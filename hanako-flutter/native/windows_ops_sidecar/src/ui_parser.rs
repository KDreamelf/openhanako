use crate::{ocr, protocol};
use anyhow::{Context, Result, anyhow};
use image::{DynamicImage, ImageFormat, Rgba, RgbaImage};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::env;
use std::io::Cursor;
use std::path::PathBuf;
use std::sync::{Mutex, OnceLock};
use yolo_rs::model::YoloModelSession;
use yolo_rs::{BoundingBox, YoloEntityOutput, image_to_yolo_input_tensor, inference};

#[derive(Debug, Deserialize)]
pub struct UiParseRequest {
    pub image_base64: String,
    #[serde(default)]
    pub return_annotated_image: bool,
    #[serde(default)]
    pub box_threshold: Option<f32>,
    #[serde(default)]
    pub iou_threshold: Option<f32>,
    #[serde(default)]
    pub use_paddleocr: Option<bool>,
    #[serde(default)]
    pub ocr_text_threshold: Option<f32>,
    #[serde(default)]
    pub imgsz: Option<u32>,
    #[serde(default)]
    pub batch_size: Option<u32>,
    #[serde(default)]
    pub use_local_semantics: Option<bool>,
    #[serde(default)]
    pub root: Option<String>,
    #[serde(default)]
    pub model_path: Option<String>,
    #[serde(default)]
    pub ocr_root: Option<String>,
}

#[derive(Debug, Deserialize)]
struct UiManifest {
    engine: String,
    models: UiModelsManifest,
}

#[derive(Debug, Deserialize)]
struct UiModelsManifest {
    icon_detector: String,
}

#[derive(Debug)]
struct UiBundleProbe {
    root: PathBuf,
    manifest_path: PathBuf,
    manifest: UiManifest,
    missing: Vec<String>,
}

struct UiService {
    probe: UiBundleProbe,
    detector: Mutex<YoloModelSession>,
    ocr_status: Value,
    execution_provider: String,
    directml_error: Option<String>,
}

static UI_SERVICE: OnceLock<Mutex<Option<UiService>>> = OnceLock::new();

