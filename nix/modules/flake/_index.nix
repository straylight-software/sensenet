# nix/modules/flake/_index.nix
#
# Module index for ℵ-0xFF — self-use only
# Downstream flakes import flakeModules.default
#
{ inputs, ... }:
{
  imports = [
    (import ./formatter.nix { inherit inputs; })
    ./lint.nix
    (import ./nixpkgs.nix { inherit inputs; })
    (import ./build/flake-module.nix { inherit inputs; })
    ./devshell.nix
    (import ./std.nix { inherit inputs; })
  ];

  # Enable devshell for this repo
  # NOTE: aleph.build.enable requires scripts/ directory which is missing
  aleph.devshell.enable = true;
  aleph.devshell.nv.enable = true;
}
