# Windows 操作边车

## 目标

把 Windows 专有能力从 Flutter 主流程里拆出去，避免把 UIA、截图、OCR 和系统交互逻辑堆进界面层。

## 形态

- 主体：Flutter 子体
- 边车：Rust Windows sidecar
- 通信：stdin/stdout 的单行 JSON
- 打包：随 Windows 安装包一起分发

## 边车职责

- 截图
- 鼠标移动、点击与键盘文字输入
- UIA 控件树读取与 InvokePattern 调用
- OCR 自包含 bundle 装载
- 本地图标/界面识别模型解析截图中的可交互元素
- 后续可扩展窗口探测、局部高亮

## 当前落点

- `native/windows_ops_sidecar/`：Rust sidecar
- `lib/windows_ops/windows_ops_client.dart`：Flutter 客户端
- `lib/windows_ops/windows_ops_capabilities.dart`：能力探测与逐项降级
- `lib/windows_ops/windows_ops_tools.dart`：按能力注册 LLM 工具 schema 与执行映射
- `windows/CMakeLists.txt`：把已构建的 sidecar 和模型目录安装到应用目录
- `installers/windows.iss`：把 sidecar 和模型资源一起打包

## 能力注册规则

参考 OmniParser 的端侧模型流程，但不沿用“模型加载中仍暴露工具”的做法。官方安装包必须预置模型和运行库，运行时不自动下载、不联网补装。子体启动或准备给 AI 暴露工具前，先做一次 capability probe：

- 边车不可启动：不注册任何 Windows 操作工具
- 局部截图探测失败：不注册截图工具
- 鼠标/键盘输入能力未声明：不注册真实输入工具
- UIA 控件树探测失败：不注册 UIA 工具
- OCR `ocr.status.available != true`：不注册 OCR 工具；正式发布包里这通常只应由本机性能或运行库加载失败触发
- 界面识别模型未发现或不可运行：不注册界面解析工具；正式发布包里这通常只应由本机性能或运行库加载失败触发

这几个能力互不捆绑。截图、UIA、OCR、界面识别模型各自通过各自注册；任意一项不可用时只降级对应工具，不影响其他已通过探测的能力。下载不是运行时恢复路径，缺模型属于发布包制作错误，不属于用户端运行时问题。

当前工具名：

- `windows_capture_region`
- `windows_mouse_move`
- `windows_mouse_click`
- `windows_text_input`
- `windows_uia_tree`
- `windows_uia_invoke`
- `windows_ocr_recognize`
- `windows_ui_parse`

其中 `windows_ocr_recognize` 和 `windows_ui_parse` 只有在本地模型与推理链都实际可运行时才会出现。主界面和设置页顶部状态栏会显示 Windows 操作链状态；模型加载中、待准备或不可用时显示为状态标签，不把未就绪能力注册给 AI。

AI 可见的工具输出默认走压缩摘要，不直接返回 sidecar 原始大 JSON：

- `windows_capture_region` 默认只返回图片尺寸、编码和 base64 长度；确实要原图时传 `include_image_base64=true`
- `windows_uia_tree` 默认返回 `compact_windows_uia_tree_v1`，只保留角色、名称、坐标、可交互候选等高价值字段；调试时传 `include_raw=true`
- `windows_ocr_recognize` 默认返回文本行摘要；需要单词级结果时传 `include_words=true`，需要原始结果时传 `include_raw=true`
- `windows_ui_parse` 默认返回 `compact_windows_ui_observation_v1`，包含界面概览、主要文字、图标模型候选、中心坐标和推理置信度；需要原始解析结果时传 `include_raw=true`

为了避免“截图 base64 -> 再解析”的上下文污染，`windows_ui_parse` 支持直接传 `x/y/width/height` 让客户端内部截图并解析。推荐 AI 优先用 `windows_ui_parse` 获取界面概览，再用 `windows_mouse_click` / `windows_text_input` 操作。

## 构建顺序

```powershell
cd native/windows_ops_sidecar
cargo build --release --target-dir target

cd ..\..
flutter build windows --release
iscc installers/windows.iss
```

