# nix/modules/flake/oci/flake-module.nix
#
# OCI container generation for sensenet toolchains.
#
# This module generates NativeLink-compatible OCI containers from
# sensenet toolchain configurations. The containers can be:
# - Full: embed all toolchain packages (~2-4GB)
# - Minimal: just nix + manifest, fetch toolchain at runtime (~200MB)
#
# Usage:
#   sense.oci.enable = true;
#   sense.oci.toolchains = [ "cxx" "rust" "haskell" ];
#   sense.oci.registry = "ghcr.io/your-org/your-repo";
#
# Build:   nix build .#oci-worker-full
# Push:    nix run .#oci-worker-full.copyToGithub
#
{ inputs }:
{
  config,
  lib,
  ...
}:
let
  mk-option = lib.${"mkOption"};
  mk-enable-option = lib.${"mkEnableOption"};
  mk-if = lib.${"mkIf"};
  types = lib.${"types"};
  optional-attrs = lib.${"optionalAttrs"};
  concat-map-strings-sep = lib.${"concatMapStringsSep"};
  to-json = builtins.${"toJSON"};
  to-string = builtins.${"toString"};
  read-file = builtins.${"readFile"};
  unsafe-discard-string-context = builtins.${"unsafeDiscardStringContext"};

  cfg = config.sense.oci;

  # Import container lib
  container-lib = import ../../../lib/container.nix { inherit lib; };
