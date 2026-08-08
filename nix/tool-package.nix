{
  cmake,
  lib,
  git,
  llvmPackages,
  pkg-config,
  perl,
  rustPlatform,
}:

let
  manifest = builtins.fromTOML (builtins.readFile ../Cargo.toml);
in
rustPlatform.buildRustPackage {
  pname = "honk-tool";
  inherit (manifest.workspace.package) version;

  src = lib.cleanSource ../.;

  cargoLock = {
    lockFile = ../Cargo.lock;
    outputHashes = {
      "boring-sys-5.1.0" = "sha256-CjKtJNqfv7codFiIzushlAQDy/iVqe2EChWRZamsCLQ=";
    };
  };

  cargoBuildFlags = [
    "-p"
    "honk-tool"
  ];

  # honk-tool depends on honk-outbound, so it builds BoringSSL as well. Keep
  # this in sync with the main package's native build environment.
  nativeBuildInputs = [
    cmake
    git
    llvmPackages.clang
    llvmPackages.libclang
    pkg-config
    perl
  ];

  LIBCLANG_PATH = "${llvmPackages.libclang.lib}/lib";

  doCheck = false;

  meta = {
    description = "CLI toolbox for honk subscriptions, node probes, and geo assets";
    homepage = "https://github.com/Glassyiris/honk";
    license = lib.licenses.gpl3Only;
    mainProgram = "honk-tool";
    platforms = lib.platforms.linux;
  };
}
