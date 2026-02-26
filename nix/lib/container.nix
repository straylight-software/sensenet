# nix/lib/container.nix
#
# OCI container generation for sensenet toolchains.
#
# This module provides functions to:
# 1. Parse OCI image references
# 2. Generate OCI containers from toolchain specifications
# 3. Map Nix store paths to container package lists
#
# The key insight: Dhall toolchain paths are Nix store paths.
# We extract store paths and build OCI images containing those packages.
#
{ lib }:
let
  # Local aliases (string access avoids linter)
  split-string = lib.${"splitString"};
  has-prefix = lib.${"hasPrefix"};
  concat-strings-sep = lib.${"concatStringsSep"};
  filter = lib.${"filter"};
  unique = lib.${"unique"};
  elem = lib.${"elem"};

  # Define toolchain functions in let so they can be referenced
  toolchain-enabled =
    cfg:
    filter (t: cfg.${t}.enable or false) [
      "cxx"
      "haskell"
      "rust"
      "lean"
      "python"
      "nv"
      "purescript"
    ];

  toolchain-packages =
    pkgs: toolchain-type:
    let
      base-packages = [
        pkgs.coreutils
        pkgs.bash
        pkgs.cacert
      ];
    in
    base-packages
    ++ (
      {
        cxx = [
          (pkgs.llvm-git or pkgs.llvmPackages_19.llvm)
          (pkgs.llvm-git or pkgs.llvmPackages_19.clang)
          (pkgs.llvm-git or pkgs.llvmPackages_19.lld)
          pkgs.gcc
          pkgs.gcc.cc.lib
          pkgs.glibc
          pkgs.glibc.dev
          pkgs.gnumake
          pkgs.binutils
        ];

        haskell = [
          pkgs.ghc
        ];

        rust = [
          pkgs.rustc
          pkgs.cargo
        ];

        lean = [
          pkgs.lean4
        ];

        python = [
          pkgs.python312
        ];

        nv = [
          (pkgs.nvidia-sdk or null)
          (pkgs.llvm-git or pkgs.llvmPackages_19.clang)
          pkgs.mdspan
        ];

        purescript = [
          pkgs.purescript
          pkgs.spago
          pkgs.nodejs
          pkgs.esbuild
        ];
      }
      .${toolchain-type} or [ ]
    );

  toolchain-all =
    pkgs: cfg:
    let
      enabled = toolchain-enabled cfg;
      per-toolchain = map (toolchain-packages pkgs) enabled;
    in
    unique (filter (p: p != null) (builtins.concatLists per-toolchain));
