{
  description = "Example downstream project using sensenet flake module";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";

    # The sensenet flake module provides:
    # - Buck2 build system with Nix toolchains
    # - C++, Rust, Haskell, Python toolchains
    # - Optional remote execution via NativeLink
    sensenet.url = "github:straylight-software/sensenet";
  };

  outputs =
    inputs@{ flake-parts, sensenet, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];

      # Import the sensenet flake module
      imports = [ sensenet.flakeModules.sensenet ];

      perSystem =
        { pkgs, system, ... }:
        {
          # Configure sensenet for this project
          sensenet.projects.example = {
            # Enable toolchains you need
            toolchain = {
              cxx.enable = true; # LLVM/Clang C++ toolchain
              # rust.enable = true;    # Rust toolchain
              # haskell.enable = true; # GHC with packages
              # python.enable = true;  # Python with nanobind
            };

            # Optional: Enable remote execution
            # remoteexecution = {
            #   enable = true;
            #   scheduler = "scheduler.example.com";
            #   cas = "cas.example.com";
            #   # authtoken = "your-token-here";  # For authenticated endpoints
            # };
          };

          # The devshell is automatically configured with:
          # - buck2 in PATH
          # - .buckconfig.local generated with toolchain paths
          # - nix/build/prelude symlinked to Buck2 prelude
          # - nix/build/toolchains copied with sensenet toolchain rules
        };
    };
}
