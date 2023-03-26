{
  description = "Dagwood Crates";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs = {
        nixpkgs.follows = "nixpkgs";
        flake-utils.follows = "flake-utils";
      };
    };

    advisory-db = {
      url = "github:rustsec/advisory-db";
      flake = false;
    };
  };

  outputs = {
    nixpkgs,
    crane,
    flake-utils,
    rust-overlay,
    advisory-db,
    ...
  }:
    flake-utils.lib.eachDefaultSystem (system: let
      overlays = [(import rust-overlay)];
      pkgs = import nixpkgs {
        inherit system overlays;
      };

      inherit (pkgs) lib rust-bin;

      rustToolchain = rust-bin.fromRustupToolchainFile ./rust-toolchain;
      craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;
      src = craneLib.cleanCargoSource ./.;
      cargoToml = ./crates/http-nvim/Cargo.toml;

      nativeBuildInputs = with pkgs; [
        pkg-config
        clang_14
        llvmPackages_14.bintools
      ];

      buildInputs = with pkgs; [
        openssl
      ];

      cargoArtifacts = craneLib.buildDepsOnly {
        inherit src buildInputs nativeBuildInputs cargoToml;
      };

      http-nvim = craneLib.buildPackage {
        inherit cargoArtifacts src buildInputs nativeBuildInputs cargoToml;
      };
    in rec {
      formatter = pkgs.alejandra;

      checks =
        {
          http-nvim = http-nvim;

          http-nvim-clippy = craneLib.cargoClippy {
            inherit cargoArtifacts src buildInputs nativeBuildInputs cargoToml;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          };

          http-nvim-doc = craneLib.cargoDoc {
            inherit cargoArtifacts src buildInputs nativeBuildInputs cargoToml;
          };

          http-nvim-fmt = craneLib.cargoFmt {
            inherit src cargoToml;
          };

          http-nvim-audit = craneLib.cargoAudit {
            inherit src advisory-db cargoToml;
          };

          http-nvim-nextest = craneLib.cargoNextest {
            inherit cargoArtifacts src buildInputs nativeBuildInputs cargoToml;
            partitions = 1;
            partitionType = "count";
          };
        }
        // lib.optionalAttrs (system == "x86_64-linux") {
          http-nvim-coverage = craneLib.cargoTarpaulin {
            inherit cargoArtifacts src cargoToml;
          };
        };

      packages.default = http-nvim;

      devShells.default = pkgs.mkShell {
        inputsFrom = builtins.attrValues checks;

        nativeBuildInputs = with pkgs;
          [
            rustToolchain
            just
            cargo-nextest
            cargo-llvm-cov
            cacert
          ]
          ++ nativeBuildInputs
          ++ buildInputs;
      };
    });
}
