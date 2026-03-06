# Flake Module Assessment

This document assesses the robustness of importing sensenet's flake module to get the full build toolchain.

## TL;DR

**Robustness: Medium-High** for supported use cases.

The flake module works well for:
- Projects using C++, Haskell, Rust, Lean, PureScript
- Local development with `nix develop`
- Buck2 builds with hermetic toolchains

Gaps exist for:
- macOS (untested, Linux-focused)
- NVIDIA/CUDA (requires private `nvidia-sdk` input)
- Remote execution (requires NativeLink infrastructure)

## Usage

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sensenet.url = "github:straylight-software/sensenet";
  };

  outputs = { nixpkgs, sensenet, ... }: {
    imports = [ sensenet.flakeModules.sensenet ];

    perSystem = { pkgs, ... }: {
      sensenet.projects.myapp = {
        src = ./.;
        targets = [ "//src:myapp" ];
        
        toolchain = {
          cxx.enable = true;
          haskell.enable = true;
          haskell.packages = hp: [ hp.aeson hp.text ];
          rust.enable = true;
        };
      };
    };
  };
}
```

This creates:
- `packages.sensenet-myapp` - Nix derivation that runs `buck2 build`
- `devShells.sensenet-myapp` - Development shell with all toolchains

## What Works

### C++ Toolchain

**Status: Robust**

```nix
toolchain.cxx = {
  enable = true;  # Default: true
  llvmpackages = pkgs.llvmPackages_19;  # Override LLVM version
  libraries = [ pkgs.zlib pkgs.openssl ];  # Add library deps
};
```

- Uses LLVM from nixpkgs (default: 19)
- Generates complete `.buckconfig.local` with paths
- Include/link paths auto-configured from `libraries`
- Works on Linux x86_64 and aarch64

**Gaps:**
- No cross-compilation support
- No macOS testing (Darwin may have issues)

### Haskell Toolchain

**Status: Robust**

```nix
toolchain.haskell = {
  enable = true;
  packages = hp: [ hp.aeson hp.text hp.bytestring ];
  ghcpackages = pkgs.haskell.packages.ghc912;  # Override GHC version
};
```

- Uses `ghcWithPackages` from nixpkgs
- GHC 9.12 workaround for `-package` flag (generates package IDs)
- IDE support: generates `hie.yaml` in shell hook
- Hoogle with pre-built database included

**Gaps:**
- No Template Haskell cross-compilation
- Requires packages available in nixpkgs Haskell set

### Rust Toolchain

**Status: Robust**

```nix
toolchain.rust.enable = true;
```

- Uses rustc/cargo/clippy from nixpkgs
- rust-analyzer included in devshell

**Gaps:**
- No cargo build script support (manual workarounds needed)
- No workspace support

### Lean 4 Toolchain

**Status: Works**

```nix
toolchain.lean.enable = true;
```

- Uses lean4 from nixpkgs
- C code extraction supported

**Gaps:**
- No Lake integration
- No Mathlib support (manual setup)

### PureScript Toolchain

**Status: Works (with caveats)**

```nix
toolchain.purescript.enable = true;
```

- Uses purs/spago/node from nixpkgs
- Halogen app bundling with esbuild

**Gaps:**
- **Network required** - spago fetches packages during build
- Not hermetic - depends on registry availability

### Python Toolchain

**Status: Minimal**

```nix
toolchain.python = {
  enable = true;
  package = pkgs.python312;
};
```

- Basic Python interpreter only
- pybind11 support for C++ bindings

**Gaps:**
- No pip/virtualenv
- No wheel building
- Intended for build scripting only

## What Doesn't Work (Or Requires Extra Setup)

### NVIDIA/CUDA

**Status: Requires Private Input**

```nix
toolchain.nv.enable = true;  # Won't work without nvidia-sdk
```

The CUDA toolchain requires:
1. `inputs.nvidia-sdk` - private straylight repository
2. LLVM from straylight fork (SM120 support)

**Without nvidia-sdk:**
```
error: attribute 'nvidia-sdk' missing
```

To use CUDA, you must either:
- Have access to `github:straylight-software/nvidia-sdk`
- Provide your own CUDA setup via `extrabuckconfigsections`

### Remote Execution

**Status: Requires Infrastructure**

```nix
remoteexecution = {
  enable = true;
  scheduler = "your-scheduler.example.com";
  cas = "your-cas.example.com";
};
```

Requires:
- Running NativeLink scheduler
- Running NativeLink CAS (S3/R2 backend)
- Workers with matching Nix toolchains

The module generates correct `.buckconfig.local` sections, but you need the infrastructure.

### macOS

**Status: Untested**

The toolchains are Linux-focused:
- Paths assume glibc, gcc libs, etc.
- CUDA not available on macOS
- May work for basic C++/Haskell/Rust but untested

## Required Inputs

Sensenet's flake requires these inputs:

```nix
inputs = {
  nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  
  # Required - Buck2 prelude rules
  buck2-prelude.url = "github:weyl-ai/straylight-buck2-prelude";
  buck2-prelude.flake = false;
  
  # Optional - for LLVM 22 with SM120 support
  llvm-project.url = "github:straylight-software/llvm-project";
  
  # Optional - for CUDA
  nvidia-sdk.url = "git+ssh://git@github.com/straylight-software/nvidia-sdk.git";
  
  # Optional - for PureScript
  purescript-overlay.url = "github:thomashoneyman/purescript-overlay";
};
```

### Transitive Dependencies

When you import the sensenet flake module, it brings:

| Dependency | Size | Required |
|------------|------|----------|
| buck2-prelude | ~5MB | Yes |
| llvm-project | ~2GB | Optional (for custom LLVM) |
| nvidia-sdk | ~1GB | Optional (for CUDA) |
| purescript-overlay | ~50MB | Optional (for PureScript) |

## Shell Hook Behavior

On `nix develop`, the shell hook:

1. Creates `nix/build/prelude` symlink to Buck2 prelude
2. Copies `toolchains/` to `nix/build/toolchains/` (Buck2 requires real files)
3. Generates `.buckconfig.local` with tool paths
4. For Haskell: generates package ID mappings (GHC 9.12 workaround)
5. For C++: generates `compile_commands.json` via BXL
6. Runs `dhall-to-buck` if present (BUILD.dhall -> BUCK generation)

### Files Created

```
.buckconfig.local          # Generated, gitignored
nix/build/prelude/         # Symlink to Nix store
nix/build/toolchains/      # Copy of toolchains/
compile_commands.json      # Generated for clangd
hie.yaml                   # Generated for HLS (in devshell.nix)
.clangd, .clang-format     # Symlinked from nix/configs/
```

## Package Derivation

The generated `packages.sensenet-<name>` derivation:

1. Sets `__noChroot = true` (allows buck2 daemon access)
2. Links prelude from Nix store
3. Copies `.buckconfig.local`
4. Runs `buck2 build <targets>`
5. Installs ELF executables to `$out/bin/`

**Caveats:**
- `__noChroot = true` is required but breaks pure evaluation
- Cannot be built in pure Nix sandbox
- Requires network access if remote execution enabled

## Robustness Rating

| Aspect | Rating | Notes |
|--------|--------|-------|
| C++ toolchain | High | Well-tested, complete |
| Haskell toolchain | High | Well-tested, IDE support |
| Rust toolchain | Medium | Works, no cargo support |
| Lean toolchain | Medium | Works, no Lake |
| PureScript | Medium | Requires network |
| CUDA | Low | Requires private input |
| Remote execution | Low | Requires infrastructure |
| macOS support | Low | Untested |
| Documentation | Medium | This doc helps |
| Error messages | Medium | Some cryptic failures |

## Recommendations for Downstream Users

### Minimal Setup (C++ only)

```nix
{
  inputs.sensenet.url = "github:straylight-software/sensenet";
  
  outputs = { sensenet, ... }: {
    imports = [ sensenet.flakeModules.sensenet ];
    
    perSystem = { ... }: {
      sensenet.projects.myapp = {
        src = ./.;
        targets = [ "//src:main" ];
        # C++ enabled by default
      };
    };
  };
}
```

### Full Polyglot Setup

```nix
{
  inputs = {
    sensenet.url = "github:straylight-software/sensenet";
    purescript-overlay.url = "github:thomashoneyman/purescript-overlay";
  };
  
  outputs = { sensenet, ... }: {
    imports = [ sensenet.flakeModules.sensenet ];
    
    perSystem = { pkgs, ... }: {
      sensenet.projects.myapp = {
        src = ./.;
        targets = [ "//..." ];
        
        toolchain = {
          cxx.enable = true;
          cxx.libraries = [ pkgs.zlib pkgs.openssl ];
          
          haskell.enable = true;
          haskell.packages = hp: [ hp.aeson hp.text hp.servant ];
          
          rust.enable = true;
          lean.enable = true;
          purescript.enable = true;
        };
        
        devshellpackages = [ pkgs.jq pkgs.ripgrep ];
        devshellhook = ''
          echo "Welcome to myapp development"
        '';
      };
    };
  };
}
```

### Minimum .buckconfig

Your project needs a `.buckconfig` file. Here's the minimum required:

```ini
[cells]
root = .
prelude = nix/build/prelude
toolchains = nix/build/toolchains

