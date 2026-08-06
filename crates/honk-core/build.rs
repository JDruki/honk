//! Build script for honk-core.
//!
//! When the `ebpf` feature is enabled, this script ensures the eBPF object
//! file is available and copies it into `OUT_DIR` so `lib.rs` can embed it
//! via `include_bytes!`.  If the object does not exist yet, it is built
//! automatically using the nightly toolchain.

fn main() {
    #[cfg(feature = "ebpf")]
    embed_ebpf_object();
}

#[cfg(feature = "ebpf")]
fn embed_ebpf_object() {
    use std::path::{Path, PathBuf};
    use std::process::Command;

    println!("cargo:rerun-if-env-changed=HONK_EBPF_OBJECT");
    println!("cargo:rerun-if-env-changed=HONK_EBPF_CARGO");
    println!("cargo:rerun-if-env-changed=HONK_EBPF_RUSTC");

    let manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    let ebpf_crate = manifest_dir.join("../honk-ebpf");
    let ebpf_common_crate = manifest_dir.join("../honk-ebpf-common");
    let ebpf_target = ebpf_crate.join("target/bpfel-unknown-none/release/honk-ebpf");

    /// aya refuses objects without a `.BTF` section ("no BTF parsed for
    /// object"). Cheap guard: section names live verbatim in the section
    /// header string table, so a byte search for the NUL-terminated name is
    /// sufficient.
    fn object_has_btf(path: &Path) -> bool {
        std::fs::read(path)
            .map(|data| {
                data.windows(5).any(|w| w == b".BTF\0") || data.windows(5).any(|w| w == b".BTF.")
            })
            .unwrap_or(false)
    }

    /// Newest mtime under `dir` (recursive). The eBPF object is built by a
    /// separate cargo invocation, so cargo's own change tracking never
    /// rebuilds it — without this check a stale object from hours ago gets
    /// embedded while the sources have moved on (observed twice: missing maps
    /// at runtime while the build looks green).
    fn newest_mtime(dir: &Path) -> Option<std::time::SystemTime> {
        let mut newest = None;
        let mut stack = vec![dir.to_path_buf()];
        while let Some(d) = stack.pop() {
            for entry in std::fs::read_dir(&d).ok()?.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else if let Ok(meta) = path.metadata()
                    && let Ok(mtime) = meta.modified()
                    && newest.is_none_or(|n| mtime > n)
                {
                    newest = Some(mtime);
                }
            }
        }
        newest
    }

    fn object_stale(obj: &Path, src_dirs: &[&Path]) -> bool {
        let Ok(obj_mtime) = obj.metadata().and_then(|m| m.modified()) else {
            return true;
        };
        src_dirs
            .iter()
            .filter_map(|d| newest_mtime(d))
            .any(|src_mtime| src_mtime > obj_mtime)
    }

    // Packaging systems can build the standalone eBPF crate separately and
    // pass its immutable output here. This avoids having the userspace crate
    // invoke rustup (and, transitively, download a nightly toolchain) inside
    // a sandboxed build. It is also useful to distributors that package the
    // object and binary independently.
    if let Some(obj) = std::env::var_os("HONK_EBPF_OBJECT").map(PathBuf::from) {
        if !obj.is_file() {
            panic!(
                "HONK_EBPF_OBJECT points to a missing file: {}",
                obj.display()
            );
        }
        if !object_has_btf(&obj) {
            panic!(
                "HONK_EBPF_OBJECT at {} has no .BTF section — aya cannot load it",
                obj.display()
            );
        }

        let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
        let dest = out_dir.join("honk-ebpf.o");
        std::fs::copy(&obj, &dest)
            .unwrap_or_else(|e| panic!("copy {} -> {}: {e}", obj.display(), dest.display()));
        println!("cargo:rerun-if-changed={}", obj.display());
        println!("cargo:rustc-env=HONK_EBPF_OBJECT={}", dest.display());
        println!(
            "cargo:warning=external eBPF object embedded ({} bytes)",
            obj.metadata().map(|m| m.len()).unwrap_or(0)
        );
        return;
    }

    let candidates = [
        ebpf_target.clone(),
        manifest_dir.join("../../target/honk-core.o"),
    ];

    let obj = candidates.iter().find(|p| p.exists()).cloned();
    let src_dirs = [ebpf_crate.join("src"), ebpf_common_crate.join("src")];

    let obj = match obj {
        Some(p)
            if object_has_btf(&p)
                && !object_stale(
                    &p,
                    &src_dirs.iter().map(|d| d.as_path()).collect::<Vec<_>>(),
                ) =>
        {
            println!("cargo:rerun-if-changed={}", p.display());
            p
        }
        stale => {
            if let Some(p) = &stale
                && p.exists()
                && object_has_btf(p)
            {
                println!(
                    "cargo:warning=eBPF object at {} is older than the eBPF sources — rebuilding",
                    p.display()
                );
            }
            // Missing, or stale without .BTF (e.g. built while an environment
            // RUSTFLAGS overrode crates/honk-ebpf/.cargo/config.toml): (re)build.
            println!("cargo:warning=Building eBPF object (one-time, ~30s)...");
            let ebpf_cargo = std::env::var_os("HONK_EBPF_CARGO");
            let cargo = ebpf_cargo
                .as_deref()
                .unwrap_or_else(|| std::ffi::OsStr::new("cargo"));
            let mut command = Command::new(cargo);
            if ebpf_cargo.is_some() {
                command.args([
                    "build",
                    "--release",
                    "-Zbuild-std=core",
                    "--target",
                    "bpfel-unknown-none",
                ]);
            } else {
                command.args([
                    "+nightly",
                    "build",
                    "--release",
                    "-Zbuild-std=core",
                    "--target",
                    "bpfel-unknown-none",
                ]);
            }
            if let Some(rustc) = std::env::var_os("HONK_EBPF_RUSTC") {
                command.env("RUSTC", rustc);
            }
            let status = command
                // An inherited RUSTFLAGS would override the crate's
                // .cargo/config.toml rustflags (--btf, debuginfo) and silently
                // produce a BTF-less object again.
                .env_remove("RUSTFLAGS")
                .env_remove("CARGO_ENCODED_RUSTFLAGS")
                .current_dir(&ebpf_crate)
                .status()
                .expect("failed to build eBPF object");

            if !status.success() {
                panic!(
                    "eBPF build failed. Build manually:\n  \
                     cd crates/honk-ebpf && cargo +nightly build --release \
                     -Zbuild-std=core --target bpfel-unknown-none"
                );
            }
            if !object_has_btf(&ebpf_target) {
                panic!(
                    "eBPF object at {} has no .BTF section — aya cannot load it. \
                     Rebuild manually:\n  \
                     cd crates/honk-ebpf && cargo +nightly build --release \
                     -Zbuild-std=core --target bpfel-unknown-none",
                    ebpf_target.display()
                );
            }
            println!("cargo:rerun-if-changed={}", ebpf_target.display());
            ebpf_target
        }
    };

    let out_dir = PathBuf::from(std::env::var("OUT_DIR").unwrap());
    let dest = out_dir.join("honk-ebpf.o");
    std::fs::copy(&obj, &dest)
        .unwrap_or_else(|e| panic!("copy {} -> {}: {}", obj.display(), dest.display(), e));

    println!(
        "cargo:rerun-if-changed={}",
        ebpf_crate.join("src").display()
    );
    // Track all individual eBPF source files for rebuild
    let ebpf_src = ebpf_crate.join("src");
    if ebpf_src.is_dir() {
        for entry in std::fs::read_dir(&ebpf_src).unwrap() {
            let entry = entry.unwrap();
            println!("cargo:rerun-if-changed={}", entry.path().display());
        }
    }
    println!(
        "cargo:rerun-if-changed={}",
        ebpf_common_crate.join("src").display()
    );
    println!("cargo:rustc-env=HONK_EBPF_OBJECT={}", dest.display());
    println!(
        "cargo:warning=eBPF object embedded ({} bytes)",
        obj.metadata().map(|m| m.len()).unwrap_or(0)
    );
}
