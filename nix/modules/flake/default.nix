# nix/modules/flake/default.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              ℵ-0xFF // default
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Import this module in your flake to get:
#   - nix fmt (treefmt: nixfmt, clang-format, ruff, biome, fourmolu, etc.)
#   - nix flake check (statix, deadnix, shellcheck, ast-grep rules)
#   - buck2 toolchains (cxx, cuda, haskell, rust, lean, python)
#   - buck2.build :: target -> derivation
#   - remote execution via NativeLink CAS
#
# USAGE:
#
#   {
#     inputs.sense.url = "github:straylight-software/sensenet";
#
#     outputs = { sense, ... }: {
#       imports = [ sense.flakeModules.default ];
#
#       # Your config here
#       perSystem = { ... }: {
#         packages.myapp = config.buck2.build {
#           target = "//src:myapp";
#         };
#       };
#     };
#   }
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{ inputs }:
{ lib, ... }:
{
  _class = "flake";

  imports = [
    (import ./formatter.nix { inherit inputs; })
    ./lint.nix
    ./std.nix
    ./buck2.nix
    ./devshell.nix
  ];

  # Sensible defaults
  sense.formatter.enable = lib.mkDefault true;
  sense.lint.enable = lib.mkDefault true;
}
