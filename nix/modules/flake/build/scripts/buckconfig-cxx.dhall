-- buckconfig-cxx.dhall
-- Generate [cxx] section for .buckconfig.local
--
-- Environment variables (UPPER_SNAKE_CASE):
--   CC, CXX, CPP, AR, LD
--   CLANG_RESOURCE_DIR, GCC_INCLUDE, GCC_INCLUDE_ARCH, GLIBC_INCLUDE
--   GCC_LIB, GCC_LIB_BASE, GLIBC_LIB, MDSPAN_INCLUDE

let env = env:CC as Text
let cxx = env:CXX as Text
let cpp = env:CPP as Text
let ar = env:AR as Text
let ld = env:LD as Text
let clang_resource_dir = env:CLANG_RESOURCE_DIR as Text
let gcc_include = env:GCC_INCLUDE as Text
let gcc_include_arch = env:GCC_INCLUDE_ARCH as Text
let glibc_include = env:GLIBC_INCLUDE as Text
let gcc_lib = env:GCC_LIB as Text
let gcc_lib_base = env:GCC_LIB_BASE as Text
let glibc_lib = env:GLIBC_LIB as Text
let mdspan_include = env:MDSPAN_INCLUDE ? "" as Text

in ''
[cxx]
# Compilers (LLVM)
cc = ${env}
cxx = ${cxx}
cpp = ${cpp}

# Bintools
ar = ${ar}
ld = ${ld}

# Include paths
clang_resource_dir = ${clang_resource_dir}
gcc_include = ${gcc_include}
gcc_include_arch = ${gcc_include_arch}
glibc_include = ${glibc_include}
${if mdspan_include == "" then "" else "mdspan_include = ${mdspan_include}"}

# Library paths
gcc_lib = ${gcc_lib}
gcc_lib_base = ${gcc_lib_base}
glibc_lib = ${glibc_lib}
''
