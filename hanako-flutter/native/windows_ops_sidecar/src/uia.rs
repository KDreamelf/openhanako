use anyhow::Result;
use serde_json::Value;

#[cfg(windows)]
mod windows_uia {
    use anyhow::{Context, Result, anyhow};
    use serde::Deserialize;
    use serde_json::{Value, json};
    use std::ffi::c_void;
    use windows::Win32::Foundation::{HWND, POINT, RECT};
    use windows::Win32::System::Com::{
        CLSCTX_INPROC_SERVER, COINIT_APARTMENTTHREADED, CoCreateInstance, CoInitializeEx,
        CoUninitialize,
    };
    use windows::Win32::UI::Accessibility::{
        CUIAutomation, IUIAutomation, IUIAutomationElement, IUIAutomationInvokePattern,
        IUIAutomationTreeWalker, UIA_InvokePatternId,
    };
    use windows::core::IUnknown;

    #[derive(Debug, Deserialize)]
    struct PointSpec {
        x: i32,
        y: i32,
    }

    #[derive(Debug, Deserialize)]
    struct UiaRequest {
        #[serde(default)]
        root: Option<String>,
        #[serde(default)]
        view: Option<String>,
        #[serde(default)]
        point: Option<PointSpec>,
        #[serde(default)]
        hwnd: Option<isize>,
        #[serde(default = "default_max_depth")]
        max_depth: usize,
        #[serde(default = "default_max_nodes")]
        max_nodes: usize,
        #[serde(default)]
        selector: Option<UiaSelector>,
    }

    #[derive(Debug, Deserialize)]
    struct UiaSelector {
        #[serde(default)]
        name: Option<String>,
        #[serde(default)]
        automation_id: Option<String>,
        #[serde(default)]
        class_name: Option<String>,
        #[serde(default)]
        localized_control_type: Option<String>,
        #[serde(default)]
        contains: bool,
    }

    fn default_max_depth() -> usize {
        3
    }

    fn default_max_nodes() -> usize {
        200
    }

    pub fn tree_request(params: &Value) -> Result<Value> {
        let request = parse_request(params)?;
        let context = UiaContext::new()?;
        let root = resolve_root(&context.automation, &request)?;
        let walker = resolve_walker(&context.automation, request.view.as_deref())?;
        let mut remaining = request.max_nodes.max(1);
        let tree = element_to_json(&root, &walker, 0, request.max_depth, &mut remaining)?;

        Ok(json!({
            "root": request.root.unwrap_or_else(|| "desktop".to_owned()),
            "view": request.view.unwrap_or_else(|| "control".to_owned()),
            "max_depth": request.max_depth,
            "max_nodes": request.max_nodes,
            "tree": tree,
        }))
    }

    pub fn invoke_request(params: &Value) -> Result<Value> {
        let request = parse_request(params)?;
        let context = UiaContext::new()?;
        let root = resolve_root(&context.automation, &request)?;

        let target = if let Some(selector) = request.selector.as_ref() {
            let walker = resolve_walker(&context.automation, request.view.as_deref())?;
            let mut remaining = request.max_nodes.max(1);
            find_matching_element(
                &root,
                &walker,
                selector,
                0,
                request.max_depth,
                &mut remaining,
            )?
            .ok_or_else(|| anyhow!("未找到匹配 selector 的 UIA 元素"))?
        } else {
            root
        };

        let before = element_summary(&target)?;
        unsafe {
            let pattern: IUIAutomationInvokePattern =
                target.GetCurrentPatternAs(UIA_InvokePatternId)?;
            pattern.Invoke()?;
        }

        Ok(json!({
            "invoked": true,
            "target": before,
        }))
    }

    fn parse_request(params: &Value) -> Result<UiaRequest> {
        let mut request: UiaRequest =
            serde_json::from_value(params.clone()).context("UIA 请求参数应为 JSON object")?;
        request.max_depth = request.max_depth.min(12);
        request.max_nodes = request.max_nodes.clamp(1, 5000);
        Ok(request)
    }

    struct ComApartment {
        initialized: bool,
    }

