use anyhow::{Context, Result, anyhow};
use image::codecs::png::PngEncoder;
use image::{ColorType, ImageEncoder};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Deserialize)]
pub struct CaptureRegionRequest {
    pub x: i32,
    pub y: i32,
    pub width: i32,
    pub height: i32,
}

pub fn capture_region_request(params: &Value) -> Result<Value> {
    let request: CaptureRegionRequest = serde_json::from_value(params.clone())
        .context("screen.capture_region 需要 x/y/width/height")?;
    let png = capture_region_png(&request)?;
    Ok(json!({
        "mime_type": "image/png",
        "encoding": "base64",
        "width": request.width,
        "height": request.height,
        "data": crate::protocol::encode_png_base64(&png),
    }))
}

fn capture_region_png(request: &CaptureRegionRequest) -> Result<Vec<u8>> {
    if request.width <= 0 || request.height <= 0 {
        return Err(anyhow!("width/height 必须大于 0"));
    }

    let rgba = capture_region_rgba(request.x, request.y, request.width, request.height)?;
    let mut encoded = Vec::new();
    let encoder = PngEncoder::new(&mut encoded);
    encoder.write_image(
        &rgba,
        request.width as u32,
        request.height as u32,
        ColorType::Rgba8.into(),
    )?;
    Ok(encoded)
}

#[cfg(windows)]
fn capture_region_rgba(x: i32, y: i32, width: i32, height: i32) -> Result<Vec<u8>> {
    use std::ffi::c_void;
    use std::mem::size_of;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::Graphics::Gdi::*;

    let width_u32 = width as u32;
    let height_u32 = height as u32;

    let null_hwnd = HWND(std::ptr::null_mut());
    let screen_dc = unsafe { GetDC(null_hwnd) };
    if screen_dc.0.is_null() {
        return Err(anyhow!("无法获取屏幕 DC"));
    }

    let mem_dc = unsafe { CreateCompatibleDC(screen_dc) };
    if mem_dc.0.is_null() {
        unsafe {
            let _ = ReleaseDC(null_hwnd, screen_dc);
        }
        return Err(anyhow!("无法创建内存 DC"));
    }

    let bitmap = unsafe { CreateCompatibleBitmap(screen_dc, width, height) };
    if bitmap.0.is_null() {
        unsafe {
            let _ = DeleteDC(mem_dc);
            let _ = ReleaseDC(null_hwnd, screen_dc);
        }
        return Err(anyhow!("无法创建位图"));
    }

    let old_object = unsafe { SelectObject(mem_dc, bitmap) };
    if old_object.0.is_null() {
        unsafe {
            let _ = DeleteObject(bitmap);
            let _ = DeleteDC(mem_dc);
            let _ = ReleaseDC(null_hwnd, screen_dc);
        }
        return Err(anyhow!("无法选择位图到 DC"));
    }

    let copied = unsafe {
        BitBlt(
            mem_dc,
            0,
            0,
            width,
            height,
            screen_dc,
            x,
            y,
            SRCCOPY | CAPTUREBLT,
        )
    };
    if copied.is_err() {
        unsafe {
            SelectObject(mem_dc, old_object);
            let _ = DeleteObject(bitmap);
            let _ = DeleteDC(mem_dc);
            let _ = ReleaseDC(null_hwnd, screen_dc);
        }
        return Err(anyhow!("BitBlt 失败"));
    }

    let mut bmi = BITMAPINFO::default();
    bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
    bmi.bmiHeader.biWidth = width;
    bmi.bmiHeader.biHeight = -height;
    bmi.bmiHeader.biPlanes = 1;
    bmi.bmiHeader.biBitCount = 32;
    bmi.bmiHeader.biCompression = BI_RGB.0;

    let mut pixels = vec![0u8; (width_u32 * height_u32 * 4) as usize];
    let lines = unsafe {
        GetDIBits(
            mem_dc,
            bitmap,
            0,
            height_u32,
            Some(pixels.as_mut_ptr() as *mut c_void),
            &mut bmi,
            DIB_RGB_COLORS,
        )
    };
    unsafe {
        SelectObject(mem_dc, old_object);
        let _ = DeleteObject(bitmap);
        let _ = DeleteDC(mem_dc);
        let _ = ReleaseDC(null_hwnd, screen_dc);
    }
    if lines == 0 {
        return Err(anyhow!("GetDIBits 失败"));
    }

    for chunk in pixels.chunks_exact_mut(4) {
        chunk.swap(0, 2);
    }
    Ok(pixels)
}

#[cfg(not(windows))]
fn capture_region_rgba(_: i32, _: i32, _: i32, _: i32) -> Result<Vec<u8>> {
    Err(anyhow!("screen.capture_region 仅支持 Windows"))
}