这里显式使用 `--target-dir target`，避免开发机全局 `CARGO_TARGET_DIR` 把 exe 打到临时目录，导致安装包找不到边车。

## OCR Bundle

OCR 走自包含 bundle，不依赖系统预装运行库。安装包内固定放到：

- `native/windows_ops/hanako_windows_ops_sidecar.exe`
- `models/windows_ops/ocr/ocr.manifest.json`
- `models/windows_ops/ocr/runtime/onnxruntime.dll`
- `models/windows_ops/ocr/runtime/DirectML.dll`
- `models/windows_ops/ocr/models/*.onnx`
- `models/windows_ops/ocr/models/charset.txt`

边车启动后只从这些本地路径或 `HANAKO_WINDOWS_OPS_OCR_DIR` 查找 OCR 资源。`ocr.status` 会返回缺失文件清单；`ocr.recognize` 会先解析图像、解析 manifest、加载本地 ONNX Runtime / DirectML DLL。模型推理不允许联网补装，必须由安装包携带完整模型族、字符表和运行库。

发布包制作时，`installers/windows.iss` 对 OCR 运行库和核心模型文件使用显式 `Source` 条目，不再对核心资源使用 `skipifsourcedoesntexist`。也就是说，模型没预置时安装包编译应该失败，而不是产出一个运行时再下载或运行时缺能力的包。

`available` 表示 OCR 工具是否可直接执行完整识别，不等同于 bundle 是否存在。仅模型文件存在但推理链未就绪时，`bundle_available` 可以为 `true`，`available` 仍为 `false`，Flutter 侧不会注册 OCR 工具。

Manifest 示例见 `native/windows_ops_sidecar/models/ocr/ocr.manifest.example.json`。

## UIA 调用

`uia.tree` 支持：

- `root`: `desktop` / `focused`
- `view`: `control` / `content` / `raw`
- `point`: `{ "x": 100, "y": 200 }`
- `hwnd`: Windows 原生窗口句柄
- `max_depth`
- `max_nodes`
- `compact_max_nodes`：AI 可见压缩摘要最多返回多少个节点
- `include_raw`：返回 sidecar 原始 UIA 树

`uia.invoke` 支持：

- 直接对 `point` / `hwnd` / `focused` 指向的元素调用
- 通过 `selector` 在控件树里查找后调用
- selector 字段：`name`、`automation_id`、`class_name`、`localized_control_type`、`contains`

## 真实输入

`input.mouse_move` 支持：

- `x` / `y`：屏幕坐标

`input.mouse_click` 支持：

- `x` / `y`：屏幕坐标
- `button`：`left` / `right` / `middle`
- `clicks`：1-5 次
- `interval_ms`：多次点击间隔

`input.text` 支持：

- `text`：要输入的文本
- `press_enter`：输入后是否按回车

输入工具是实际系统输入，不依赖 UIA 元素可识别。推荐链路是：先截图或 `windows_ui_parse` 找目标，再 `windows_mouse_click` 聚焦，最后 `windows_text_input` 输入。

参考资料：

- [Microsoft UI Automation](https://learn.microsoft.com/en-us/windows/win32/winauto/entry-uiauto-client)
- [IUIAutomation](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nn-uiautomationclient-iuiautomation)
- [ONNX Runtime DirectML execution provider](https://learn.microsoft.com/en-us/windows/ai/directml/gpu-accelerated-machine-learning)
- [Windows Graphics Capture](https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture)

## 约定

- UIA 直接使用 Windows COM / UIAutomation，不依赖外部服务
- OCR 运行库和模型随安装包分发
- Windows 主机上优先启用本地边车
- 主界面和设置页顶部状态栏显示 DHT、经验转发、界面模型与输入链路等后台准备状态
- 子体安装包内预留 `native/windows_ops/` 和 `models/windows_ops/`
- 不把“加载中”或“待安装”的能力注册给 AI；未通过探测的能力只保留状态查询和日志
- AI 工具默认返回 compact observation，避免 UIA 原始树和图片 base64 直接污染上下文
- 不在用户端自动下载模型；正式包的模型完整性由打包阶段保证
