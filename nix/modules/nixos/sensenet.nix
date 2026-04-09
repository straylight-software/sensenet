# nix/modules/nixos/sensenet.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                                       // sensenet // nixos
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#   "The matrix has its roots in primitive arcade games, in early
#    graphics programs and military experimentation with cranial
#    jacks."
#
#                                                         — Neuromancer
#
# NixOS module for Sensenet (Buck2 + Nix integration).
#
# Configures Nix daemon to allow __noChroot derivations required by
# Buck2 builds that need daemon access for incremental compilation.
#
# USAGE:
#
#   {
#     imports = [ sensenet.nixosModules.sensenet ];
#     sensenet.enable = true;
#   }
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{
  config,
  lib,
  ...
}:
let
  cfg = config.sensenet;
in
{
  _class = "nixos";

  options.sensenet = {
    enable = lib.mkEnableOption "Sensenet Nix configuration for Buck2 builds";
  };

  config = lib.mkIf cfg.enable {
    # Allow __noChroot derivations (required for Buck2 daemon access)
    # "relaxed" permits __noChroot while still sandboxing normal builds
    nix.settings.sandbox = lib.mkForce "relaxed";
  };
}
