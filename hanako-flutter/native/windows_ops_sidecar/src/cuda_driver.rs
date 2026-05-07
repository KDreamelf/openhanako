use anyhow::{Context, Result, anyhow, bail};
use libloading::Library;
use std::ffi::{CString, c_char, c_int, c_uint, c_void};
use std::ptr;

type CuResult = c_int;
type CuDevice = c_int;
type CuContext = *mut c_void;
type CuModule = *mut c_void;
type CuFunction = *mut c_void;
type CuStream = *mut c_void;
type CuDevicePtr = u64;

const CUDA_SUCCESS: CuResult = 0;

type CuInit = unsafe extern "C" fn(c_uint) -> CuResult;
type CuDriverGetVersion = unsafe extern "C" fn(*mut c_int) -> CuResult;
type CuDeviceGetCount = unsafe extern "C" fn(*mut c_int) -> CuResult;
type CuDeviceGet = unsafe extern "C" fn(*mut CuDevice, c_int) -> CuResult;
type CuDeviceGetName = unsafe extern "C" fn(*mut c_char, c_int, CuDevice) -> CuResult;
type CuDeviceComputeCapability = unsafe extern "C" fn(*mut c_int, *mut c_int, CuDevice) -> CuResult;
type CuCtxCreate = unsafe extern "C" fn(*mut CuContext, c_uint, CuDevice) -> CuResult;
type CuCtxDestroy = unsafe extern "C" fn(CuContext) -> CuResult;
type CuModuleLoadData = unsafe extern "C" fn(*mut CuModule, *const c_void) -> CuResult;
type CuModuleUnload = unsafe extern "C" fn(CuModule) -> CuResult;
type CuModuleGetFunction =
    unsafe extern "C" fn(*mut CuFunction, CuModule, *const c_char) -> CuResult;
type CuMemAlloc = unsafe extern "C" fn(*mut CuDevicePtr, usize) -> CuResult;
type CuMemFree = unsafe extern "C" fn(CuDevicePtr) -> CuResult;
type CuMemcpyHtoD = unsafe extern "C" fn(CuDevicePtr, *const c_void, usize) -> CuResult;
type CuMemcpyDtoH = unsafe extern "C" fn(*mut c_void, CuDevicePtr, usize) -> CuResult;
type CuLaunchKernel = unsafe extern "C" fn(
    CuFunction,
    c_uint,
    c_uint,
    c_uint,
    c_uint,
    c_uint,
    c_uint,
    c_uint,
    CuStream,
    *mut *mut c_void,
    *mut *mut c_void,
) -> CuResult;
type CuCtxSynchronize = unsafe extern "C" fn() -> CuResult;

pub struct CudaStatus {
    pub available: bool,
    pub reason: Option<String>,
    pub device_name: Option<String>,
    pub compute_capability: Option<String>,
    pub driver_version: Option<i32>,
}

pub struct CudaBackend {
    _lib: Library,
    api: CudaApi,
    context: CuContext,
    module: CuModule,
    function: CuFunction,
    device_name: String,
    compute_capability: String,
    driver_version: i32,
}

struct CudaApi {
    cu_ctx_destroy: CuCtxDestroy,
    cu_module_unload: CuModuleUnload,
    cu_mem_alloc: CuMemAlloc,
    cu_mem_free: CuMemFree,
    cu_memcpy_htod: CuMemcpyHtoD,
    cu_memcpy_dtoh: CuMemcpyDtoH,
    cu_launch_kernel: CuLaunchKernel,
    cu_ctx_synchronize: CuCtxSynchronize,
}

impl CudaBackend {
    pub fn status() -> CudaStatus {
        match Self::new() {
            Ok(backend) => CudaStatus {
                available: true,
                reason: None,
                device_name: Some(backend.device_name.clone()),
                compute_capability: Some(backend.compute_capability.clone()),
                driver_version: Some(backend.driver_version),
            },
            Err(err) => CudaStatus {
                available: false,
                reason: Some(err.to_string()),
                device_name: None,
                compute_capability: None,
                driver_version: None,
            },
        }
    }

