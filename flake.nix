{
  description = "Nix flake for honk, a Rust eBPF transparent proxy engine";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts = {
      url = "github:hercules-ci/flake-parts";
      inputs.nixpkgs-lib.follows = "nixpkgs";
    };

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{
      self,
      flake-parts,
      nixpkgs,
      rust-overlay,
      ...
    }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      imports = [ flake-parts.flakeModules.easyOverlay ];

      perSystem =
        {
          pkgs,
          ...
        }:
        let
          pkgs' = pkgs.extend rust-overlay.overlays.default;

          # Keep userspace on stable while compiling the standalone eBPF crate
          # with the same nightly pinned by the release workflow.
          rustStable = pkgs'.rust-bin.stable.latest.minimal.override {
            extensions = [
              "clippy"
              "rust-src"
              "rustfmt"
            ];
          };
          rustEbpf = pkgs'.rust-bin.nightly."2026-07-20".minimal.override {
            extensions = [
              "llvm-tools-preview"
              "rust-src"
            ];
          };
          rustPlatform = pkgs'.makeRustPlatform {
            cargo = rustStable;
            rustc = rustStable;
          };
          rustEbpfPlatform = pkgs'.makeRustPlatform {
            cargo = rustEbpf;
            rustc = rustEbpf;
          };
          # bpf-linker reads the LLVM bitcode emitted by rustc, so its LLVM
          # major version must match the pinned nightly (LLVM 22).
          bpfLinker = pkgs'.bpf-linker.override {
            llvmPackagesForLinker = pkgs'.llvmPackages_22;
          };

          honkEbpf = pkgs'.callPackage ./nix/ebpf-package.nix {
            rustPlatform = rustEbpfPlatform;
            rustToolchain = rustEbpf;
            bpf-linker = bpfLinker;
          };
          honk = pkgs'.callPackage ./nix/package.nix {
            inherit rustPlatform;
            honkEbpfObject = honkEbpf;
          };
          honkTool = pkgs'.callPackage ./nix/tool-package.nix {
            inherit rustPlatform;
          };
        in
        {
          packages = {
            default = honk;
            inherit honk honkEbpf honkTool;
          };

          apps = {
            default = {
              type = "app";
              program = "${honk}/bin/honk-core";
            };
            honk-tool = {
              type = "app";
              program = "${honkTool}/bin/honk-tool";
            };
          };

          # easyOverlay turns these into overlays.default, so downstream NixOS
          # configurations can use pkgs.honk and pkgs.honkTool as well.
          overlayAttrs = {
            inherit honk honkEbpf honkTool;
          };

          checks = {
            inherit honk honkEbpf honkTool;
          };

          devShells.default = pkgs'.mkShell {
            packages = [
              bpfLinker
              pkgs'.cargo-watch
              pkgs'.cmake
              pkgs'.git
              pkgs'.just
              pkgs'.llvmPackages.clang
              pkgs'.llvmPackages.libclang
              pkgs'.nixfmt-rfc-style
              pkgs'.pkg-config
              pkgs'.perl
              pkgs'.rust-analyzer
              rustStable
            ];

            LIBCLANG_PATH = "${pkgs'.llvmPackages.libclang.lib}/lib";
            # build.rs normally delegates to `cargo +nightly`. Nix toolchains
            # are not managed by rustup, so provide exact binaries instead.
            HONK_EBPF_CARGO = "${rustEbpf}/bin/cargo";
            HONK_EBPF_RUSTC = "${rustEbpf}/bin/rustc";

            shellHook = ''
              echo "honk development shell (Rust $(rustc --version | cut -d' ' -f2))"
              echo "eBPF builds use $HONK_EBPF_CARGO"
            '';
          };

          formatter = pkgs'.nixfmt-rfc-style;
        };

      flake.nixosModules.default = import ./nix/module.nix {
        packageFor = pkgs: self.packages.${pkgs.stdenv.hostPlatform.system}.honk;
      };
    };
}
