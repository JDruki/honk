{
  lib,
  bpf-linker,
  rustPlatform,
  rustToolchain,
}:

let
  manifest = builtins.fromTOML (builtins.readFile ../Cargo.toml);
in
rustPlatform.buildRustPackage {
  pname = "honk-ebpf";
  inherit (manifest.workspace.package) version;

  src = lib.cleanSource ../.;
  sourceRoot = "source/crates/honk-ebpf";

  cargoLock = {
    lockFile = ../crates/honk-ebpf/Cargo.lock;
  };

  nativeBuildInputs = [ bpf-linker ];

  # The crate is intentionally outside the workspace and needs build-std for
  # bpfel-unknown-none. Its .cargo config selects bpf-linker from PATH.
  buildPhase = ''
    runHook preBuild

    # buildRustPackage replaces crates.io with this derivation's vendor tree.
    # `-Zbuild-std=core` also resolves crates from the nightly sysroot (for
    # example rustc-literal-escaper), which are intentionally absent from
    # honk-ebpf's Cargo.lock. Add the toolchain's already-vendored std crates
    # to the same offline source; symlinks retain Nix's immutability and avoid
    # copying them into every eBPF build.
    rustStdVendor="${rustToolchain}/lib/rustlib/src/rust/library/vendor"
    for crate in "$rustStdVendor"/*; do
      name="$(basename "$crate")"
      if [ ! -e "$NIX_BUILD_TOP/cargo-vendor-dir/$name" ]; then
        ln -s "$crate" "$NIX_BUILD_TOP/cargo-vendor-dir/$name"
      fi
    done

    cargo build --offline --locked --release -Zbuild-std=core --target bpfel-unknown-none
    runHook postBuild
  '';

  doCheck = false;

  installPhase = ''
    runHook preInstall
    install -Dm444 target/bpfel-unknown-none/release/honk-ebpf "$out/lib/honk/honk-ebpf.o"
    runHook postInstall
  '';

  meta = {
    description = "eBPF datapath object for honk";
    homepage = "https://github.com/Glassyiris/honk";
    license = lib.licenses.gpl3Only;
    platforms = lib.platforms.linux;
  };
}