#[derive(Debug, Clone, Serialize)]
pub struct UiElement {
    pub id: u32,
    pub kind: String,
    pub label: String,
    pub bbox: ocr::RectBounds,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub confidence: Option<f32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct ScreenInfo {
    pub width: u32,
    pub height: u32,
    pub channels: u8,
}

#[derive(Debug, Clone, Serialize)]
pub struct UiParseResult {
    pub screen_info: ScreenInfo,
    pub parsed_content_list: Vec<UiElement>,
    pub label_coordinates: Vec<UiElement>,
    pub ocr_text: ocr::OcrRecognitionResult,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub annotated_image_base64: Option<String>,
}

pub fn status_request(params: &Value) -> Result<Value> {
    let request: UiStatusRequest = serde_json::from_value(params.clone())
        .map_err(|err| anyhow!("ui.status 参数错误: {err}"))?;
    let _ = request.load;
    let explicit_root = request.root.as_deref().or(request.model_path.as_deref());
    let explicit_ocr_root = request.ocr_root.as_deref();

    let probe = match UiBundleProbe::resolve(explicit_root) {
        Ok(probe) => probe,
        Err(err) => {
            return Ok(json!({
                "available": false,
                "model_ready": false,
                "engine": "rust-yolo-rs+ocrs",
                "error": err.to_string(),
                "search_roots": ui_search_roots()
                    .into_iter()
                    .map(|path| path.display().to_string())
                    .collect::<Vec<_>>(),
            }));
        }
    };

    if !probe.missing.is_empty() {
        return Ok(json!({
            "available": false,
            "model_ready": false,
            "engine": probe.manifest.engine,
            "bundle_root": probe.root.display().to_string(),
            "manifest": probe.manifest_path.display().to_string(),
            "missing": probe.missing,
            "search_roots": ui_search_roots()
                .into_iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>(),
            "dependencies": {
                "ok": false,
                "missing": probe.missing.clone(),
            }
        }));
    }

    let engine = probe.manifest.engine.clone();
    let bundle_root = probe.root.display().to_string();
    let manifest = probe.manifest_path.display().to_string();

    match probe.load(explicit_ocr_root) {
        Ok(service) => Ok(service.status_json()),
        Err(err) => Ok(json!({
            "available": false,
            "model_ready": false,
            "engine": engine,
            "bundle_root": bundle_root,
            "manifest": manifest,
            "error": err.to_string(),
            "dependencies": {
                "ok": false,
                "error": err.to_string(),
            },
            "search_roots": ui_search_roots()
                .into_iter()
                .map(|path| path.display().to_string())
                .collect::<Vec<_>>(),
        })),
    }
}

pub fn parse_base64_request(params: &Value) -> Result<Value> {
    let request: UiParseRequest = serde_json::from_value(params.clone())
        .map_err(|err| anyhow!("ui.parse_base64 参数错误: {err}"))?;
    let image_bytes = protocol::decode_base64_image(&request.image_base64)
        .map_err(|err| anyhow!("ui.parse_base64 图像数据解析失败: {err}"))?;
    let explicit_root = request.root.as_deref().or(request.model_path.as_deref());
    let result = with_service(explicit_root, request.ocr_root.as_deref(), |service| {
        service.parse(
            &image_bytes,
            request.return_annotated_image,
            request.box_threshold.unwrap_or(0.25),
            request.iou_threshold.unwrap_or(0.7),
            request.use_local_semantics.unwrap_or(true),
            request.ocr_root.as_deref(),
            request.use_paddleocr.unwrap_or(false),
            request.ocr_text_threshold.unwrap_or(0.8),
            request.imgsz,
            request.batch_size.unwrap_or(64),
        )
    })?;

    let mut warnings = Vec::new();
    if request.use_paddleocr.unwrap_or(false) {
        warnings.push("use_paddleocr 参数已忽略，实际运行时使用本地 Rust OCR".to_owned());
    }
    if request.imgsz.is_some() {
        warnings.push("imgsz 参数已保留但当前实现使用固定 640 输入".to_owned());
    }
    if request.batch_size.is_some() {
        warnings.push("batch_size 参数当前未参与本地推理分批".to_owned());
    }

    Ok(json!({
        "available": true,
        "engine": "rust-yolo-rs+ocrs",
        "screen_info": result.screen_info,
        "parsed_content_list": result.parsed_content_list,
        "label_coordinates": result.label_coordinates,
        "ocr_text": result.ocr_text,
        "annotated_image_base64": result.annotated_image_base64,
        "box_threshold": request.box_threshold.unwrap_or(0.25),
        "iou_threshold": request.iou_threshold.unwrap_or(0.7),
        "use_local_semantics": request.use_local_semantics.unwrap_or(true),
        "ocr_text_threshold": request.ocr_text_threshold.unwrap_or(0.8),
        "warnings": warnings,
    }))
}

impl UiBundleProbe {
    fn resolve(explicit_root: Option<&str>) -> Result<Self> {
        let roots = if let Some(root) = explicit_root {
            vec![PathBuf::from(root)]
        } else {
            ui_search_roots()
        };

        for root in roots {
            let manifest_path = root.join("ui_parser.manifest.json");
            if !manifest_path.exists() {
                continue;
            }
            let content = std::fs::read_to_string(&manifest_path).with_context(|| {
                format!("读取 UI parser manifest 失败: {}", manifest_path.display())
            })?;
            let manifest: UiManifest = serde_json::from_str(&content).with_context(|| {
                format!("解析 UI parser manifest 失败: {}", manifest_path.display())
            })?;

            let detector = root.join(&manifest.models.icon_detector);
            let mut missing = Vec::new();
            if !detector.exists() {
                missing.push(detector.display().to_string());
            }

            return Ok(Self {
                root,
                manifest_path,
                manifest,
                missing,
            });
        }

        Err(anyhow!(
            "未找到本地 UI parser bundle: ui_parser.manifest.json"
        ))
    }

