{
  description = "cmux — Nix-built variant (no Xcode.app required)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils, ... }:
    flake-utils.lib.eachSystem [ "aarch64-darwin" "x86_64-darwin" ] (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = with pkgs; [
            # NB: reverting to wrapped `swift` because `swift-unwrapped`
            # produces target triple `aarch64-apple-macosx12.0` which ld
            # rejects ("unknown architecture aarch64" — needs arm64).
            # The wrapper is actually doing necessary target normalization;
            # we'll need a different angle for the runtime crash.
            swift
            swiftPackages.swiftpm
            swiftPackages.swift-driver
            sqlite
            zlib
            zig
            git
            python3
            rsync
          ];

          shellHook = ''
            export SDKROOT=$(xcrun --show-sdk-path 2>/dev/null || true)
            export DEVELOPER_DIR=$(xcode-select -p 2>/dev/null || true)
            # cc-wrapper otherwise downgrades the target triple to macosx12.0,
            # which makes @Observable etc. unavailable. Force the real
            # deployment target through the wrapper.
            export MACOSX_DEPLOYMENT_TARGET=14.0

            echo "-- cmux dev environment (Nix) --"
            echo "SDKROOT=$SDKROOT"
            echo "swift:  $(swift --version 2>&1 | head -1)"
            echo "zig:    $(zig version 2>&1)"
            echo
            echo "Build targets:"
            echo "  nix build .#cmux       — assemble cmux.app (in progress)"
            echo "  swift build            — compile cmux executable (Package.swift is at repo root)"
            echo
            echo "One-time setup (run once after fresh clone):"
            echo "  ./nix-build/scripts/bake-icon.sh           # AppIcon.appiconset → AppIcon.icns"
            echo "  ./nix-build/scripts/extract-agent-icons.sh # AgentIcons.imageset → loose PNGs"
          '';
        };

        packages = {
          cmux = pkgs.callPackage ./nix-build/default.nix { };
        };
      });
}
