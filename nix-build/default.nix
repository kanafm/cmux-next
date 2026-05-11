{ stdenv, lib, swift, zig, git, python3, rsync, ... }:

# Builds cmux.app via SwiftPM + manual bundle assembly. No xcodebuild.
#
# Status: scaffolding. The full app build is iterated on as a follow-up because
# it depends on (a) a working `swift build` of the SPM tree against cmux's flat
# Sources/ layout, (b) a built GhosttyKit.xcframework (run `nix develop` then
# `./scripts/ensure-ghosttykit.sh`), and (c) Sparkle.framework being correctly
# embedded and signed. Each is tractable but each has its own surprises.
#
# In the meantime, use the devShell (`nix develop`) for compiler+SDK+zig and
# drive the build manually while we iterate.
stdenv.mkDerivation {
  pname = "cmux";
  version = "0.0.0-nix";
  src = ../.;

  nativeBuildInputs = [ swift zig git python3 rsync ];

  # Inherit SDKROOT/DEVELOPER_DIR from the user's nix develop env.
  # Pure-build hookup is deferred — see DIVERGENCE.md.
  configurePhase = ''
    echo "[cmux/default.nix] full-app derivation not yet wired up."
    echo "Use 'nix develop' for the dev shell; build steps are documented in nix-build/README.md."
    exit 1
  '';
  dontBuild = true;
  dontInstall = true;

  meta = with lib; {
    description = "cmux Nix build (work in progress)";
    platforms = platforms.darwin;
  };
}
