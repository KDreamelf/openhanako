use anyhow::{Context, Result, anyhow};
use ocrs::{ImageSource, OcrEngine, OcrEngineParams, TextItem};
use rten::Model;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::env;
use std::path::{Path, PathBuf};
use std::sync::{Mutex, OnceLock};

#[derive(Debug, Deserialize)]
pub struct OcrRecognizeRequest {
    pub image_base64: String,
    #[serde(default)]
    pub language: Option<String>,
    #[serde(default)]
    pub model_path: Option<String>,
    #[serde(default)]
    pub root: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OcrManifest {
    engine: String,
    models: OcrModelsManifest,
}

#[derive(Debug, Deserialize)]
struct OcrModelsManifest {
    detection: String,
    recognition: String,
}

#[derive(Debug)]
struct OcrBundleProbe {
    root: PathBuf,
    manifest_path: PathBuf,
    manifest: OcrManifest,
    missing: Vec<String>,
}

struct OcrService {
    probe: OcrBundleProbe,
    engine: OcrEngine,
}

static OCR_SERVICE: OnceLock<Mutex<Option<OcrService>>> = OnceLock::new();

#[derive(Debug, Clone, Serialize)]
pub struct RectBounds {
    pub x: f32,
    pub y: f32,
    pub width: f32,
    pub height: f32,
}

impl RectBounds {
    pub fn right(&self) -> f32 {
        self.x + self.width
    }

    pub fn bottom(&self) -> f32 {
        self.y + self.height
    }

    pub fn contains_point(&self, x: f32, y: f32) -> bool {
        x >= self.x && x <= self.right() && y >= self.y && y <= self.bottom()
    }

    pub fn intersects(&self, other: &RectBounds) -> bool {
        self.x < other.right()
            && self.right() > other.x
            && self.y < other.bottom()
            && self.bottom() > other.y
    }

