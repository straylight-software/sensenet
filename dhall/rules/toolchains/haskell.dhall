--| Haskell toolchain and rules using GHC from Nix
--|
--| Uses ghcWithPackages from the Nix devshell, which includes all
--| dependencies. The bin/ghc wrapper filters Mercury-specific flags
--| that stock GHC doesn't understand.
--|
--| Paths are read from .buckconfig.local [haskell] section.
--|
--| Rules:
--|   haskell_toolchain  - toolchain definition
--|   haskell_library    - compile to .hi/.o with HaskellLibraryInfo
--|   haskell_binary     - executable from sources + deps
--|   haskell_c_library  - FFI exports callable from C/C++
--|   haskell_ffi_binary - Haskell calling C/C++ via FFI
--|   haskell_ffi_test   - FFI test executable
--|   haskell_script     - single-file scripts
--|   haskell_test       - test executable

let R = ../Rule.dhall
let S = ../to-starlark.dhall

-- ══════════════════════════════════════════════════════════════════════════════
-- Configuration (globals)
-- ══════════════════════════════════════════════════════════════════════════════

let globals = ''
# Mandatory compiler flags - applied to all Haskell compilation
# These are non-negotiable and cannot be overridden by targets
MANDATORY_GHC_FLAGS = [
    "-Wall",
    "-Werror",
]

def _get_ghc() -> str:
    return read_root_config("haskell", "ghc", "bin/ghc")

def _get_ghc_pkg() -> str:
    return read_root_config("haskell", "ghc_pkg", "bin/ghc-pkg")

def _get_package_db() -> str | None:
    return read_root_config("haskell", "global_package_db", None)
''

-- ══════════════════════════════════════════════════════════════════════════════
-- Providers
-- ══════════════════════════════════════════════════════════════════════════════

let haskellLibraryInfo =
      R.typedProvider "HaskellLibraryInfo"
        [ R.typedField "package_name" "str"
        , R.typedFieldDefault "hi_dir" "Artifact | None" "None"
        , R.typedFieldDefault "object_dir" "Artifact | None" "None"
        , R.typedFieldDefault "stub_dir" "Artifact | None" "None"
        , R.typedFieldDefault "hie_dir" "Artifact | None" "None"
        , R.typedFieldDefault "objects" "list" "[]"
        , R.typedFieldDefault "modules" "list" "[]"
        ]

let haskellIncludeInfo =
      R.typedProvider "HaskellIncludeInfo"
        [ R.typedFieldDefault "include_dirs" "list" "[]"
        ]

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_toolchain
-- ══════════════════════════════════════════════════════════════════════════════

