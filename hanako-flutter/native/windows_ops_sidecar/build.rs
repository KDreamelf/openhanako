use std::env;
use std::path::{Path, PathBuf};
use std::process::Command;

fn main() {
    println!("cargo:rustc-check-cfg=cfg(hanako_cuda_fatbin)");
    println!("cargo:rerun-if-changed=src/cuda/pbkdf2_sha512.cu");

    let Some(nvcc) = find_nvcc() else {
        println!("cargo:warning=CUDA Toolkit nvcc not found; building rust_cpu recovery only");
        return;
    };

    let out_dir = PathBuf::from(env::var("OUT_DIR").expect("OUT_DIR must be set"));
    let fatbin_path = out_dir.join("pbkdf2_sha512.fatbin");
    let source = PathBuf::from("src/cuda/pbkdf2_sha512.cu");

    let mut command = Command::new(&nvcc);
    command
        .arg("-fatbin")
        .arg("-O3")
        .arg("-Xcompiler=/utf-8")
        .arg("-gencode=arch=compute_75,code=sm_75")
        .arg("-o")
        .arg(&fatbin_path)
        .arg(&source);
    if let Some(ccbin) = find_msvc_cl_dir() {
        command.arg("-ccbin").arg(ccbin);
    }

    match command.status() {
        Ok(status) if status.success() => {
            println!("cargo:rustc-cfg=hanako_cuda_fatbin");
            println!(
                "cargo:rustc-env=HANAKO_CUDA_FATBIN={}",
                fatbin_path.display()
            );
        }
        Ok(status) => {
            println!(
                "cargo:warning=nvcc failed with status {status}; building rust_cpu recovery only"
            );
        }
        Err(err) => {
            println!("cargo:warning=failed to run nvcc ({err}); building rust_cpu recovery only");
        }
    }
}

fn find_nvcc() -> Option<PathBuf> {
    if let Some(path) = find_on_path("nvcc.exe") {
        return Some(path);
    }
    for key in ["CUDA_PATH", "CUDA_HOME"] {
        if let Ok(root) = env::var(key) {
            let candidate = Path::new(&root).join("bin/nvcc.exe");
            if candidate.exists() {
                return Some(candidate);
            }
        }
    }
    for root in [
        r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2",
        r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.1",
        r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.0",
        r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9",
        r"C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.8",
    ] {
        let candidate = Path::new(root).join("bin/nvcc.exe");
        if candidate.exists() {
            return Some(candidate);
        }
    }
    None
}

fn find_msvc_cl_dir() -> Option<PathBuf> {
    let base =
        Path::new(r"C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Tools\MSVC");
    let entries = std::fs::read_dir(base).ok()?;
    let mut versions = entries
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect::<Vec<_>>();
    versions.sort();
    versions.reverse();
    for version in versions {
        let cl_dir = version.join("bin/Hostx64/x64");
        if cl_dir.join("cl.exe").exists() {
            return Some(cl_dir);
        }
    }
    None
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let paths = env::var_os("PATH")?;
    env::split_paths(&paths)
        .map(|path| path.join(name))
        .find(|candidate| candidate.exists())
}
