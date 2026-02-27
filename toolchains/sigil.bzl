# sigil.bzl - Rules for sigil-trtllm (TensorRT + simdjson)
#
# Custom rules for building sigil-trtllm library and binaries.
# Uses nvidia-sdk for TensorRT and simdjson from nix store.

def _sigil_library_impl(ctx: AnalysisContext) -> list[Provider]:
    """Build sigil-trtllm library."""
    
    # Get compiler from config
    cxx = read_root_config("cxx", "cxx", "clang++")
    ld = read_root_config("cxx", "ld", "ld.lld")
    
    # Include paths from config
    gcc_include = read_root_config("cxx", "gcc_include", "")
    gcc_include_arch = read_root_config("cxx", "gcc_include_arch", "")
    glibc_include = read_root_config("cxx", "glibc_include", "")
    clang_resource_dir = read_root_config("cxx", "clang_resource_dir", "")
    
    # sigil-specific deps
    simdjson_include = read_root_config("sigil", "simdjson_include", "")
    simdjson_lib = read_root_config("sigil", "simdjson_lib", "")
    tensorrt_include = read_root_config("sigil", "tensorrt_include", "")
    tensorrt_lib = read_root_config("sigil", "tensorrt_lib", "")
    
    # Base compile flags
    compile_flags = [
        "-std=c++23",
        "-fPIC",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Wno-deprecated-declarations",
        "-Wno-unused-parameter",
        "-c",
    ]
    
    # Add stdlib paths
    if clang_resource_dir:
        compile_flags.extend(["-resource-dir=" + clang_resource_dir])
    if gcc_include:
        compile_flags.extend(["-isystem", gcc_include])
    if gcc_include_arch:
        compile_flags.extend(["-isystem", gcc_include_arch])
    if glibc_include:
        compile_flags.extend(["-isystem", glibc_include])
    
    # Add sigil headers
    compile_flags.extend(["-I", ctx.attrs.include_dir])
    
    # Add simdjson
    if simdjson_include:
        compile_flags.extend(["-isystem", simdjson_include])
    
    # Add TensorRT
    if tensorrt_include:
        compile_flags.extend(["-isystem", tensorrt_include])
    
    # Compile each source file
    objects = []
    for src in ctx.attrs.srcs:
        obj_name = src.short_path.replace("/", "_").replace(".cpp", ".o")
        obj = ctx.actions.declare_output(obj_name)
        
        cmd = cmd_args([cxx] + compile_flags + [
            "-o", obj.as_output(),
            src,
        ])
        
        ctx.actions.run(cmd, category = "sigil_compile", identifier = src.short_path)
        objects.append(obj)
    
    # Create static library
    ar = read_root_config("cxx", "ar", "llvm-ar")
    lib_name = "lib" + ctx.attrs.name + ".a"
    lib_out = ctx.actions.declare_output(lib_name)
    
    ar_cmd = cmd_args([ar, "rcs", lib_out.as_output()] + objects)
    ctx.actions.run(ar_cmd, category = "sigil_archive", identifier = ctx.attrs.name)
    
    return [
        DefaultInfo(default_output = lib_out),
    ]

sigil_library = rule(
    impl = _sigil_library_impl,
    attrs = {
        "srcs": attrs.list(attrs.source(), default = []),
        "include_dir": attrs.string(default = "include"),
        "deps": attrs.list(attrs.dep(), default = []),
    },
)