    pub fn new() -> Result<Self> {
        let module_data = cuda_module_data()?;
        let lib = unsafe { Library::new("nvcuda.dll") }
            .or_else(|_| unsafe { Library::new("cuda.dll") })
            .context("NVIDIA CUDA driver library nvcuda.dll not available")?;

        unsafe {
            let cu_init: CuInit = load(&lib, b"cuInit\0")?;
            let cu_driver_get_version: CuDriverGetVersion = load(&lib, b"cuDriverGetVersion\0")?;
            let cu_device_get_count: CuDeviceGetCount = load(&lib, b"cuDeviceGetCount\0")?;
            let cu_device_get: CuDeviceGet = load(&lib, b"cuDeviceGet\0")?;
            let cu_device_get_name: CuDeviceGetName = load(&lib, b"cuDeviceGetName\0")?;
            let cu_device_compute_capability: CuDeviceComputeCapability =
                load(&lib, b"cuDeviceComputeCapability\0")?;
            let cu_ctx_create: CuCtxCreate = load(&lib, b"cuCtxCreate_v2\0")?;
            let cu_ctx_destroy: CuCtxDestroy = load(&lib, b"cuCtxDestroy_v2\0")?;
            let cu_module_load_data: CuModuleLoadData = load(&lib, b"cuModuleLoadData\0")?;
            let cu_module_unload: CuModuleUnload = load(&lib, b"cuModuleUnload\0")?;
            let cu_module_get_function: CuModuleGetFunction = load(&lib, b"cuModuleGetFunction\0")?;
            let cu_mem_alloc: CuMemAlloc = load(&lib, b"cuMemAlloc_v2\0")?;
            let cu_mem_free: CuMemFree = load(&lib, b"cuMemFree_v2\0")?;
            let cu_memcpy_htod: CuMemcpyHtoD = load(&lib, b"cuMemcpyHtoD_v2\0")?;
            let cu_memcpy_dtoh: CuMemcpyDtoH = load(&lib, b"cuMemcpyDtoH_v2\0")?;
            let cu_launch_kernel: CuLaunchKernel = load(&lib, b"cuLaunchKernel\0")?;
            let cu_ctx_synchronize: CuCtxSynchronize = load(&lib, b"cuCtxSynchronize\0")?;

            check(cu_init(0), "cuInit")?;
            let mut driver_version = 0;
            check(
                cu_driver_get_version(&mut driver_version),
                "cuDriverGetVersion",
            )?;

            let mut device_count = 0;
            check(cu_device_get_count(&mut device_count), "cuDeviceGetCount")?;
            if device_count <= 0 {
                bail!("no CUDA-capable NVIDIA device found");
            }

            let mut device = 0;
            check(cu_device_get(&mut device, 0), "cuDeviceGet")?;

            let mut name_buf = [0i8; 128];
            check(
                cu_device_get_name(name_buf.as_mut_ptr(), name_buf.len() as c_int, device),
                "cuDeviceGetName",
            )?;
            let nul = name_buf
                .iter()
                .position(|value| *value == 0)
                .unwrap_or(name_buf.len());
            let device_name = String::from_utf8_lossy(
                &name_buf[..nul].iter().map(|c| *c as u8).collect::<Vec<_>>(),
            )
            .to_string();

            let mut major = 0;
            let mut minor = 0;
            check(
                cu_device_compute_capability(&mut major, &mut minor, device),
                "cuDeviceComputeCapability",
            )?;
            let compute_capability = format!("{major}.{minor}");

            let mut context = ptr::null_mut();
            check(cu_ctx_create(&mut context, 0, device), "cuCtxCreate_v2")?;

            let mut module = ptr::null_mut();
            check(
                cu_module_load_data(&mut module, module_data.as_ptr().cast()),
                "cuModuleLoadData",
            )?;

            let mut function = ptr::null_mut();
            let function_name = CString::new("pbkdf2_sha512_kernel").unwrap();
            check(
                cu_module_get_function(&mut function, module, function_name.as_ptr()),
                "cuModuleGetFunction",
            )?;

            Ok(Self {
                _lib: lib,
                api: CudaApi {
                    cu_ctx_destroy,
                    cu_module_unload,
                    cu_mem_alloc,
                    cu_mem_free,
                    cu_memcpy_htod,
                    cu_memcpy_dtoh,
                    cu_launch_kernel,
                    cu_ctx_synchronize,
                },
                context,
                module,
                function,
                device_name,
                compute_capability,
                driver_version,
            })
        }
    }

    pub fn device_name(&self) -> &str {
        &self.device_name
    }

    pub fn compute_capability(&self) -> &str {
        &self.compute_capability
    }