    fn load(self, explicit_ocr_root: Option<&str>) -> Result<UiService> {
        if !self.missing.is_empty() {
            return Err(anyhow!(
                "UI parser bundle 缺少文件: {}",
                self.missing.join(", ")
            ));
        }

        let detector_path = self.root.join(&self.manifest.models.icon_detector);
        let detector = build_detector(&detector_path)?;
        let ocr_status = if let Some(ocr_root) = explicit_ocr_root {
            ocr::status_request(&json!({"root": ocr_root}))?
        } else {
            ocr::status_request(&json!({}))?
        };
        if ocr_status.get("available").and_then(Value::as_bool) != Some(true) {
            return Err(anyhow!(
                "OCR 依赖未就绪: {}",
                ocr_status
                    .get("error")
                    .and_then(Value::as_str)
                    .unwrap_or("未知错误")
            ));
        }

        let service = UiService {
            probe: self,
            detector: Mutex::new(detector.model),
            ocr_status,
            execution_provider: detector.execution_provider,
            directml_error: detector.directml_error,
        };

        Ok(service)
    }
}

impl UiService {
    fn status_json(&self) -> Value {
        json!({
            "available": true,
            "model_ready": true,
            "engine": self.probe.manifest.engine.clone(),
            "bundle_root": self.probe.root.display().to_string(),
            "manifest": self.probe.manifest_path.display().to_string(),
            "models": {
                "icon_detector": self.probe.root.join(&self.probe.manifest.models.icon_detector).display().to_string(),
            },
            "runtime": {
                "detector_execution_provider": self.execution_provider.clone(),
                "directml_error": self.directml_error.clone(),
            },
            "dependencies": {
                "ok": self.ocr_status.get("available").and_then(Value::as_bool).unwrap_or(false),
                "ocr": self.ocr_status.clone(),
            }
        })
    }

