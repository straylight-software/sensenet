# nix/modules/flake/lint.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                                 // lint //
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
# Lint config files: clang-format, clang-tidy, ruff, biome, stylua, etc.
#
# Exports:
#   - flake.lintConfigs: individual config file paths
#   - perSystem.packages.lint-configs: directory with all configs
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
let
  lint-configs = {
    clang-format = ../../configs/.clang-format;
    clang-tidy = ../../configs/.clang-tidy;
    ruff = ../../configs/ruff.toml;
    biome = ../../configs/biome.json;
    stylua = ../../configs/.stylua.toml;
    rustfmt = ../../configs/.rustfmt.toml;
    taplo = ../../configs/taplo.toml;
  };
in
{ config, lib, ... }:
let
  cfg = config.sense.lint;
in
{
  _class = "flake";

  options.sense.lint = {
    enable = lib.mkEnableOption "sense lint configs" // {
      default = true;
    };
  };

  config = lib.mkIf cfg.enable {
    flake.lintConfigs = lint-configs;

    perSystem =
      { pkgs, ... }:
      let
        configs-dir = pkgs.linkFarm "sense-lint-configs" [
          {
            name = ".clang-format";
            path = lint-configs.clang-format;
          }
          {
            name = ".clang-tidy";
            path = lint-configs.clang-tidy;
          }
          {
            name = "ruff.toml";
            path = lint-configs.ruff;
          }
          {
            name = "biome.json";
            path = lint-configs.biome;
          }
          {
            name = ".stylua.toml";
            path = lint-configs.stylua;
          }
          {
            name = ".rustfmt.toml";
            path = lint-configs.rustfmt;
          }
          {
            name = "taplo.toml";
            path = lint-configs.taplo;
          }
        ];
      in
      {
        packages.lint-configs = configs-dir;
      };
  };
}