    pub fn pbkdf2_batch(&self, mnemonics: &[Vec<u8>]) -> Result<Vec<[u8; 64]>> {
        if mnemonics.is_empty() {
            return Ok(Vec::new());
        }
        let count = mnemonics.len() as u32;
        let mut input = Vec::new();
        let mut offsets = Vec::with_capacity(mnemonics.len());
        let mut lengths = Vec::with_capacity(mnemonics.len());
        for mnemonic in mnemonics {
            offsets.push(input.len() as u32);
            lengths.push(mnemonic.len() as u32);
            input.extend_from_slice(mnemonic);
        }
        let output_len = mnemonics.len() * 64;

        unsafe {
            let d_input = DeviceBuffer::new(&self.api, input.len())?;
            let d_offsets = DeviceBuffer::new(&self.api, offsets.len() * size_of::<u32>())?;
            let d_lengths = DeviceBuffer::new(&self.api, lengths.len() * size_of::<u32>())?;
            let d_output = DeviceBuffer::new(&self.api, output_len)?;

            copy_to_device(&self.api, d_input.ptr, &input)?;
            copy_to_device(&self.api, d_offsets.ptr, as_bytes(&offsets))?;
            copy_to_device(&self.api, d_lengths.ptr, as_bytes(&lengths))?;

            let mut p_input = d_input.ptr;
            let mut p_offsets = d_offsets.ptr;
            let mut p_lengths = d_lengths.ptr;
            let mut p_count = count;
            let mut p_output = d_output.ptr;
            let mut params = [
                (&mut p_input as *mut CuDevicePtr).cast::<c_void>(),
                (&mut p_offsets as *mut CuDevicePtr).cast::<c_void>(),
                (&mut p_lengths as *mut CuDevicePtr).cast::<c_void>(),
                (&mut p_count as *mut u32).cast::<c_void>(),
                (&mut p_output as *mut CuDevicePtr).cast::<c_void>(),
            ];
            let block = 128u32;
            let grid = count.div_ceil(block);
            check(
                (self.api.cu_launch_kernel)(
                    self.function,
                    grid,
                    1,
                    1,
                    block,
                    1,
                    1,
                    0,
                    ptr::null_mut(),
                    params.as_mut_ptr(),
                    ptr::null_mut(),
                ),
                "cuLaunchKernel",
            )?;
            check((self.api.cu_ctx_synchronize)(), "cuCtxSynchronize")?;

            let mut output = vec![0u8; output_len];
            check(
                (self.api.cu_memcpy_dtoh)(output.as_mut_ptr().cast(), d_output.ptr, output_len),
                "cuMemcpyDtoH_v2",
            )?;
            Ok(output
                .chunks_exact(64)
                .map(|chunk| {
                    let mut seed = [0u8; 64];
                    seed.copy_from_slice(chunk);
                    seed
                })
                .collect())
        }
    }
}

impl Drop for CudaBackend {
    fn drop(&mut self) {
        unsafe {
            let _ = (self.api.cu_module_unload)(self.module);
            let _ = (self.api.cu_ctx_destroy)(self.context);
        }
    }
}

struct DeviceBuffer<'a> {
    api: &'a CudaApi,
    ptr: CuDevicePtr,
}

impl<'a> DeviceBuffer<'a> {
    unsafe fn new(api: &'a CudaApi, bytes: usize) -> Result<Self> {
        let mut ptr = 0;
        check(
            unsafe { (api.cu_mem_alloc)(&mut ptr, bytes) },
            "cuMemAlloc_v2",
        )?;
        Ok(Self { api, ptr })
    }
}

impl Drop for DeviceBuffer<'_> {
    fn drop(&mut self) {
        unsafe {
            let _ = (self.api.cu_mem_free)(self.ptr);
        }
    }
}

unsafe fn load<T: Copy>(lib: &Library, name: &[u8]) -> Result<T> {
    let symbol = unsafe { lib.get::<T>(name) }.with_context(|| {
        format!(
            "missing CUDA driver symbol {}",
            String::from_utf8_lossy(name)
        )
    })?;
    Ok(*symbol)
}

unsafe fn copy_to_device(api: &CudaApi, dst: CuDevicePtr, data: &[u8]) -> Result<()> {
    check(
        unsafe { (api.cu_memcpy_htod)(dst, data.as_ptr().cast(), data.len()) },
        "cuMemcpyHtoD_v2",
    )
}

fn check(result: CuResult, label: &str) -> Result<()> {
    if result == CUDA_SUCCESS {
        Ok(())
    } else {
        Err(anyhow!("{label} failed with CUDA error {result}"))
    }
}

fn cuda_module_data() -> Result<&'static [u8]> {
    #[cfg(hanako_cuda_fatbin)]
    {
        Ok(include_bytes!(env!("HANAKO_CUDA_FATBIN")))
    }
    #[cfg(not(hanako_cuda_fatbin))]
    {
        bail!("CUDA fatbin was not built; install CUDA Toolkit with nvcc on the build machine")
    }
}

fn as_bytes(values: &[u32]) -> &[u8] {
    unsafe { std::slice::from_raw_parts(values.as_ptr().cast(), std::mem::size_of_val(values)) }
}
