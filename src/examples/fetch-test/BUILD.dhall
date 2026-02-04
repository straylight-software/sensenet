let Build = ../../../dhall/Build.dhall
let Toolchain = ../../../dhall/Toolchain.dhall
let Resource = ../../../dhall/Resource.dhall

-- Shell build that fetches - declares PURE (lying)
in  { name = "fetch-test"
    , srcs = Build.Src.Files [ "build.sh" ]
    , deps = [] : List Build.Dep
    , toolchain = Toolchain.presets.clang-18-glibc-dynamic
    , requires = Resource.pure  -- LIE: this build fetches
    }