let haskellToolchain =
      { impl =
          (R.ruleImpl "haskell_toolchain" ''
    ghc = read_root_config("haskell", "ghc", "bin/ghc")
    ghc_pkg = read_root_config("haskell", "ghc_pkg", "bin/ghc-pkg")
    haddock = read_root_config("haskell", "haddock", "bin/haddock")

    return [
        DefaultInfo(),
        HaskellToolchainInfo(
            compiler = ghc,
            packager = ghc_pkg,
            linker = ghc,
            haddock = haddock,
            compiler_flags = ctx.attrs.compiler_flags,
            linker_flags = ctx.attrs.linker_flags,
            ghci_script_template = ctx.attrs.ghci_script_template,
            ghci_iserv_template = ctx.attrs.ghci_iserv_template,
            script_template_processor = ctx.attrs.script_template_processor,
            cache_links = True,
            archive_contents = "normal",
            support_expose_package = False,
        ),
        HaskellPlatformInfo(
            name = "x86_64-linux",
        ),
    ]
'')
            with doc = "Haskell toolchain with paths from .buckconfig.local"
            with is_toolchain = True
      , attrs =
          [ R.stringListAttr "compiler_flags"
          , R.stringListAttr "linker_flags"
          , R.attr "ghci_script_template" (R.AttrType.OptionSource {=})
          , R.attr "ghci_iserv_template" (R.AttrType.OptionSource {=})
          , R.attr "script_template_processor" 
              (R.AttrType.OptionExecDep { providers = ["RunInfo"], default = None Text })
          ]
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_library
-- ══════════════════════════════════════════════════════════════════════════════

let haskellLibrary =
      { impl =
          R.ruleImpl "haskell_library" ''
    ghc = _get_ghc()
    package_db = _get_package_db()
    
    if not ctx.attrs.srcs:
        return [
            DefaultInfo(),
            HaskellLibraryInfo(package_name = ctx.attrs.name, modules = []),
        ]
    
    # Output directories
    obj_dir = ctx.actions.declare_output("objs", dir = True)
    hi_dir = ctx.actions.declare_output("hi", dir = True)
    stub_dir = ctx.actions.declare_output("stubs", dir = True)
    
    # Collect dependency hi directories for -i flag
    dep_hi_dirs = []
    dep_objects = []
    for dep in ctx.attrs.deps:
        if HaskellLibraryInfo in dep:
            lib_info = dep[HaskellLibraryInfo]
            if lib_info.hi_dir:
                dep_hi_dirs.append(lib_info.hi_dir)
            if lib_info.objects:
                dep_objects.extend(lib_info.objects)
            elif lib_info.object_dir:
                dep_objects.append(lib_info.object_dir)
    
    # Build GHC command
    cmd = cmd_args([ghc])
    cmd.add("-no-link")
    cmd.add("-package-env=-")
    
    if package_db:
        cmd.add("-package-db", package_db)
    
    cmd.add("-odir", obj_dir.as_output())
    cmd.add("-hidir", hi_dir.as_output())
    cmd.add("-stubdir", stub_dir.as_output())
    
    # Generate .hie files for IDE support (go-to-definition, etc.)
    hie_dir = ctx.actions.declare_output("hie", dir = True)
    cmd.add("-fwrite-ide-info")
    cmd.add("-hiedir", hie_dir.as_output())
    
    # Mandatory flags (non-negotiable)
    cmd.add(MANDATORY_GHC_FLAGS)
    
    # Language extensions
    cmd.add("-XGHC2024")
    for ext in ctx.attrs.language_extensions:
        cmd.add("-X{}".format(ext))
    
    # GHC options
    cmd.add(ctx.attrs.ghc_options)
    
    # Packages
    for pkg in ctx.attrs.packages:
        cmd.add("-package", pkg)
    
    # Include paths for dependencies
    for hi_d in dep_hi_dirs:
        cmd.add(cmd_args("-i", hi_d, delimiter = ""))
    
    # Sources
    cmd.add(ctx.attrs.srcs)
    
    ctx.actions.run(cmd, category = "haskell_compile", identifier = ctx.attrs.name)
    
    # Create static library from objects
    lib = ctx.actions.declare_output("lib{}.a".format(ctx.attrs.name))
    ar_cmd = cmd_args(
        "/bin/sh", "-c",
        cmd_args("ar rcs", lib.as_output(), cmd_args(obj_dir, format = "{}/*.o"), delimiter = " "),
    )
    ctx.actions.run(ar_cmd, category = "haskell_archive", identifier = ctx.attrs.name)
    
    return [
        DefaultInfo(
            default_output = lib,
            sub_targets = {
                "hi": [DefaultInfo(default_outputs = [hi_dir])],
                "stubs": [DefaultInfo(default_outputs = [stub_dir])],
                "objects": [DefaultInfo(default_outputs = [obj_dir])],
                "hie": [DefaultInfo(default_outputs = [hie_dir])],
            },
        ),
        HaskellLibraryInfo(
            package_name = ctx.attrs.name,
            hi_dir = hi_dir,
            object_dir = lib,
            stub_dir = stub_dir,
            hie_dir = hie_dir,
            objects = [],
            modules = ctx.attrs.srcs,
        ),
    ]
''
      , attrs =
          [ R.sourceListAttr "srcs"
          , R.depListAttr "deps"
          , R.stringListAttr "packages"
          , R.stringListAttr "ghc_options"
          , R.stringListAttr "language_extensions"
          ]
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_binary
-- ══════════════════════════════════════════════════════════════════════════════

let haskellBinaryImpl = ''
    ghc = _get_ghc()
    package_db = _get_package_db()
    
    out = ctx.actions.declare_output(ctx.attrs.name)
    
    # Output directories for intermediate files (keeps source tree clean)
    obj_dir = ctx.actions.declare_output("objs", dir = True)
    hi_dir = ctx.actions.declare_output("hi", dir = True)
    
    # Collect dependency info
    dep_hi_dirs = []
    dep_libs = []
    dep_sources = []  # For source-based deps
    for dep in ctx.attrs.deps:
        if HaskellLibraryInfo in dep:
            lib_info = dep[HaskellLibraryInfo]
            if lib_info.hi_dir:
                dep_hi_dirs.append(lib_info.hi_dir)
            if lib_info.objects:
                dep_libs.extend(lib_info.objects)
            elif lib_info.object_dir:
                dep_libs.append(lib_info.object_dir)
            # Also collect source modules for source-based compilation
            if lib_info.modules:
                dep_sources.extend(lib_info.modules)
    
    cmd = cmd_args([ghc])
    cmd.add("-package-env=-")
    cmd.add("-O2")
    
    # Output directories (intermediate .o/.hi files go to buck-out, not source tree)
    cmd.add("-odir", obj_dir.as_output())
    cmd.add("-hidir", hi_dir.as_output())
    
    # Generate .hie files for IDE support (go-to-definition, etc.)
    hie_dir = ctx.actions.declare_output("hie", dir = True)
    cmd.add("-fwrite-ide-info")
    cmd.add("-hiedir", hie_dir.as_output())


    # Mandatory flags (non-negotiable)
    cmd.add(MANDATORY_GHC_FLAGS)
    cmd.add("-XGHC2024")
    
    if package_db:
        cmd.add("-package-db", package_db)
    
    # Main module
    if ctx.attrs.main:
        cmd.add("-main-is", ctx.attrs.main)
    
    cmd.add("-o", out.as_output())
    
    # Language extensions
    for ext in ctx.attrs.language_extensions:
        cmd.add("-X{}".format(ext))
    
    # GHC options (includes compiler_flags for backwards compat)
    cmd.add(ctx.attrs.ghc_options)
    cmd.add(ctx.attrs.compiler_flags)
    
    # Packages
    for pkg in ctx.attrs.packages:
        cmd.add("-package", pkg)
    
    # Include paths for dependencies
    for hi_d in dep_hi_dirs:
        cmd.add(cmd_args("-i", hi_d, delimiter = ""))
    
    # Sources (our sources + source-based deps)
    cmd.add(ctx.attrs.srcs)
    cmd.add(dep_sources)
    
    # Link against compiled deps
    cmd.add(dep_libs)
    
    ctx.actions.run(cmd, category = "ghc", identifier = ctx.attrs.name)
    
    return [
        DefaultInfo(
            default_output = out,
            sub_targets = {
                "hi": [DefaultInfo(default_outputs = [hi_dir])],
                "hie": [DefaultInfo(default_outputs = [hie_dir])],
            },
        ),
        RunInfo(args = cmd_args(out)),
    ]
''

let haskellBinaryAttrs =
      [ R.sourceListAttr "srcs"
      , R.depListAttr "deps"
      , R.optionStringAttr "main"
      , R.stringListAttr "packages"
      , R.stringListAttr "ghc_options"
      , R.stringListAttr "language_extensions"
      , R.stringListAttr "compiler_flags"
      ]

let haskellBinary =
      { impl = R.ruleImpl "haskell_binary" haskellBinaryImpl
      , attrs = haskellBinaryAttrs
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_c_library - FFI exports callable from C/C++
-- ══════════════════════════════════════════════════════════════════════════════

let haskellCLibrary =
      { impl =
          R.ruleImpl "haskell_c_library" ''
    ghc = _get_ghc()
    package_db = _get_package_db()
    
    stub_dir = ctx.actions.declare_output("stubs", dir = True)
    lib = ctx.actions.declare_output("lib{}.a".format(ctx.attrs.name))
    
    # Collect dependency hi directories
    dep_hi_dirs = []
    for dep in ctx.attrs.deps:
        if HaskellLibraryInfo in dep:
            lib_info = dep[HaskellLibraryInfo]
            if lib_info.hi_dir:
                dep_hi_dirs.append(lib_info.hi_dir)
    
    # Compile each source individually to get proper stub generation
    objects = []
    hi_files = []
    
    for src in ctx.attrs.srcs:
        src_path = src.short_path
        if src_path.endswith(".hs"):
            base_name = src_path.replace(".hs", "").split("/")[-1]
            obj = ctx.actions.declare_output("{}.o".format(base_name))
            hi = ctx.actions.declare_output("{}.hi".format(base_name))
            
            cmd = cmd_args([ghc])
            cmd.add("-c")
            cmd.add("-package-env=-")
            cmd.add("-fPIC")  # Position independent for shared libs
            
            if package_db:
                cmd.add("-package-db", package_db)
            
            cmd.add("-stubdir", stub_dir.as_output())
            cmd.add("-o", obj.as_output())
            cmd.add("-ohi", hi.as_output())
            
            # Mandatory flags (non-negotiable)
            cmd.add(MANDATORY_GHC_FLAGS)
            
            # Language extensions (ForeignFunctionInterface is required)
            cmd.add("-XGHC2024")
            cmd.add("-XForeignFunctionInterface")
            for ext in ctx.attrs.language_extensions:
                cmd.add("-X{}".format(ext))
            
            cmd.add(ctx.attrs.ghc_options)
            
            # Dependencies
            for hi_d in dep_hi_dirs:
                cmd.add(cmd_args("-i", hi_d, delimiter = ""))
            
            for pkg in ctx.attrs.packages:
                cmd.add("-package", pkg)
            
            cmd.add(src)
            
            ctx.actions.run(cmd, category = "haskell_compile", identifier = src_path)
            objects.append(obj)
            hi_files.append(hi)
    
    if not objects:
        return [DefaultInfo()]
    
    # Create hi directory with symlinks
    hi_dir = ctx.actions.declare_output("hi", dir = True)
    hi_symlinks = {hi.basename: hi for hi in hi_files}
    ctx.actions.symlinked_dir(hi_dir, hi_symlinks)
    
    # Archive objects
    ar_cmd = cmd_args("ar", "rcs", lib.as_output())
    ar_cmd.add(objects)
    ctx.actions.run(ar_cmd, category = "haskell_archive", identifier = ctx.attrs.name)
    
    return [
        DefaultInfo(
            default_output = lib,
            sub_targets = {
                "stubs": [DefaultInfo(default_outputs = [stub_dir])],
                "hi": [DefaultInfo(default_outputs = hi_files)],
                "objects": [DefaultInfo(default_outputs = objects)],
            },
        ),
        HaskellIncludeInfo(include_dirs = [stub_dir]),
        HaskellLibraryInfo(
            package_name = ctx.attrs.name,
            hi_dir = hi_dir,
            object_dir = lib,
            stub_dir = stub_dir,
            objects = objects,
            modules = [],
        ),
    ]
''
      , attrs =
          [ R.sourceListAttr "srcs"
          , R.depListAttr "deps"
          , R.stringListAttr "packages"
          , R.stringListAttr "ghc_options"
          , R.stringListAttr "language_extensions"
          ]
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_ffi_binary - Haskell calling C/C++ via FFI
-- ══════════════════════════════════════════════════════════════════════════════

let haskellFfiBinaryImpl = ''
    ghc = _get_ghc()
    ghc_pkg = _get_ghc_pkg()
    cxx = read_root_config("cxx", "cxx", "clang++")
    
    # Read library paths from config (for Nix-provided libraries)
    liburing_lib = read_root_config("io-uring", "liburing_lib", "")
    liburing_include = read_root_config("io-uring", "liburing_include", "")
    
    # C++ stdlib paths for unwrapped clang
    gcc_include = read_root_config("cxx", "gcc_include", "")
    gcc_include_arch = read_root_config("cxx", "gcc_include_arch", "")
    glibc_include = read_root_config("cxx", "glibc_include", "")
    clang_resource_dir = read_root_config("cxx", "clang_resource_dir", "")
    gcc_lib_base = read_root_config("cxx", "gcc_lib_base", "")
    
    out = ctx.actions.declare_output(ctx.attrs.name)
    
    # Step 1: Compile C++ sources
    cxx_compile_flags = ["-std=c++17", "-O2", "-fPIC", "-c"]
    
    if gcc_include:
        cxx_compile_flags.extend(["-isystem", gcc_include])
    if gcc_include_arch:
        cxx_compile_flags.extend(["-isystem", gcc_include_arch])
    if glibc_include:
        cxx_compile_flags.extend(["-isystem", glibc_include])
    if clang_resource_dir:
        cxx_compile_flags.extend(["-resource-dir=" + clang_resource_dir])
    
    cxx_compile_flags.extend(["-I", "."])
    
    # Add user-specified include directories
    for inc_dir in ctx.attrs.include_dirs:
        cxx_compile_flags.extend(["-I", inc_dir])
    
    # Add config-provided include directories (from Nix)
    if liburing_include:
        cxx_compile_flags.extend(["-I", liburing_include])
    
    cxx_objects = []
    for src in ctx.attrs.cxx_srcs:
        obj_name = src.short_path.replace(".cpp", ".o").replace(".c", ".o")
        obj = ctx.actions.declare_output(obj_name)
        
        cmd = cmd_args([cxx] + cxx_compile_flags + ["-o", obj.as_output(), src])
        ctx.actions.run(cmd, category = "cxx_compile", identifier = src.short_path)
        cxx_objects.append(obj)
    
    # Step 2: Compile Haskell and link
    # Output directories for intermediate files (keeps source tree clean)
    obj_dir = ctx.actions.declare_output("hs_objs", dir = True)
    hi_dir = ctx.actions.declare_output("hs_hi", dir = True)
    
    # Use ghc-pkg-id wrapper script to translate -package to -package-id
    # This works around GHC 9.12 bug where -package doesn't expose packages
    # Path comes from config, set by flake module's shellHook
    ghc_wrapper = read_root_config("haskell", "ghc_pkg_wrapper", "bin/ghc-pkg-id")
    ghc_cmd = cmd_args([ghc_wrapper, ghc, ghc_pkg])
    ghc_cmd.add("-O2", "-threaded")
    
    # Output directories (intermediate .o/.hi files go to buck-out, not source tree)
    ghc_cmd.add("-odir", obj_dir.as_output())
    ghc_cmd.add("-hidir", hi_dir.as_output())
    
    # Mandatory flags (non-negotiable)
    ghc_cmd.add(MANDATORY_GHC_FLAGS)
    ghc_cmd.add("-XGHC2024")
    
    # GCC library path for libstdc++
    if gcc_lib_base:
        ghc_cmd.add("-optl", "-L" + gcc_lib_base)
    
    # Extra library directories from attrs
    for lib_dir in ctx.attrs.extra_lib_dirs:
        ghc_cmd.add("-optl", "-L" + lib_dir)
        ghc_cmd.add("-optl", "-Wl,-rpath," + lib_dir)
    
    # Config-provided library directories (from Nix)
    if liburing_lib:
        ghc_cmd.add("-optl", "-L" + liburing_lib)
        ghc_cmd.add("-optl", "-Wl,-rpath," + liburing_lib)
    
    ghc_cmd.add("-lstdc++")
    
    # Link against extra libraries
    for lib in ctx.attrs.extra_libs:
        ghc_cmd.add("-l" + lib)
    
    # Extra linker flags
    for flag in ctx.attrs.linker_flags:
        ghc_cmd.add("-optl", flag)
    
    ghc_cmd.add("-o", out.as_output())
    
    # Language extensions
    for ext in ctx.attrs.language_extensions:
        ghc_cmd.add("-X{}".format(ext))
    
    # GHC options from attrs
    ghc_cmd.add(ctx.attrs.ghc_options)
    
    # Packages
    for pkg in ctx.attrs.packages:
        ghc_cmd.add("-package", pkg)
    
    ghc_cmd.add(ctx.attrs.compiler_flags)
    ghc_cmd.add(ctx.attrs.hs_srcs)
    ghc_cmd.add(cxx_objects)
    
    ctx.actions.run(ghc_cmd, category = "ghc_link", identifier = ctx.attrs.name)
    
    return [
        DefaultInfo(default_output = out),
        RunInfo(args = [out]),
    ]
''

let haskellFfiBinaryAttrs =
      [ R.sourceListAttr "hs_srcs"
      , R.sourceListAttr "cxx_srcs"
      , R.sourceListAttr "cxx_headers"
      , R.depListAttr "deps"
      , R.stringListAttr "packages"
      , R.stringListAttr "compiler_flags"
      , R.stringListAttr "language_extensions"
      , R.stringListAttr "ghc_options"
      , R.stringListAttr "extra_libs"
      , R.stringListAttr "extra_lib_dirs"
      , R.stringListAttr "include_dirs"
      , R.stringListAttr "linker_flags"
      ]

let haskellFfiBinary =
      { impl = R.ruleImpl "haskell_ffi_binary" haskellFfiBinaryImpl
      , attrs = haskellFfiBinaryAttrs
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_ffi_test - FFI test executable (same as ffi_binary)
-- ══════════════════════════════════════════════════════════════════════════════

let haskellFfiTest =
      { impl = R.ruleImpl "haskell_ffi_test" haskellFfiBinaryImpl
      , attrs = haskellFfiBinaryAttrs
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_script - Single-file scripts
-- ══════════════════════════════════════════════════════════════════════════════

let haskellScript =
      { impl =
          R.ruleImpl "haskell_script" ''
    ghc = _get_ghc()
    
    out = ctx.actions.declare_output(ctx.attrs.name)
    
    # Output directories for intermediate files (keeps source tree clean)
    obj_dir = ctx.actions.declare_output("objs", dir = True)
    hi_dir = ctx.actions.declare_output("hi", dir = True)
    
    cmd = cmd_args([ghc])
    
    # Output directories (intermediate .o/.hi files go to buck-out, not source tree)
    cmd.add("-odir", obj_dir.as_output())
    cmd.add("-hidir", hi_dir.as_output())
    
    # Mandatory flags (non-negotiable)
    cmd.add(MANDATORY_GHC_FLAGS)
    cmd.add("-XGHC2024")
    
    cmd.add(ctx.attrs.compiler_flags)
    cmd.add("-o", out.as_output())
    
    for include_path in ctx.attrs.include_paths:
        cmd.add("-i" + include_path)
    
    for pkg in ctx.attrs.packages:
        cmd.add("-package", pkg)
    
    cmd.add(ctx.attrs.srcs)
    
    ctx.actions.run(cmd, category = "haskell_script", identifier = ctx.attrs.name)
    
    return [
        DefaultInfo(default_output = out),
        RunInfo(args = [out]),
    ]
''
      , attrs =
          [ R.sourceListAttr "srcs"
          , R.stringListAttr "include_paths"
          , R.stringListAttr "compiler_flags"
          , R.stringListAttr "packages"
          ]
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- haskell_test - Test executable (same as binary)
-- ══════════════════════════════════════════════════════════════════════════════

-- Note: haskell_test reuses _haskell_binary_impl but we need to generate
-- it as a separate rule. We use the same impl body.
let haskellTest =
      { impl = R.ruleImpl "haskell_test" haskellBinaryImpl
      , attrs = haskellBinaryAttrs
      }

-- ══════════════════════════════════════════════════════════════════════════════
-- Complete file
-- ══════════════════════════════════════════════════════════════════════════════

let file =
      R.bzlFile
        with header = ''
# Haskell toolchain and rules using GHC from Nix.
#
# Uses ghcWithPackages from the Nix devshell, which includes all
# dependencies. The bin/ghc wrapper filters Mercury-specific flags
# that stock GHC doesn't understand.
#
# Paths are read from .buckconfig.local [haskell] section.
#
# Rules:
#   haskell_toolchain  - toolchain definition
#   haskell_library    - compile to .hi/.o with HaskellLibraryInfo
#   haskell_binary     - executable from sources + deps
#   haskell_c_library  - FFI exports callable from C/C++
#   haskell_ffi_binary - Haskell calling C/C++ via FFI
#   haskell_ffi_test   - FFI test executable
#   haskell_script     - single-file scripts
#   haskell_test       - test executable
''
        with loads =
            [ R.load "@prelude//haskell:toolchain.bzl" ["HaskellToolchainInfo", "HaskellPlatformInfo"]
            ]
        with globals = globals
        with providers = [ haskellLibraryInfo, haskellIncludeInfo ]
        with rules =
            [ haskellToolchain
            , haskellLibrary
            , haskellBinary
            , haskellCLibrary
            , haskellFfiBinary
            , haskellFfiTest
            , haskellScript
            , haskellTest
            ]

in  { file, render = S.renderBzlFile file }