in
{
  _class = "flake";

  options.sense.oci = {
    enable = mk-enable-option "OCI container generation for toolchains";

    toolchains = mk-option {
      type = types.listOf (
        types.enum [
          "cxx"
          "haskell"
          "rust"
          "lean"
          "python"
          "nv"
          "purescript"
        ]
      );
      default = [ "cxx" ];
      description = "Which toolchains to include in the container";
    };

    registry = mk-option {
      type = types.str;
      default = "ghcr.io/straylight-software/sensenet";
      description = "Container registry for pushing images";
    };

    tag = mk-option {
      type = types.str;
      default = "latest";
      description = "Container image tag";
    };

    nativelink = {
      scheduler = mk-option {
        type = types.str;
        default = "localhost";
        description = "NativeLink scheduler address for worker config";
      };

      cas = mk-option {
        type = types.str;
        default = "localhost";
        description = "NativeLink CAS address for worker config";
      };

      scheduler-port = mk-option {
        type = types.port;
        default = 50051;
        description = "NativeLink scheduler port";
      };

      cas-port = mk-option {
        type = types.port;
        default = 50052;
        description = "NativeLink CAS port";
      };
    };

    # Minimal vs full container strategy
    strategy = mk-option {
      type = types.enum [
        "full"
        "minimal"
      ];
      default = "full";
      description = ''
        Container strategy:
        - full: embed all toolchain packages (large, ~2-4GB, no runtime fetch)
        - minimal: embed nix + manifest, fetch toolchain from cache at runtime
      '';
    };
  };

  config = mk-if cfg.enable {
    perSystem =
      {
        pkgs,
        system,
        ...
      }:
      let
        write-text = pkgs.${"writeText"};
        write-shell-application = pkgs.${"writeShellApplication"};

        # Get nativelink binary
        nativelink =
          inputs.nativelink.packages.${system}.default or inputs.nativelink.packages.${system}.nativelink
            or null;

        # Build toolchain package list from enabled toolchains
        toolchain-packages =
          let
            # Create a fake config structure for toolchain.all-packages
            fake-cfg = builtins.listToAttrs (
              map (t: {
                name = t;
                value.enable = true;
              }) cfg.toolchains
            );
          in
          container-lib.toolchain.all-packages pkgs fake-cfg;

        # Generate toolchain manifest (store paths for runtime fetching)
        toolchain-manifest = write-text "toolchain-manifest.txt" (
          concat-map-strings-sep "\n" (pkg: unsafe-discard-string-context (to-string pkg)) toolchain-packages
        );

        # NativeLink worker config
        worker-config = write-text "worker.json" (to-json {
          stores = [
            {
              name = "REMOTE_CAS";
              grpc = {
                "instance_name" = "main";
                endpoints = [
                  { address = "grpc://${cfg.nativelink.cas}:${to-string cfg.nativelink.cas-port}"; }
                ];
                "store_type" = "cas";
              };
            }
            {
              name = "REMOTE_AC";
              grpc = {
                "instance_name" = "main";
                endpoints = [
                  { address = "grpc://${cfg.nativelink.cas}:${to-string cfg.nativelink.cas-port}"; }
                ];
                "store_type" = "ac";
              };
            }
            {
              name = "CAS_FAST_SLOW";
              "fast_slow" = {
                fast = {
                  filesystem = {
                    "content_path" = "/data/cas-content";
                    "temp_path" = "/data/cas-temp";
                    "eviction_policy"."max_bytes" = "10Gb";
                  };
                };
                "fast_direction" = "get";
                slow."ref_store".name = "REMOTE_CAS";
              };
            }
          ];
          workers = [
            {
              local = {
                "worker_api_endpoint".uri = "grpc://${cfg.nativelink.scheduler}:50061";
                "work_directory" = "/data/work";
                "cas_fast_slow_store" = "CAS_FAST_SLOW";
                "upload_action_result"."ac_store" = "REMOTE_AC";
                "platform_properties" = {
                  "OSFamily".values = [ "linux" ];
                  "container-image".values = [ "sensenet-worker" ];
                  # Add toolchain capabilities
                  "toolchains".values = cfg.toolchains;
                };
              };
            }
          ];
          servers = [ ];
        });

        # Worker entrypoint script
        worker-script = write-shell-application {
          name = "sensenet-worker";
          runtimeInputs = [ nativelink ];
          text = ''
            mkdir -p /data/work /data/cas-content /data/cas-temp
            exec nativelink ${worker-config}
          '';
        };

        # Setup script for minimal containers (fetches toolchain at runtime)
        setup-script = write-shell-application {
          name = "sensenet-worker-setup";
          runtimeInputs = [
            pkgs.coreutils
            pkgs.nix
            pkgs.cacert
          ];
          runtimeEnv = {
            NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
          };
          text = ''
            echo "Fetching toolchain packages from cache.nixos.org..."
            TOOLCHAIN_PATHS="${
              concat-map-strings-sep " " (pkg: unsafe-discard-string-context (to-string pkg)) toolchain-packages
            }"
            for path in $TOOLCHAIN_PATHS; do
              if [[ ! -e "$path" ]]; then
                echo "Fetching $path..."
                nix-store --realise "$path" || echo "Warning: failed to fetch $path"
              fi
            done
            echo "Toolchain setup complete."
          '';
        };

        # nix2gpu service helper
        mk-service = script: _: _: {
          _class = "service";
          config.process.argv = [ "${script}/bin/${script.name}" ];
        };

      in
      optional-attrs (nativelink != null) {
        # ══════════════════════════════════════════════════════════════════════
        # nix2gpu container definitions
        # ══════════════════════════════════════════════════════════════════════

        nix2gpu = {
          # Full worker: all toolchain packages embedded
          oci-worker-full = {
            systemPackages = [
              nativelink
              worker-script
              pkgs.coreutils
              pkgs.bash
              pkgs.cacert
            ]
            ++ toolchain-packages;

            services.worker = {
              imports = [ (mk-service worker-script { inherit lib pkgs; }) ];
            };

            registries = [ cfg.registry ];

            extraEnv = {
              RUST_LOG = "info";
              NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            };
          };

          # Minimal worker: just nix, fetch toolchain at runtime
          oci-worker-minimal = {
            systemPackages = [
              nativelink
              worker-script
              setup-script
              pkgs.nix
              pkgs.coreutils
              pkgs.bash
              pkgs.cacert
            ];

            services.worker = {
              imports = [ (mk-service worker-script { inherit lib pkgs; }) ];
            };

            registries = [ cfg.registry ];

            extraEnv = {
              RUST_LOG = "info";
              NIX_SSL_CERT_FILE = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
            };
          };
        };

        # ══════════════════════════════════════════════════════════════════════
        # Packages for inspection / manual use
        # ══════════════════════════════════════════════════════════════════════

        packages = {
          # Worker config for debugging
          oci-worker-config = worker-config;

          # Toolchain manifest
          oci-toolchain-manifest = toolchain-manifest;

          # Setup script (for minimal containers)
          oci-worker-setup = setup-script;

          # Entrypoint script
          oci-worker-script = worker-script;
        };
      };
  };
}