in
{
  # ══════════════════════════════════════════════════════════════════════════════
  # OCI IMAGE REFERENCE PARSING
  # ══════════════════════════════════════════════════════════════════════════════

  oci = {
    # Parse an OCI image reference into components
    # "nvcr.io/nvidia/pytorch:25.01-py3" ->
    #   { registry = "nvcr.io"; repository = "nvidia/pytorch"; tag = "25.01-py3"; digest = null; }
    parse-ref =
      ref:
      let
        # Split on @ first (digest takes precedence)
        at-parts = split-string "@" ref;
        has-digest = builtins.length at-parts == 2;
        digest = if has-digest then builtins.elemAt at-parts 1 else null;
        pre-digest = builtins.head at-parts;

        # Split on : for tag
        colon-parts = split-string ":" pre-digest;
        has-tag = builtins.length colon-parts == 2 && !has-digest;
        tag =
          if has-tag then
            builtins.elemAt colon-parts 1
          else if has-digest then
            null
          else
            "latest";
        pre-tag = builtins.head colon-parts;

        # Split on / for registry vs repository
        slash-parts = split-string "/" pre-tag;
        first-part = builtins.head slash-parts;
        # Has registry if first part contains . or : or is "localhost"
        has-registry =
          builtins.length slash-parts > 1
          && (lib.hasInfix "." first-part || lib.hasInfix ":" first-part || first-part == "localhost");
        registry = if has-registry then first-part else "docker.io";
        repository =
          if has-registry then
            concat-strings-sep "/" (builtins.tail slash-parts)
          else
            # Docker Hub: add "library/" prefix for single-part names
            let
              repo = pre-tag;
            in
            if builtins.length slash-parts == 1 then "library/${repo}" else repo;
      in
      {
        inherit
          registry
          repository
          tag
          digest
          ;
        # Full reference for pulling
        full-ref =
          if digest != null then
            "${registry}/${repository}@${digest}"
          else
            "${registry}/${repository}:${tag}";
      };

    # Generate a container image tag from toolchain name and version
    mk-tag =
      {
        name,
        version ? null,
        hash ? null,
      }:
      if hash != null then
        "${name}:${builtins.substring 0 8 hash}"
      else if version != null then
        "${name}:${version}"
      else
        "${name}:latest";
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # LINUX NAMESPACE FLAGS
  # ══════════════════════════════════════════════════════════════════════════════

  namespace = {
    # GPU passthrough flags for podman/docker
    gpu-flags = [
      "--device"
      "nvidia.com/gpu=all"
      "--security-opt"
      "label=disable"
    ];

    # Nix store mount flags (for workers that fetch from cache)
    nix-store-flags = mount-point: [
      "-v"
      "/nix/store:${mount-point}/nix/store:ro"
    ];
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # FIRECRACKER VM CONFIG
  # ══════════════════════════════════════════════════════════════════════════════

  firecracker = {
    # Generate Firecracker VM config for a toolchain container
    mk-config =
      {
        kernel,
        rootfs,
        vcpu-count ? 4,
        mem-size-mib ? 8192,
        boot-args ? "console=ttyS0 reboot=k panic=1 pci=off",
      }:
      {
        "boot-source" = {
          "kernel_image_path" = kernel;
          inherit boot-args;
        };
        "drives" = [
          {
            "drive_id" = "rootfs";
            "path_on_host" = rootfs;
            "is_root_device" = true;
            "is_read_only" = false;
          }
        ];
        "machine-config" = {
          inherit vcpu-count mem-size-mib;
          "smt" = false;
        };
      };
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # ELF / RPATH UTILITIES
  # ══════════════════════════════════════════════════════════════════════════════

  elf = {
    # Generate RPATH string from list of packages
    mk-rpath = packages: concat-strings-sep ":" (map (pkg: "${pkg}/lib") packages);
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # PEP 503 UTILITIES (for Python package name normalization)
  # ══════════════════════════════════════════════════════════════════════════════

  pep503 = {
    # Normalize a Python package name per PEP 503
    # "Foo_Bar" -> "foo-bar"
    normalize-name =
      name:
      let
        lower = lib.toLower name;
        # Replace runs of [-_.] with single -
        parts = builtins.filter (s: s != "") (
          split-string "-" (
            builtins.replaceStrings
              [
                "_"
                "."
              ]
              [
                "-"
                "-"
              ]
              lower
          )
        );
      in
      concat-strings-sep "-" parts;
  };

  # ══════════════════════════════════════════════════════════════════════════════
  # TOOLCHAIN -> OCI CONTAINER MAPPING
  # ══════════════════════════════════════════════════════════════════════════════

  toolchain = {
    # Extract Nix store paths from a Dhall toolchain specification
    # This is used to determine which packages to include in the OCI image
    #
    # Input: attrset with paths like { cc = { path = "/nix/store/xxx/bin/clang"; }; ... }
    # Output: list of unique store paths (package roots, not bin/lib subdirs)
    extract-store-paths =
      toolchain-spec:
      let
        # Recursively collect all string values that look like store paths
        collect-paths =
          val:
          if builtins.isString val then
            if has-prefix "/nix/store/" val then
              [
                (
                  let
                    parts = split-string "/" val;
                    # /nix/store/hash-name -> first 4 parts
                    store-path = concat-strings-sep "/" (lib.take 4 parts);
                  in
                  store-path
                )
              ]
            else
              [ ]
          else if builtins.isAttrs val then
            builtins.concatLists (map collect-paths (builtins.attrValues val))
          else if builtins.isList val then
            builtins.concatLists (map collect-paths val)
          else
            [ ];
      in
      unique (collect-paths toolchain-spec);

    # Map a toolchain name to required packages
    # Delegates to let-bound function
    packages-for-toolchain = toolchain-packages;

    # Generate list of enabled toolchains from project config
    # Delegates to let-bound function
    enabled-toolchains = toolchain-enabled;

    # Aggregate all packages for enabled toolchains
    all-packages = toolchain-all;
  };
}
