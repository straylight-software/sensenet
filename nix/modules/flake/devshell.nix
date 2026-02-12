# nix/modules/flake/devshell.nix
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#                              // devshell //
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#     Case had always taken it for granted that the real bosses, the
#     kingpins in a given industry, would be old men. The Tessier-
#     Ashpools were old money. He'd expected a boardroom, an
#     executive's office. Not the surreal maze of Straylight.
#
#                                                         — Neuromancer
#
# Development shell. Env vars at mkShell level only, not in shellHook.
# We say "nv" not "cuda". See: docs/languages/nix/philosophy/nvidia-not-cuda.md
#
# Haskell packages: The build.nix module defines toolchain.haskell.packages
# as the single source of truth. Devshell adds testing/dev packages on top.
#
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
{ config, lib, ... }:
let
  # lisp-case aliases for lib functions
  mk-enable-option = lib.mkEnableOption;
  mk-option = lib.mkOption;
  mk-if = lib.mkIf;
  optional-attrs = lib.optionalAttrs;
  inherit (lib) optionals;
  optional-string = lib.optionalString;
  has-prefix = lib.hasPrefix;
  inherit (lib) filter;
  function-to = lib.types.functionTo;
  list-of = lib.types.listOf;
  attrs-of = lib.types.attrsOf;

  cfg = config.sense.devshell;
  build-cfg = config.sense.build;