    pub fn expand(&self, padding: f32) -> RectBounds {
        RectBounds {
            x: (self.x - padding).max(0.0),
            y: (self.y - padding).max(0.0),
            width: self.width + padding * 2.0,
            height: self.height + padding * 2.0,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct OcrWordResult {
    pub text: String,
    pub bbox: RectBounds,
}

#[derive(Debug, Clone, Serialize)]
pub struct OcrLineResult {
    pub text: String,
    pub bbox: RectBounds,
    pub words: Vec<OcrWordResult>,
}

#[derive(Debug, Clone, Serialize)]
pub struct OcrRecognitionResult {
    pub text: String,
    pub line_count: usize,
    pub word_count: usize,
    pub lines: Vec<OcrLineResult>,
    pub words: Vec<OcrWordResult>,
}

pub fn status_request(params: &Value) -> Result<Value> {
    let explicit_root = explicit_root_from_params(params);
    let _ = params.get("load");
    let probe = match OcrBundleProbe::resolve(explicit_root.as_deref()) {
        Ok(probe) => probe,
        Err(err) => {
            return Ok(json!({
                "available": false,
                "bundle_available": false,
                "engine": "ocrs-rten",
                "error": err.to_string(),
                "search_roots": ocr_search_roots()
                    .into_iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>(),
            }));
        }
    };

    if !probe.missing.is_empty() {
        return Ok(json!({
            "available": false,
            "bundle_available": false,
            "engine": probe.manifest.engine,
            "bundle_root": probe.root.display().to_string(),
            "manifest": probe.manifest_path.display().to_string(),
            "missing": probe.missing,
            "search_roots": ocr_search_roots()
                .into_iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>(),
        }));
    }

    let engine = probe.manifest.engine.clone();
    let bundle_root = probe.root.display().to_string();
    let manifest = probe.manifest_path.display().to_string();

    match probe.load() {
        Ok(service) => Ok(service.status_json()),
        Err(err) => Ok(json!({
            "available": false,
            "bundle_available": true,
            "engine": engine,
            "bundle_root": bundle_root,
            "manifest": manifest,
            "error": err.to_string(),
            "search_roots": ocr_search_roots()
                .into_iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>(),
        })),
    }
}

pub fn recognize_request(params: &Value) -> Result<Value> {
    let request: OcrRecognizeRequest = serde_json::from_value(params.clone())
        .map_err(|err| anyhow!("ocr.recognize 参数错误: {err}"))?;
    let image_bytes = crate::protocol::decode_base64_image(&request.image_base64)
        .map_err(|err| anyhow!("ocr.recognize 图像数据解析失败: {err}"))?;
    let result = recognize_image_bytes(
        explicit_root_from_request(&request),
        &image_bytes,
        request.language.as_deref(),
    )?;

    Ok(json!({
        "available": true,
        "engine": "ocrs-rten",
        "language": request.language,
        "text": result.text,
        "line_count": result.line_count,
        "word_count": result.word_count,
        "lines": result.lines,
        "words": result.words,
        "decoded_bytes": image_bytes.len(),
    }))
}

pub fn recognize_image_bytes(
    explicit_root: Option<&str>,
    image_bytes: &[u8],
    language: Option<&str>,
) -> Result<OcrRecognitionResult> {
    let _ = language;
    with_service(explicit_root, |service| {
        let rgb_image = image::load_from_memory(image_bytes)
            .with_context(|| "ocr.recognize 图片解码失败")?
            .into_rgb8();
        let img_source = ImageSource::from_bytes(rgb_image.as_raw(), rgb_image.dimensions())
            .map_err(|err| anyhow!("ocr.recognize 图像预处理失败: {err}"))?;
        let input = service
            .engine
            .prepare_input(img_source)
            .context("ocr.recognize 预处理失败")?;

        let word_rects = service
            .engine
            .detect_words(&input)
            .context("ocr.recognize 文本检测失败")?;
        let line_rects = service.engine.find_text_lines(&input, &word_rects);
        let recognized_lines = service
            .engine
            .recognize_text(&input, &line_rects)
            .context("ocr.recognize 文本识别失败")?;

        let mut lines = Vec::new();
        let mut words = Vec::new();
        let mut full_text = Vec::new();

        for line in recognized_lines.into_iter().flatten() {
            let text = line.to_string();
            if text.trim().is_empty() {
                continue;
            }

            let line_words = line
                .words()
                .map(|word| {
                    let text = word.to_string();
                    let bbox = rect_bounds_from_item(&word);
                    OcrWordResult { text, bbox }
                })
                .collect::<Vec<_>>();

            let line_bbox = rect_bounds_from_item(&line);
            full_text.push(text.clone());
            words.extend(line_words.iter().cloned());
            lines.push(OcrLineResult {
                text,
                bbox: line_bbox,
                words: line_words,
            });
        }

        Ok(OcrRecognitionResult {
            text: full_text.join("\n"),
            line_count: lines.len(),
            word_count: words.len(),
            lines,
            words,
        })
    })
}

impl OcrBundleProbe {
    fn resolve(explicit_root: Option<&str>) -> Result<Self> {
        let roots = if let Some(root) = explicit_root {
            vec![PathBuf::from(root)]
        } else {
            ocr_search_roots()
        };

        for root in roots {
            let manifest_path = root.join("ocr.manifest.json");
            if !manifest_path.exists() {
                continue;
            }
            let content = std::fs::read_to_string(&manifest_path)
                .with_context(|| format!("读取 OCR manifest 失败: {}", manifest_path.display()))?;
            let manifest: OcrManifest = serde_json::from_str(&content)
                .with_context(|| format!("解析 OCR manifest 失败: {}", manifest_path.display()))?;

            let detection = root.join(&manifest.models.detection);
            let recognition = root.join(&manifest.models.recognition);
            let mut missing = Vec::new();
            if !detection.exists() {
                missing.push(detection.display().to_string());
            }
            if !recognition.exists() {
                missing.push(recognition.display().to_string());
            }

            return Ok(Self {
                root,
                manifest_path,
                manifest,
                missing,
            });
        }

        Err(anyhow!("未找到本地 OCR bundle: ocr.manifest.json"))
    }

    fn load(self) -> Result<OcrService> {
        if !self.missing.is_empty() {
            return Err(anyhow!("OCR bundle 缺少文件: {}", self.missing.join(", ")));
        }

        let detection_path = self.root.join(&self.manifest.models.detection);
        let recognition_path = self.root.join(&self.manifest.models.recognition);

        let detection_model = Model::load_file(&detection_path)
            .with_context(|| format!("加载 OCR 检测模型失败: {}", detection_path.display()))?;
        let recognition_model = Model::load_file(&recognition_path)
            .with_context(|| format!("加载 OCR 识别模型失败: {}", recognition_path.display()))?;

        let engine = OcrEngine::new(OcrEngineParams {
            detection_model: Some(detection_model),
            recognition_model: Some(recognition_model),
            ..Default::default()
        })
        .context("初始化 OCR 引擎失败")?;

        Ok(OcrService {
            probe: self,
            engine,
        })
    }
}

impl OcrService {
    fn status_json(&self) -> Value {
        json!({
            "available": true,
            "bundle_available": true,
            "engine": self.probe.manifest.engine.clone(),
            "bundle_root": self.probe.root.display().to_string(),
            "manifest": self.probe.manifest_path.display().to_string(),
            "models": {
                "detection": self.probe.root.join(&self.probe.manifest.models.detection).display().to_string(),
                "recognition": self.probe.root.join(&self.probe.manifest.models.recognition).display().to_string(),
            },
            "recognition": {
                "available": true,
            },
        })
    }
}

fn explicit_root_from_params(params: &Value) -> Option<String> {
    params
        .get("root")
        .or_else(|| params.get("model_path"))
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn explicit_root_from_request(request: &OcrRecognizeRequest) -> Option<&str> {
    request.root.as_deref().or(request.model_path.as_deref())
}

fn with_service<T>(
    explicit_root: Option<&str>,
    f: impl FnOnce(&OcrService) -> Result<T>,
) -> Result<T> {
    if let Some(root) = explicit_root {
        let probe = OcrBundleProbe::resolve(Some(root))?;
        let service = probe.load()?;
        return f(&service);
    }

    let lock = OCR_SERVICE.get_or_init(|| Mutex::new(None));
    let mut guard = lock
        .lock()
        .map_err(|_| anyhow!("OCR service lock poisoned"))?;
    if guard.is_none() {
        let probe = OcrBundleProbe::resolve(None)?;
        *guard = Some(probe.load()?);
    }

    let service = guard
        .as_ref()
        .ok_or_else(|| anyhow!("OCR service 未初始化"))?;
    f(service)
}

fn rect_bounds_from_item(item: &impl TextItem) -> RectBounds {
    let rect = item.bounding_rect();
    RectBounds {
        x: rect.left() as f32,
        y: rect.top() as f32,
        width: rect.width() as f32,
        height: rect.height() as f32,
    }
}

fn ocr_search_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(root) = env::var("HANAKO_WINDOWS_OPS_OCR_DIR") {
        if !root.trim().is_empty() {
            roots.push(PathBuf::from(root.trim()));
        }
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            roots.push(exe_dir.join("ocr"));
            if let Some(native_dir) = exe_dir.parent() {
                if let Some(app_dir) = native_dir.parent() {
                    roots.push(app_dir.join("models").join("windows_ops").join("ocr"));
                }
            }
        }
    }
    if let Ok(current) = env::current_dir() {
        roots.push(current.join("models").join("ocr"));
        roots.push(
            current
                .join("native")
                .join("windows_ops_sidecar")
                .join("models")
                .join("ocr"),
        );
    }
    dedupe_paths(roots)
}

fn dedupe_paths(paths: Vec<PathBuf>) -> Vec<PathBuf> {
    let mut result = Vec::new();
    for path in paths {
        if !result.iter().any(|item: &PathBuf| item == &path) {
            result.push(path);
        }
    }
    result
}

#[allow(dead_code)]
fn _is_inside(path: &Path, root: &Path) -> bool {
    path.starts_with(root)
}