    fn parse(
        &self,
        image_bytes: &[u8],
        return_annotated_image: bool,
        box_threshold: f32,
        iou_threshold: f32,
        use_local_semantics: bool,
        ocr_root: Option<&str>,
        _use_paddleocr: bool,
        _ocr_text_threshold: f32,
        _imgsz: Option<u32>,
        _batch_size: u32,
    ) -> Result<UiParseResult> {
        let image =
            image::load_from_memory(image_bytes).with_context(|| "ui.parse_base64 图片解码失败")?;
        let rgba = image.to_rgba8();
        let (width, height) = rgba.dimensions();
        let input = image_to_yolo_input_tensor(&DynamicImage::ImageRgba8(rgba.clone()));

        let mut detector = self
            .detector
            .lock()
            .map_err(|_| anyhow!("UI parser detector lock poisoned"))?;
        detector.probability_threshold = Some(box_threshold);
        detector.iou_threshold = Some(iou_threshold);
        let detections =
            inference(&mut detector, input.view()).context("ui.parse_base64 图标检测失败")?;
        drop(detector);

        let ocr_result = ocr::recognize_image_bytes(ocr_root, image_bytes, None)?;
        let mut elements = build_elements(detections, &ocr_result, use_local_semantics);
        elements.sort_by(|a, b| {
            a.bbox
                .y
                .total_cmp(&b.bbox.y)
                .then(a.bbox.x.total_cmp(&b.bbox.x))
        });

        let label_coordinates = elements
            .iter()
            .filter(|element| element.kind == "icon")
            .cloned()
            .collect::<Vec<_>>();

        let annotated_image_base64 = if return_annotated_image {
            Some(annotate_image(&rgba, &elements)?)
        } else {
            None
        };

        Ok(UiParseResult {
            screen_info: ScreenInfo {
                width,
                height,
                channels: 4,
            },
            parsed_content_list: elements,
            label_coordinates,
            ocr_text: ocr_result,
            annotated_image_base64,
        })
    }
}

fn with_service<T>(
    explicit_root: Option<&str>,
    explicit_ocr_root: Option<&str>,
    f: impl FnOnce(&UiService) -> Result<T>,
) -> Result<T> {
    if let Some(root) = explicit_root {
        let probe = UiBundleProbe::resolve(Some(root))?;
        let service = probe.load(explicit_ocr_root)?;
        return f(&service);
    }

    if explicit_ocr_root.is_some() {
        let probe = UiBundleProbe::resolve(None)?;
        let service = probe.load(explicit_ocr_root)?;
        return f(&service);
    }

    let lock = UI_SERVICE.get_or_init(|| Mutex::new(None));
    let mut guard = lock
        .lock()
        .map_err(|_| anyhow!("UI parser service lock poisoned"))?;
    if guard.is_none() {
        let probe = UiBundleProbe::resolve(None)?;
        *guard = Some(probe.load(None)?);
    }

    let service = guard
        .as_ref()
        .ok_or_else(|| anyhow!("UI parser service 未初始化"))?;
    f(service)
}

struct DetectorRuntime {
    model: YoloModelSession,
    execution_provider: String,
    directml_error: Option<String>,
}

fn build_detector(path: &PathBuf) -> Result<DetectorRuntime> {
    match build_detector_with_directml(path) {
        Ok(model) => Ok(DetectorRuntime {
            model,
            execution_provider: "directml".to_owned(),
            directml_error: None,
        }),
        Err(directml_err) => {
            let session = ort::session::Session::builder()
                .context("创建 ONNX CPU Session 失败")?
                .commit_from_file(path)
                .with_context(|| format!("加载图标检测模型失败: {}", path.display()))?;
            Ok(DetectorRuntime {
                model: yolo_model_from_session(session),
                execution_provider: "cpu".to_owned(),
                directml_error: Some(directml_err.to_string()),
            })
        }
    }
}

fn build_detector_with_directml(path: &PathBuf) -> Result<YoloModelSession> {
    let session = ort::session::Session::builder()
        .context("创建 ONNX Session 失败")?
        .with_execution_providers([ort::ep::DirectML::default().build()])
        .map_err(|err| anyhow!("配置 DirectML 执行提供器失败: {err}"))?
        .commit_from_file(path)
        .with_context(|| format!("加载图标检测模型失败: {}", path.display()))?;

    Ok(yolo_model_from_session(session))
}

fn yolo_model_from_session(session: ort::session::Session) -> YoloModelSession {
    let mut model = YoloModelSession::new(session, std::iter::once("icon"));
    model.probability_threshold = Some(0.25);
    model.iou_threshold = Some(0.7);
    model
}

fn build_elements(
    detections: Vec<YoloEntityOutput>,
    ocr_result: &ocr::OcrRecognitionResult,
    use_local_semantics: bool,
) -> Vec<UiElement> {
    let mut elements = Vec::new();
    let mut next_id = 1u32;

    for detection in detections {
        let bbox = bbox_to_bounds(&detection.bounding_box);
        let label = if use_local_semantics {
            best_label_for_detection(&bbox, &ocr_result.lines)
        } else {
            "icon".to_owned()
        };
        elements.push(UiElement {
            id: next_id,
            kind: "icon".to_owned(),
            label,
            bbox,
            confidence: Some(detection.confidence),
            text: None,
        });
        next_id += 1;
    }

    for line in &ocr_result.lines {
        let label = line.text.clone();
        elements.push(UiElement {
            id: next_id,
            kind: "text".to_owned(),
            label: label.clone(),
            bbox: line.bbox.clone(),
            confidence: None,
            text: Some(line.text.clone()),
        });
        next_id += 1;
    }

    elements
}

fn best_label_for_detection(bbox: &ocr::RectBounds, lines: &[ocr::OcrLineResult]) -> String {
    let center_x = bbox.x + bbox.width / 2.0;
    let center_y = bbox.y + bbox.height / 2.0;
    let expanded = bbox.expand(16.0);

    for line in lines {
        if line.bbox.intersects(&expanded)
            || expanded.contains_point(line.bbox.x + 1.0, line.bbox.y + 1.0)
            || expanded.contains_point(center_x, center_y)
        {
            let text = line.text.trim();
            if !text.is_empty() {
                return text.to_owned();
            }
        }
    }

    "icon".to_owned()
}

fn bbox_to_bounds(bbox: &BoundingBox) -> ocr::RectBounds {
    ocr::RectBounds {
        x: bbox.x1.max(0.0),
        y: bbox.y1.max(0.0),
        width: (bbox.x2 - bbox.x1).max(0.0),
        height: (bbox.y2 - bbox.y1).max(0.0),
    }
}

fn annotate_image(image: &RgbaImage, elements: &[UiElement]) -> Result<String> {
    let mut canvas = image.clone();
    for element in elements {
        match element.kind.as_str() {
            "icon" => draw_rectangle(&mut canvas, &element.bbox, Rgba([255, 59, 48, 200])),
            "text" => draw_rectangle(&mut canvas, &element.bbox, Rgba([0, 122, 255, 200])),
            _ => draw_rectangle(&mut canvas, &element.bbox, Rgba([52, 199, 89, 200])),
        }
    }

    let mut buffer = Cursor::new(Vec::new());
    DynamicImage::ImageRgba8(canvas)
        .write_to(&mut buffer, ImageFormat::Png)
        .context("导出标注图失败")?;
    Ok(protocol::encode_png_base64(buffer.get_ref()))
}

fn draw_rectangle(image: &mut RgbaImage, bbox: &ocr::RectBounds, color: Rgba<u8>) {
    let width = image.width() as i32;
    let height = image.height() as i32;
    if width <= 0 || height <= 0 {
        return;
    }

    let left = bbox.x.floor().max(0.0) as i32;
    let top = bbox.y.floor().max(0.0) as i32;
    let right = bbox.right().ceil().min(width as f32 - 1.0) as i32;
    let bottom = bbox.bottom().ceil().min(height as f32 - 1.0) as i32;

    if right < left || bottom < top {
        return;
    }

    for x in left..=right {
        put_pixel_if_in_bounds(image, x, top, color);
        put_pixel_if_in_bounds(image, x, bottom, color);
    }
    for y in top..=bottom {
        put_pixel_if_in_bounds(image, left, y, color);
        put_pixel_if_in_bounds(image, right, y, color);
    }
}

fn put_pixel_if_in_bounds(image: &mut RgbaImage, x: i32, y: i32, color: Rgba<u8>) {
    if x < 0 || y < 0 {
        return;
    }
    let x = x as u32;
    let y = y as u32;
    if x < image.width() && y < image.height() {
        image.put_pixel(x, y, color);
    }
}

fn ui_search_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(root) = env::var("HANAKO_WINDOWS_OPS_UI_PARSER_DIR") {
        if !root.trim().is_empty() {
            roots.push(PathBuf::from(root.trim()));
        }
    }
    if let Ok(exe) = env::current_exe() {
        if let Some(exe_dir) = exe.parent() {
            roots.push(exe_dir.join("ui_parser"));
            if let Some(native_dir) = exe_dir.parent() {
                if let Some(app_dir) = native_dir.parent() {
                    roots.push(app_dir.join("models").join("windows_ops").join("ui_parser"));
                }
            }
        }
    }
    if let Ok(current) = env::current_dir() {
        roots.push(current.join("models").join("ui_parser"));
        roots.push(
            current
                .join("native")
                .join("windows_ops_sidecar")
                .join("models")
                .join("ui_parser"),
        );
        roots.push(current.join("models").join("windows_ops").join("ui_parser"));
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

#[derive(Debug, Deserialize)]
struct UiStatusRequest {
    #[serde(default)]
    root: Option<String>,
    #[serde(default)]
    model_path: Option<String>,
    #[serde(default)]
    ocr_root: Option<String>,
    #[serde(default)]
    load: Option<bool>,
}