in
{
  _class = "flake";

  options.sense.devshell = {
    enable = mk-enable-option "sense devshell";
    nv.enable = mk-enable-option "NVIDIA SDK in devshell";
    straylight-nix.enable = mk-enable-option "straylight-nix with builtins.wasm support";

    extra-packages = mk-option {
      type = function-to (list-of lib.types.package);
      default = _: [ ];
      description = "Extra packages (receives pkgs)";
    };

    extra-haskell-packages = mk-option {
      type = function-to (list-of lib.types.package);
      default = hp: [
        # Scripting extras (not needed for Buck2 builds)
        hp.turtle
        hp.yaml
        hp.shelly
        hp.foldl
        hp.dhall
        hp.async

        # Crypto (for Sense.Script.Oci etc)
        hp.crypton
        hp.memory

        # Data structures
        hp.unordered-containers
        hp.vector

        # Testing frameworks
        hp.hedgehog
        hp.QuickCheck
        hp.quickcheck-instances
        hp.tasty
        hp.tasty-quickcheck
        hp.tasty-hunit

        # Development utilities
        hp.lens
        hp.raw-strings-qq
      ];
      description = "Extra Haskell packages for devshell (on top of build.toolchain.haskell.packages)";
    };

    extra-shell-hook = mk-option {
      type = lib.types.lines;
      default = "";
      description = "Extra shell hook commands";
    };

    extra-env = mk-option {
      type = attrs-of lib.types.str;
      default = { };
      description = "Extra environment variables";
    };
  };

  config = mk-if cfg.enable {
    perSystem =
      { pkgs, config, ... }:
      let
        # All env vars defined here, not in shellHook
        # Env var names use CUDA/NVIDIA because that's what tools expect
        nv-env = optional-attrs (cfg.nv.enable && pkgs ? nvidia-sdk) {
          CUDA_HOME = "${pkgs.nvidia-sdk}";
          CUDA_PATH = "${pkgs.nvidia-sdk}";
          NVIDIA_SDK = "${pkgs.nvidia-sdk}";
          # LD_LIBRARY_PATH for runtime loading of CUDA libs (hasktorch, etc.)
          LD_LIBRARY_PATH = "${pkgs.nvidia-sdk}/lib";
        };

        # ────────────────────────────────────────────────────────────────────────
        # Haskell Configuration
        # ────────────────────────────────────────────────────────────────────────
        # Single source of truth: build.toolchain.haskell.packages from _main.nix
        # Devshell adds testing/dev packages on top via extra-haskell-packages.
        #
        # HLS go-to-definition:
        # - For YOUR code: works via hie.yaml (generated in shellHook)
        # - For library code: HLS uses Haddock docs for type info, but source
        #   navigation requires packages built with -fwrite-ide-info (not default).
        #   For library source nav, use haskell-src-exts or M-. in Emacs haskell-mode.
        hs-pkgs = pkgs.haskell.packages.ghc912 or pkgs.haskellPackages;

        # Combine build toolchain packages + devshell extras
        # build.toolchain.haskell.packages: core packages for Buck2 builds
        # cfg.extra-haskell-packages: testing, scripting, dev tools
        ghc-with-all-deps = hs-pkgs.ghcWithPackages (
          hp: (build-cfg.toolchain.haskell.packages hp) ++ (cfg.extra-haskell-packages hp)
        );

        # System libraries GHC needs at runtime
        ghc-runtime-libs = [
          pkgs.numactl
          pkgs.gmp
          pkgs.libffi
          pkgs.ncurses
        ];
      in
      {
        devShells.default = pkgs.mkShell (
          {
            name = "sense-dev";

            hardeningDisable = [ "all" ];
            NIX_HARDENING_ENABLE = "";

            packages = [
              pkgs.git
              pkgs.jq
              pkgs.yq-go
              pkgs.ripgrep
              pkgs.fd
              pkgs.just
              pkgs.buck2
              ghc-with-all-deps

              # ════════════════════════════════════════════════════════════════
              # LSP servers - go-to-definition works out of the box
              # ════════════════════════════════════════════════════════════════

              # Haskell: HLS with matching GHC version
              # Packages built with -fwrite-ide-info for library navigation
              hs-pkgs.haskell-language-server

              # Nix: nixd (configured via .nixd.json from use_flake-lsp)
              pkgs.nixd

              # Rust: rust-analyzer (if Rust toolchain enabled)
              # Note: rust-analyzer is added via build.nix when rust toolchain is enabled
            ]
            # C++: clangd comes from llvm-git (via build.nix packages)
            # compile_commands.json generated by bin/compdb
            ++ ghc-runtime-libs
            ++ optionals (cfg.nv.enable && pkgs ? llvm-git) [
              pkgs.llvm-git
            ]
            ++ optionals (!cfg.nv.enable && pkgs ? sense && pkgs.sense ? llvm) [
              pkgs.sense.llvm.clang
              pkgs.sense.llvm.lld
            ]
            ++ optionals (cfg.nv.enable && pkgs ? nvidia-sdk) [
              pkgs.nvidia-sdk
            ]
            # straylight-nix with builtins.wasm support
            ++ optionals (cfg.straylight-nix.enable && pkgs ? sense && pkgs.sense ? nix) (
              filter (p: p != null) [
                pkgs.sense.nix.nix
              ]
            )
            ++ (cfg.extra-packages pkgs)
            # Buck2 build system packages (excludes GHC since devshell has its own ghc-with-all-deps)
            # This includes llvm-git, nvidia-sdk, rustc, lean4, python, etc.
            ++ filter (p: !(has-prefix "ghc-" (p.name or ""))) (config.sense.build.packages or [ ])
            # LRE packages (nativelink, lre-start)
            ++ (config.sense.lre.packages or [ ]);

            shellHook =
              let
                straylight-nix-check = optional-string cfg.straylight-nix.enable ''
                  if [ -n "${pkgs.sense.nix.nix or ""}" ]; then
                    echo "straylight-nix: $(${pkgs.sense.nix.nix}/bin/nix --version)"
                    echo "builtins.wasm: $(${pkgs.sense.nix.nix}/bin/nix eval --expr 'builtins ? wasm')"
                  fi
                '';

                # Generate .buckconfig.local with toolchain paths
                # This provides Buck2 with Nix store paths for all compilers
                
                # STRICT REQUIREMENT: NVIDIA toolchain requires custom LLVM-git overlay
                # Enable 'sense.llvm-git.enable = true' in your flake config.
                llvm-pkg = if (pkgs ? llvm-git) then pkgs.llvm-git 
                           else throw "NVIDIA toolchain requires 'pkgs.llvm-git'. Set 'sense.llvm-git.enable = true'.";
                
                clang = llvm-pkg;
                # llvm-git is already unwrapped
                clang-unwrapped = llvm-pkg;
                lld = llvm-pkg;

                # NV config if enabled
                nv-config = optional-string (cfg.nv.enable && pkgs ? nvidia-sdk) ''
                  [nv]
                  nvidia_sdk_path = ${pkgs.nvidia-sdk}
                  nvidia_sdk_include = ${pkgs.nvidia-sdk}/include
                  nvidia_sdk_lib = ${pkgs.nvidia-sdk}/lib
                  clang = ${clang-unwrapped}/bin/clang++
                  ptxas = ${pkgs.nvidia-sdk}/bin/ptxas
                  fatbinary = ${pkgs.nvidia-sdk}/bin/fatbinary
                  mdspan_include = ${pkgs.callPackage ../../packages/mdspan.nix { }}/include
                  archs = sm_90,sm_100,sm_120
                '';

                buckconfig-template = builtins.readFile ./devshell/buckconfig-local.ini;
                buckconfig-filled =
                  builtins.replaceStrings
                    [
                      "@cc@"
                      "@cxx@"
                      "@cpp@"
                      "@ar@"
                      "@ld@"
                      "@clang_resource_dir@"
                      "@gcc_include@"
                      "@gcc_include_arch@"
                      "@glibc_include@"
                      "@gcc_lib@"
                      "@gcc_lib_base@"
                      "@glibc_lib@"
                      "@ghc@"
                      "@ghc_pkg@"
                      "@haddock@"
                      "@ghc_version@"
                      "@ghc_lib_dir@"
                      "@global_package_db@"
                      "@rustc@"
                      "@rustdoc@"
                      "@clippy_driver@"
                      "@cargo@"
                      "@lean@"
                      "@leanc@"
                      "@lean_lib_dir@"
                      "@lean_include_dir@"
                      "@python_interpreter@"
                      "@python_include@"
                      "@pybind11_include@"
                    ]
                    [
                      "${clang}/bin/clang"
                      "${clang}/bin/clang++"
                      "${clang}/bin/clang-cpp"
                      "${lld}/bin/llvm-ar"
                      "${lld}/bin/ld.lld"
                      "${clang}/lib/clang/22"
                      "${pkgs.gcc.cc}/include/c++/${pkgs.gcc.cc.version}"
                      "${pkgs.gcc.cc}/include/c++/${pkgs.gcc.cc.version}/${pkgs.stdenv.hostPlatform.config}"
                      "${pkgs.glibc.dev}/include"
                      "${pkgs.gcc.cc}/lib/gcc/${pkgs.stdenv.hostPlatform.config}/${pkgs.gcc.cc.version}"
                      "${pkgs.gcc.cc.lib}/lib"
                      "${pkgs.glibc}/lib"
                      "${ghc-with-all-deps}/bin/ghc"
                      "${ghc-with-all-deps}/bin/ghc-pkg"
                      "${ghc-with-all-deps}/bin/haddock"
                      "9.12.2"
                      "${ghc-with-all-deps}/lib/ghc-9.12.2/lib"
                      "${ghc-with-all-deps}/lib/ghc-9.12.2/lib/package.conf.d"
                      "${pkgs.rustc}/bin/rustc"
                      "${pkgs.rustc}/bin/rustdoc"
                      "${pkgs.clippy}/bin/clippy-driver"
                      "${pkgs.cargo}/bin/cargo"
                      "${pkgs.lean4}/bin/lean"
                      "${pkgs.lean4}/bin/leanc"
                      "${pkgs.lean4}/lib/lean/library"
                      "${pkgs.lean4}/include"
                      "${pkgs.python312}/bin/python3"
                      "${pkgs.python312}/include/python3.12"
                      "${pkgs.python312Packages.pybind11}/include"
                    ]
                    buckconfig-template;

                buckconfig-local-content = buckconfig-filled + nv-config;

                buckconfig-local-file = pkgs.writeText "buckconfig.local" buckconfig-local-content;

                buckconfig-hook = ''
                  # Generate .buckconfig.local with Nix toolchain paths
                  cp ${buckconfig-local-file} .buckconfig.local
                  chmod 644 .buckconfig.local
                  echo "Generated .buckconfig.local with Nix toolchain paths"
                '';

                hie-yaml-hook = ''
                  GHC_WITH_DEPS="${ghc-with-all-deps}"
                  ${builtins.readFile ./devshell/hls-setup.sh}
                  # Sync .hie files from buck-out if they exist
                  if [ -d buck-out ] && [ -x bin/sync-hie.sh ]; then
                    ./bin/sync-hie.sh 2>/dev/null || true
                  fi
                '';
              in
              ''
                echo "━━━ sense devshell ━━━"
                echo "GHC: $(${ghc-with-all-deps}/bin/ghc --version)"
                ${straylight-nix-check}
                ${buckconfig-hook}
                ${config.sense.build.shellHook or ""}
                ${config.sense.shortlist.shellHook or ""}
                ${config.sense.lre.shellHook or ""}
                ${hie-yaml-hook}
                ${cfg.extra-shell-hook}
              '';
          }
          // nv-env
          // cfg.extra-env
          // optional-attrs (cfg.nv.enable && pkgs ? nvidia-sdk) {
            # Ensure ptxas/fatbinary are in PATH for Clang
            PATH = "${pkgs.nvidia-sdk}/bin:" + (builtins.getEnv "PATH");
          }
        );
        devShells.linter = pkgs.mkShell {
          name = "linter-shell";

          packages = [
            pkgs.ast-grep
            pkgs.tree-sitter
            pkgs.tree-sitter-grammars.tree-sitter-nix
          ];
        };
      };
  };
}