    impl ComApartment {
        fn new() -> Result<Self> {
            let hr = unsafe { CoInitializeEx(None, COINIT_APARTMENTTHREADED) };
            hr.ok().context("初始化 COM apartment 失败")?;
            Ok(Self { initialized: true })
        }
    }

    impl Drop for ComApartment {
        fn drop(&mut self) {
            if self.initialized {
                unsafe {
                    CoUninitialize();
                }
            }
        }
    }

    struct UiaContext {
        _com: ComApartment,
        automation: IUIAutomation,
    }

    impl UiaContext {
        fn new() -> Result<Self> {
            let com = ComApartment::new()?;
            let automation: IUIAutomation = unsafe {
                CoCreateInstance(&CUIAutomation, None::<&IUnknown>, CLSCTX_INPROC_SERVER)
                    .context("创建 CUIAutomation 失败")?
            };
            Ok(Self {
                _com: com,
                automation,
            })
        }
    }

    fn resolve_root(
        automation: &IUIAutomation,
        request: &UiaRequest,
    ) -> Result<IUIAutomationElement> {
        if let Some(point) = request.point.as_ref() {
            return unsafe {
                automation
                    .ElementFromPoint(POINT {
                        x: point.x,
                        y: point.y,
                    })
                    .context("按坐标获取 UIA 元素失败")
            };
        }
        if let Some(hwnd) = request.hwnd {
            return unsafe {
                automation
                    .ElementFromHandle(HWND(hwnd as *mut c_void))
                    .context("按 HWND 获取 UIA 元素失败")
            };
        }
        match request.root.as_deref().unwrap_or("desktop") {
            "focused" => unsafe {
                automation
                    .GetFocusedElement()
                    .context("获取焦点 UIA 元素失败")
            },
            "desktop" | "root" => unsafe {
                automation
                    .GetRootElement()
                    .context("获取桌面 UIA 根元素失败")
            },
            other => Err(anyhow!("不支持的 UIA root: {other}")),
        }
    }

    fn resolve_walker(
        automation: &IUIAutomation,
        view: Option<&str>,
    ) -> Result<IUIAutomationTreeWalker> {
        unsafe {
            match view.unwrap_or("control") {
                "raw" => automation
                    .RawViewWalker()
                    .context("获取 RawViewWalker 失败"),
                "content" => automation
                    .ContentViewWalker()
                    .context("获取 ContentViewWalker 失败"),
                "control" => automation
                    .ControlViewWalker()
                    .context("获取 ControlViewWalker 失败"),
                other => Err(anyhow!("不支持的 UIA view: {other}")),
            }
        }
    }

    fn element_to_json(
        element: &IUIAutomationElement,
        walker: &IUIAutomationTreeWalker,
        depth: usize,
        max_depth: usize,
        remaining: &mut usize,
    ) -> Result<Value> {
        if *remaining == 0 {
            return Ok(json!({"truncated": true}));
        }
        *remaining -= 1;

        let mut node = element_summary(element)?;
        if depth >= max_depth || *remaining == 0 {
            node["children"] = json!([]);
            return Ok(node);
        }

        let mut children = Vec::new();
        let mut child = unsafe { walker.GetFirstChildElement(element).ok() };
        while let Some(current) = child {
            if *remaining == 0 {
                break;
            }
            children.push(element_to_json(
                &current,
                walker,
                depth + 1,
                max_depth,
                remaining,
            )?);
            child = unsafe { walker.GetNextSiblingElement(&current).ok() };
        }
        node["children"] = Value::Array(children);
        Ok(node)
    }

    fn find_matching_element(
        element: &IUIAutomationElement,
        walker: &IUIAutomationTreeWalker,
        selector: &UiaSelector,
        depth: usize,
        max_depth: usize,
        remaining: &mut usize,
    ) -> Result<Option<IUIAutomationElement>> {
        if *remaining == 0 {
            return Ok(None);
        }
        *remaining -= 1;

        if selector_matches(element, selector)? {
            return Ok(Some(element.clone()));
        }
        if depth >= max_depth {
            return Ok(None);
        }

        let mut child = unsafe { walker.GetFirstChildElement(element).ok() };
        while let Some(current) = child {
            if let Some(found) =
                find_matching_element(&current, walker, selector, depth + 1, max_depth, remaining)?
            {
                return Ok(Some(found));
            }
            if *remaining == 0 {
                return Ok(None);
            }
            child = unsafe { walker.GetNextSiblingElement(&current).ok() };
        }
        Ok(None)
    }

