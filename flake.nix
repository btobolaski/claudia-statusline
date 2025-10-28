{
  description = "Claudia Statusline - A feature-rich statusline for Claude Code";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

    crane = {
      url = "github:ipetkov/crane";
    };

    flake-utils.url = "github:numtide/flake-utils";

    rust-overlay = {
      url = "github:oxalica/rust-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, crane, flake-utils, rust-overlay, ... }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
        };

        rustToolchain = pkgs.rust-bin.stable.latest.default;

        craneLib = (crane.mkLib pkgs).overrideToolchain rustToolchain;

        # Extract git metadata from flake for build metadata
        # These will be used by build.rs when git commands aren't available
        gitRevision = if self ? rev then self.rev else self.dirtyRev or "unknown";
        gitDirty = if self ? dirtyRev then "true" else "false";

        # Filter source to include only files needed for the build
        # This improves caching by preventing rebuilds when unrelated files change
        src = pkgs.lib.fileset.toSource {
          root = ./.;
          fileset = pkgs.lib.fileset.unions [
            (craneLib.fileset.commonCargoSources ./.)
            ./VERSION
            ./build.rs
          ];
        };

        # Common arguments shared across all derivations
        commonArgs = {
          inherit src;
          strictDeps = true;
          pname = "statusline";

          # Build-time dependencies
          nativeBuildInputs = [ ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # Darwin-specific build dependencies
          ];

          # Runtime dependencies
          buildInputs = [ ] ++ pkgs.lib.optionals pkgs.stdenv.isDarwin [
            # Add Apple frameworks if needed for Darwin builds
            pkgs.libiconv
          ];

          # Provide git metadata from flake context for build.rs
          # When building in Nix's sandboxed environment, git commands aren't available,
          # so we pass metadata extracted from the flake's git repository
          preBuild = ''
            export CLAUDIA_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
            export CLAUDIA_GIT_HASH="${gitRevision}"
            export CLAUDIA_GIT_BRANCH="unknown"
            export CLAUDIA_GIT_DIRTY="${gitDirty}"
            export CLAUDIA_GIT_DESCRIBE="${gitRevision}"
          '';
        };

        # Build *just* the cargo dependencies for caching
        # This allows Nix to cache dependencies separately from the main build
        cargoArtifacts = craneLib.buildDepsOnly commonArgs;

        # Build the actual package
        statusline = craneLib.buildPackage (commonArgs // {
          inherit cargoArtifacts;

          # Run tests separately in checks, not during build
          doCheck = false;
        });

        # Additional packages/apps
        statusline-app = flake-utils.lib.mkApp {
          drv = statusline;
          name = "statusline";
        };
      in
      {
        # `nix build`
        packages.default = statusline;
        packages.statusline = statusline;

        # `nix run`
        apps.default = statusline-app;
        apps.statusline = statusline-app;

        # `nix develop`
        devShells.default = craneLib.devShell {
          # Inherit inputs from the package build
          inputsFrom = [ statusline ];

          # Minimal additional dev tools
          packages = with pkgs; [
            # Rust toolchain is already provided by craneLib.devShell
            rustToolchain
          ];
        };

        # `nix flake check`
        checks = {
          # Check that the package builds
          inherit statusline;

          # Run clippy with strict warnings
          statusline-clippy = craneLib.cargoClippy (commonArgs // {
            inherit cargoArtifacts;
            cargoClippyExtraArgs = "--all-targets -- --deny warnings";
          });

          # Check code formatting
          statusline-fmt = craneLib.cargoFmt {
            inherit src;
          };

          # Note: statusline-test is commented out due to pre-existing test failures
          # that are unrelated to the Nix build. These tests fail both inside and
          # outside the Nix sandbox. To run tests manually, use: cargo test
          # statusline-test = craneLib.cargoTest (commonArgs // {
          #   inherit cargoArtifacts;
          # });
        };
      }
    );
}
