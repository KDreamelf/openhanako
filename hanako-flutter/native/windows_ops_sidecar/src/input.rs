use anyhow::Result;
use serde_json::Value;

#[cfg(windows)]
mod windows_input {
    use anyhow::{Context, Result, anyhow};
    use serde::Deserialize;
    use serde_json::{Value, json};
    use std::mem::size_of;
    use std::thread;
    use std::time::Duration;
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        INPUT, INPUT_0, INPUT_KEYBOARD, INPUT_MOUSE, KEYBDINPUT, KEYEVENTF_KEYUP,
        KEYEVENTF_UNICODE, MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP, MOUSEEVENTF_MIDDLEDOWN,
        MOUSEEVENTF_MIDDLEUP, MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP, MOUSEINPUT, SendInput,
        VIRTUAL_KEY,
    };
    use windows::Win32::UI::WindowsAndMessaging::SetCursorPos;

    #[derive(Debug, Deserialize)]
    struct MouseMoveRequest {
        x: i32,
        y: i32,
    }

    #[derive(Debug, Deserialize)]
    struct MouseClickRequest {
        x: i32,
        y: i32,
        #[serde(default = "default_button")]
        button: String,
        #[serde(default = "default_clicks")]
        clicks: u32,
        #[serde(default)]
        interval_ms: u64,
    }

    #[derive(Debug, Deserialize)]
    struct TextInputRequest {
        text: String,
        #[serde(default)]
        press_enter: bool,
    }

    fn default_button() -> String {
        "left".to_owned()
    }

    fn default_clicks() -> u32 {
        1
    }

    pub fn status_request(_: &Value) -> Result<Value> {
        Ok(json!({
            "available": true,
            "mouse": true,
            "keyboard": true,
        }))
    }

    pub fn mouse_move_request(params: &Value) -> Result<Value> {
        let request: MouseMoveRequest =
            serde_json::from_value(params.clone()).context("input.mouse_move 参数错误")?;
        unsafe {
            SetCursorPos(request.x, request.y).context("移动鼠标失败")?;
        }
        Ok(json!({
            "moved": true,
            "point": {"x": request.x, "y": request.y},
        }))
    }

    pub fn mouse_click_request(params: &Value) -> Result<Value> {
        let mut request: MouseClickRequest =
            serde_json::from_value(params.clone()).context("input.mouse_click 参数错误")?;
        request.clicks = request.clicks.clamp(1, 5);
        unsafe {
            SetCursorPos(request.x, request.y).context("点击前移动鼠标失败")?;
        }
        let (down, up) = button_flags(&request.button)?;
        for index in 0..request.clicks {
            send_mouse_flag(down)?;
            send_mouse_flag(up)?;
            if request.interval_ms > 0 && index + 1 < request.clicks {
                thread::sleep(Duration::from_millis(request.interval_ms.min(1000)));
            }
        }
        Ok(json!({
            "clicked": true,
            "button": request.button,
            "clicks": request.clicks,
            "point": {"x": request.x, "y": request.y},
        }))
    }

    pub fn text_input_request(params: &Value) -> Result<Value> {
        let request: TextInputRequest =
            serde_json::from_value(params.clone()).context("input.text 参数错误")?;
        type_text(&request.text)?;
        if request.press_enter {
            type_text("\n")?;
        }
        Ok(json!({
            "typed": true,
            "chars": request.text.chars().count(),
            "press_enter": request.press_enter,
        }))
    }

    fn button_flags(
        button: &str,
    ) -> Result<(
        windows::Win32::UI::Input::KeyboardAndMouse::MOUSE_EVENT_FLAGS,
        windows::Win32::UI::Input::KeyboardAndMouse::MOUSE_EVENT_FLAGS,
    )> {
        match button.trim().to_ascii_lowercase().as_str() {
            "left" => Ok((MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP)),
            "right" => Ok((MOUSEEVENTF_RIGHTDOWN, MOUSEEVENTF_RIGHTUP)),
            "middle" => Ok((MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP)),
            other => Err(anyhow!("不支持的鼠标按键: {other}")),
        }
    }

    fn send_mouse_flag(
        flag: windows::Win32::UI::Input::KeyboardAndMouse::MOUSE_EVENT_FLAGS,
    ) -> Result<()> {
        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 {
                mi: MOUSEINPUT {
                    dx: 0,
                    dy: 0,
                    mouseData: 0,
                    dwFlags: flag,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        let sent = unsafe { SendInput(&mut [input], size_of::<INPUT>() as i32) };
        if sent == 0 {
            return Err(anyhow!("发送鼠标输入失败"));
        }
        Ok(())
    }

    fn type_text(text: &str) -> Result<()> {
        for unit in text.encode_utf16() {
            send_unicode_key(unit, false)?;
            send_unicode_key(unit, true)?;
        }
        Ok(())
    }

    fn send_unicode_key(scan: u16, key_up: bool) -> Result<()> {
        let flags = if key_up {
            KEYEVENTF_UNICODE | KEYEVENTF_KEYUP
        } else {
            KEYEVENTF_UNICODE
        };
        let input = INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT {
                    wVk: VIRTUAL_KEY(0),
                    wScan: scan,
                    dwFlags: flags,
                    time: 0,
                    dwExtraInfo: 0,
                },
            },
        };
        let sent = unsafe { SendInput(&mut [input], size_of::<INPUT>() as i32) };
        if sent == 0 {
            return Err(anyhow!("发送键盘输入失败"));
        }
        Ok(())
    }
}

#[cfg(windows)]
pub fn status_request(params: &Value) -> Result<Value> {
    windows_input::status_request(params)
}

#[cfg(windows)]
pub fn mouse_move_request(params: &Value) -> Result<Value> {
    windows_input::mouse_move_request(params)
}

#[cfg(windows)]
pub fn mouse_click_request(params: &Value) -> Result<Value> {
    windows_input::mouse_click_request(params)
}

#[cfg(windows)]
pub fn text_input_request(params: &Value) -> Result<Value> {
    windows_input::text_input_request(params)
}

#[cfg(not(windows))]
pub fn status_request(_: &Value) -> Result<Value> {
    Err(anyhow::anyhow!("输入控制仅支持 Windows"))
}

#[cfg(not(windows))]
pub fn mouse_move_request(_: &Value) -> Result<Value> {
    Err(anyhow::anyhow!("输入控制仅支持 Windows"))
}

#[cfg(not(windows))]
pub fn mouse_click_request(_: &Value) -> Result<Value> {
    Err(anyhow::anyhow!("输入控制仅支持 Windows"))
}

#[cfg(not(windows))]
pub fn text_input_request(_: &Value) -> Result<Value> {
    Err(anyhow::anyhow!("输入控制仅支持 Windows"))
}
