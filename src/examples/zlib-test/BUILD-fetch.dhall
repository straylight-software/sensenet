let Build = ../../../dhall/Build.dhall
let Toolchain = ../../../dhall/Toolchain.dhall
let Resource = ../../../dhall/Resource.dhall

-- This target declares it needs network (honest)
in  Build.cxx-binary
      { name = "test-fetch-real"
      , srcs = [ "test-fetch-real.cpp" ]
      , deps = [] : List Build.Dep
      , toolchain = Toolchain.presets.clang-18-glibc-dynamic
      , requires = Resource.network  -- declares network access
      }
