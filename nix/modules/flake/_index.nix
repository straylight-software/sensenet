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
    (import ./std.nix { inherit inputs; })
  ];
}
