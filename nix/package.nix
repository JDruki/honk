{
  lib,
  cmake,
  git,
  honkEbpfObject,
  llvmPackages,
  pkg-config,
  perl,
  rustPlatform,
}:

let
  manifest = builtins.fromTOML (builtins.readFile ../Cargo.toml);
in
rustPlatform.buildRustPackage {
  pname = "honk-proxy";
  inherit (manifest.workspace.package) version;

  src = lib.cleanSource ../.;

  cargoLock = {
    lockFile = ../Cargo.lock;
    outputHashes = {
      "boring-sys-5.1.0" = "sha256-Tvf9qpUC6IO3ikkHO7BG0lp+ZGtu4DiS0HKKFdmjwjY=";
    };
  };

  nativeBuildInputs = [
    cmake
    git
    llvmPackages.clang
    llvmPackages.libclang
    pkg-config
    perl
  ];

  # Build the object independently: invoking rustup from build.rs is neither
  # available nor desirable inside a Nix sandbox.
  HONK_EBPF_OBJECT = "${honkEbpfObject}/lib/honk/honk-ebpf.o";
  LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";

  cargoBuildFlags = [
    "-p"
    "honk-core"
    "--features"
    "ebpf"
  ];

  doCheck = false;

  postInstall = ''
    install -Dm444 config.min.dae "$out/share/doc/honk-proxy/config.min.dae"
    install -Dm444 README.md "$out/share/doc/honk-proxy/README.md"
    install -Dm444 README_CN.md "$out/share/doc/honk-proxy/README_CN.md"
    install -Dm444 LICENSE "$out/share/licenses/honk-proxy/LICENSE"
  '';

  meta = {
    description = "Rust eBPF transparent proxy engine for Linux";
    homepage = "https://github.com/Glassyiris/honk";
    license = lib.licenses.gpl3Only;
    mainProgram = "honk-core";
    platforms = lib.platforms.linux;
  };
}
