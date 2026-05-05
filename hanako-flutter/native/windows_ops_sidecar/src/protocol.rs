use crate::{capture, ocr, ui_parser, uia};
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

pub fn dispatch(line: &str) -> RpcResponse {
    match serde_json::from_str::<RpcRequest>(line) {
        Ok(request) => handle_request(request),
        Err(err) => error(0, "bad_request", format!("无法解析请求: {err}"), None),
    }
}

fn handle_request(request: RpcRequest) -> RpcResponse {
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
                    "uia.tree",
                    "uia.invoke",
                    "ocr.status",
                    "ocr.recognize",
                    "ui.status",
                    "ui.parse_base64"
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
        result: Some(result),
        error: None,
    }
}

fn error(id: u64, code: &str, message: String, details: Option<Value>) -> RpcResponse {
    RpcResponse {
        id,
        ok: false,
        result: None,
        error: Some(RpcError {
            code: code.to_owned(),
            message,
            details,
        }),
    }
}

pub fn encode_png_base64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

pub fn decode_base64_image(input: &str) -> Result<Vec<u8>> {
    Ok(STANDARD.decode(input.trim())?)
}