    fn selector_matches(element: &IUIAutomationElement, selector: &UiaSelector) -> Result<bool> {
        if let Some(expected) = selector.name.as_deref() {
            if !field_matches(
                &safe_bstr(|| unsafe { element.CurrentName() }),
                expected,
                selector.contains,
            ) {
                return Ok(false);
            }
        }
        if let Some(expected) = selector.automation_id.as_deref() {
            if !field_matches(
                &safe_bstr(|| unsafe { element.CurrentAutomationId() }),
                expected,
                selector.contains,
            ) {
                return Ok(false);
            }
        }
        if let Some(expected) = selector.class_name.as_deref() {
            if !field_matches(
                &safe_bstr(|| unsafe { element.CurrentClassName() }),
                expected,
                selector.contains,
            ) {
                return Ok(false);
            }
        }
        if let Some(expected) = selector.localized_control_type.as_deref() {
            if !field_matches(
                &safe_bstr(|| unsafe { element.CurrentLocalizedControlType() }),
                expected,
                selector.contains,
            ) {
                return Ok(false);
            }
        }
        Ok(true)
    }

    fn field_matches(actual: &str, expected: &str, contains: bool) -> bool {
        if contains {
            actual.contains(expected)
        } else {
            actual == expected
        }
    }

    fn element_summary(element: &IUIAutomationElement) -> Result<Value> {
        let rect = unsafe {
            element
                .CurrentBoundingRectangle()
                .unwrap_or_else(|_| RECT::default())
        };
        let hwnd = unsafe { element.CurrentNativeWindowHandle().ok() }
            .map(|value| value.0 as isize)
            .unwrap_or_default();
        let is_enabled = unsafe { element.CurrentIsEnabled().ok() }
            .map(|value| value.as_bool())
            .unwrap_or(false);
        let is_offscreen = unsafe { element.CurrentIsOffscreen().ok() }
            .map(|value| value.as_bool())
            .unwrap_or(false);

        Ok(json!({
            "name": safe_bstr(|| unsafe { element.CurrentName() }),
            "automation_id": safe_bstr(|| unsafe { element.CurrentAutomationId() }),
            "class_name": safe_bstr(|| unsafe { element.CurrentClassName() }),
            "localized_control_type": safe_bstr(|| unsafe { element.CurrentLocalizedControlType() }),
            "framework_id": safe_bstr(|| unsafe { element.CurrentFrameworkId() }),
            "process_id": unsafe { element.CurrentProcessId().unwrap_or_default() },
            "control_type": unsafe { element.CurrentControlType().map(|value| value.0).unwrap_or_default() },
            "native_window_handle": hwnd,
            "is_enabled": is_enabled,
            "is_offscreen": is_offscreen,
            "bounding_rect": {
                "left": rect.left,
                "top": rect.top,
                "right": rect.right,
                "bottom": rect.bottom,
                "width": rect.right - rect.left,
                "height": rect.bottom - rect.top,
            },
        }))
    }

    fn safe_bstr<F>(f: F) -> String
    where
        F: FnOnce() -> windows::core::Result<windows::core::BSTR>,
    {
        f().map(|value| value.to_string()).unwrap_or_default()
    }
}

#[cfg(windows)]
pub fn tree_request(params: &Value) -> Result<Value> {
    windows_uia::tree_request(params)
}

#[cfg(windows)]
pub fn invoke_request(params: &Value) -> Result<Value> {
    windows_uia::invoke_request(params)
}

#[cfg(not(windows))]
pub fn tree_request(_: &Value) -> Result<Value> {
    Err(anyhow::anyhow!("UIA 仅支持 Windows"))
}

#[cfg(not(windows))]
pub fn invoke_request(_: &Value) -> Result<Value> {
    Err(anyhow::anyhow!("UIA 仅支持 Windows"))
}