[parser]
target_platform_detector_spec = target:root//...->prelude//platforms:default

[build]
execution_platforms = toolchains//:local
```

The flake module generates these at shell entry:
- `nix/build/prelude` - symlink to Buck2 prelude
- `nix/build/toolchains` - copy of sensenet toolchain rules
- `.buckconfig.local` - toolchain paths and RE settings

See `examples/downstream-project/` for a complete working example.

### Remote Execution Testing

When remote execution is enabled, the shell provides an `re-test` function:

```bash
# In nix develop shell with remoteexecution.enable = true
re-test
```

This shows:
1. RE settings from `.buckconfig.local`
2. Execution platform resolution
3. Dry-run build with `--prefer-remote`

### Troubleshooting

**"attribute 'nvidia-sdk' missing"**
- CUDA toolchain requires private input
- Disable with `toolchain.nv.enable = false;`

**Buck2 fails with "cell not found"**
- Ensure `nix/build/prelude` exists
- Run `mkdir -p nix/build && ln -s <prelude-path> nix/build/prelude`

**Haskell packages not found**
- Check package is in nixpkgs Haskell set
- Try specifying `ghcpackages = pkgs.haskell.packages.ghc912;`

**PureScript build fails**
- Requires network access for spago
- Check `spago.yaml` is valid
