use crate::{capture, input, ocr, recovery, ui_parser, uia};
use anyhow::Result;
use base64::Engine;
use base64::engine::general_purpose::STANDARD;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

#[derive(Debug, Deserialize)]
pub struct RpcRequest {
    pub id: u64,
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct RpcResponse {
    pub id: u64,
    pub ok: bool,
    #[serde(skip_serializing_if = "is_false")]
    pub progress: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<RpcError>,
}

#[derive(Debug, Serialize)]
pub struct RpcError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<Value>,
}

pub fn dispatch_with_progress<F>(line: &str, emit_progress: &mut F) -> RpcResponse
where
    F: FnMut(u64, Value),
{
    match serde_json::from_str::<RpcRequest>(line) {
        Ok(request) => handle_request(request, emit_progress),
        Err(err) => error(0, "bad_request", format!("无法解析请求: {err}"), None),
    }
}

fn handle_request<F>(request: RpcRequest, emit_progress: &mut F) -> RpcResponse
where
    F: FnMut(u64, Value),
{
    match request.method.as_str() {
        "ping" => ok(
            request.id,
            json!({
                "name": "hanako_windows_ops_sidecar",
                "platform": "windows",
                "capabilities": {
                    "screen_capture": true,
                    "uia": {
                        "tree": true,
                        "invoke": true
                    },
                    "input": {
                        "status": true,
                        "mouse": true,
                        "keyboard": true
                    },
                    "ocr": {
                        "bundle_status": true,
                        "status": true,
                        "recognize": true,
                        "runtime": "ocrs-rten"
                    },
                    "ui_parsing": {
                        "status": true,
                        "parse": true,
                        "engine": "rust-yolo-rs+ocrs"
                    },
                    "recovery": {
                        "status": true,
                        "search": true,
                        "backend": "rust_cpu"
                    }
                }
            }),
        ),
        "protocol.describe" => ok(
            request.id,
            json!({
                "transport": "stdin/stdout-jsonl",
                "methods": [
                    "ping",
                    "protocol.describe",
                    "screen.capture_region",
                    "input.status",
                    "input.mouse_move",
                    "input.mouse_click",
                    "input.text",
                    "uia.tree",
                    "uia.invoke",
                    "ocr.status",
                    "ocr.recognize",
                    "ui.status",
                    "ui.parse_base64",
                    "recovery.status",
                    "recovery.search"
                ]
            }),
        ),
        "screen.capture_region" => match capture::capture_region_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "capture_failed",
                err.to_string(),
                Some(json!({"method": "screen.capture_region"})),
            ),
        },
        "input.status" => match input::status_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "input_not_ready",
                err.to_string(),
                Some(json!({"method": "input.status"})),
            ),
        },
        "input.mouse_move" => match input::mouse_move_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "input_failed",
                err.to_string(),
                Some(json!({"method": "input.mouse_move"})),
            ),
        },
        "input.mouse_click" => match input::mouse_click_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "input_failed",
                err.to_string(),
                Some(json!({"method": "input.mouse_click"})),
            ),
        },
        "input.text" => match input::text_input_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "input_failed",
                err.to_string(),
                Some(json!({"method": "input.text"})),
            ),
        },
        "uia.tree" => match uia::tree_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "uia_not_ready",
                err.to_string(),
                Some(json!({"method": "uia.tree"})),
            ),
        },
        "uia.invoke" => match uia::invoke_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "uia_not_ready",
                err.to_string(),
                Some(json!({"method": "uia.invoke"})),
            ),
        },
        "ocr.recognize" => match ocr::recognize_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "ocr_not_ready",
                err.to_string(),
                Some(json!({"method": "ocr.recognize"})),
            ),
        },
        "ocr.status" => match ocr::status_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "ocr_not_ready",
                err.to_string(),
                Some(json!({"method": "ocr.status"})),
            ),
        },
        "ui.status" => match ui_parser::status_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "ui_parser_not_ready",
                err.to_string(),
                Some(json!({"method": "ui.status"})),
            ),
        },
        "ui.parse_base64" => match ui_parser::parse_base64_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "ui_parser_not_ready",
                err.to_string(),
                Some(json!({"method": "ui.parse_base64"})),
            ),
        },
        "recovery.status" => match recovery::status_request(&request.params) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "recovery_not_ready",
                err.to_string(),
                Some(json!({"method": "recovery.status"})),
            ),
        },
        "recovery.search" => match recovery::search_request(&request.params, &mut |progress| {
            emit_progress(request.id, progress);
        }) {
            Ok(result) => ok(request.id, result),
            Err(err) => error(
                request.id,
                "recovery_failed",
                err.to_string(),
                Some(json!({"method": "recovery.search"})),
            ),
        },
        other => error(
            request.id,
            "method_not_found",
            format!("未知方法: {other}"),
            None,
        ),
    }
}

fn ok(id: u64, result: Value) -> RpcResponse {
    RpcResponse {
        id,
        ok: true,
        progress: false,
        result: Some(result),
        error: None,
    }
}

fn error(id: u64, code: &str, message: String, details: Option<Value>) -> RpcResponse {
    RpcResponse {
        id,
        ok: false,
        progress: false,
        result: None,
        error: Some(RpcError {
            code: code.to_owned(),
            message,
            details,
        }),
    }
}

pub fn progress(id: u64, result: Value) -> RpcResponse {
    RpcResponse {
        id,
        ok: true,
        progress: true,
        result: Some(result),
        error: None,
    }
}

fn is_false(value: &bool) -> bool {
    !*value
}

pub fn encode_png_base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn decode_base64_image(input: &str) -> Result<Vec<u8>> {
    Ok(STANDARD.decode(input.trim())?)
}