def _sigil_binary_impl(ctx: AnalysisContext) -> list[Provider]:
    """Build sigil-trtllm binary."""
    
    # Get compiler from config
    cxx = read_root_config("cxx", "cxx", "clang++")
    ld = read_root_config("cxx", "ld", "ld.lld")
    
    # Include paths from config
    gcc_include = read_root_config("cxx", "gcc_include", "")
    gcc_include_arch = read_root_config("cxx", "gcc_include_arch", "")
    glibc_include = read_root_config("cxx", "glibc_include", "")
    clang_resource_dir = read_root_config("cxx", "clang_resource_dir", "")
    gcc_lib = read_root_config("cxx", "gcc_lib", "")
    gcc_lib_base = read_root_config("cxx", "gcc_lib_base", "")
    glibc_lib = read_root_config("cxx", "glibc_lib", "")
    dynamic_linker = read_root_config("cxx", "dynamic_linker", "")
    
    # sigil-specific deps
    simdjson_include = read_root_config("sigil", "simdjson_include", "")
    simdjson_lib = read_root_config("sigil", "simdjson_lib", "")
    tensorrt_include = read_root_config("sigil", "tensorrt_include", "")
    tensorrt_lib = read_root_config("sigil", "tensorrt_lib", "")
    
    # Base compile flags
    compile_flags = [
        "-std=c++23",
        "-O2",
        "-Wall",
        "-Wextra",
        "-Wno-deprecated-declarations",
        "-Wno-unused-parameter",
        "-c",
    ]
    
    # Add stdlib paths
    if clang_resource_dir:
        compile_flags.extend(["-resource-dir=" + clang_resource_dir])
    if gcc_include:
        compile_flags.extend(["-isystem", gcc_include])
    if gcc_include_arch:
        compile_flags.extend(["-isystem", gcc_include_arch])
    if glibc_include:
        compile_flags.extend(["-isystem", glibc_include])
    
    # Add sigil headers
    compile_flags.extend(["-I", ctx.attrs.include_dir])
    
    # Add simdjson
    if simdjson_include:
        compile_flags.extend(["-isystem", simdjson_include])
    
    # Add TensorRT
    if tensorrt_include:
        compile_flags.extend(["-isystem", tensorrt_include])
    
    # Compile source
    objects = []
    for src in ctx.attrs.srcs:
        obj_name = src.short_path.replace("/", "_").replace(".cpp", ".o")
        obj = ctx.actions.declare_output(obj_name)
        
        cmd = cmd_args([cxx] + compile_flags + [
            "-o", obj.as_output(),
            src,
        ])
        
        ctx.actions.run(cmd, category = "sigil_compile", identifier = src.short_path)
        objects.append(obj)
    
    # Link flags
    link_flags = [
        "-fuse-ld=" + ld,
    ]
    
    # Add library search paths
    if simdjson_lib:
        link_flags.extend(["-L" + simdjson_lib, "-Wl,-rpath," + simdjson_lib, "-lsimdjson"])
    if tensorrt_lib:
        link_flags.extend(["-L" + tensorrt_lib, "-Wl,-rpath," + tensorrt_lib, "-lnvinfer", "-lnvinfer_plugin"])
    
    # Add stdlib paths
    if gcc_lib:
        link_flags.extend(["-B" + gcc_lib, "-L" + gcc_lib])
    if gcc_lib_base:
        link_flags.extend(["-L" + gcc_lib_base, "-Wl,-rpath," + gcc_lib_base])
    if glibc_lib:
        link_flags.extend(["-B" + glibc_lib, "-L" + glibc_lib, "-Wl,-rpath," + glibc_lib])
    if dynamic_linker:
        link_flags.append("-Wl,--dynamic-linker=" + dynamic_linker)
    
    # Get library objects from deps
    dep_objects = []
    for dep in ctx.attrs.deps:
        dep_info = dep[DefaultInfo]
        if dep_info.default_output:
            dep_objects.append(dep_info.default_output)
    
    # Link
    out = ctx.actions.declare_output(ctx.attrs.name)
    link_cmd = cmd_args([cxx] + link_flags + [
        "-o", out.as_output(),
    ] + objects + dep_objects)
    
    ctx.actions.run(link_cmd, category = "sigil_link", identifier = ctx.attrs.name)
    
    return [
        DefaultInfo(default_output = out),
        RunInfo(args = cmd_args([out])),
    ]

sigil_binary = rule(
    impl = _sigil_binary_impl,
    attrs = {
        "srcs": attrs.list(attrs.source(), default = []),
        "include_dir": attrs.string(default = "include"),
        "deps": attrs.list(attrs.dep(), default = []),
    },
)
