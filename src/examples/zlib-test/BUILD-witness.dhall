let Build = ../../../dhall/Build.dhall
let Toolchain = ../../../dhall/Toolchain.dhall
let Resource = ../../../dhall/Resource.dhall

in  Build.cxx-binary
      { name = "test-witness"
      , srcs = [ "test-fetch.cpp" ]
      , deps = [] : List Build.Dep
      , toolchain = Toolchain.presets.clang-18-glibc-dynamic
      , requires = Resource.pure
      }
