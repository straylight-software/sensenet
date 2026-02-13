# ℵ sensenet

> Minimal viable Nix: formatting, linting, Buck2 toolchains, remote execution.

## Branch Protocol

| Branch | Purpose |
|--------|---------|
| `main` | Post-review, stable. All commits have been reviewed. |
| `dev` | Moving ref to unblock. Integration branch for active development. |
| `user/the-thing-<linear-id>` | Feature/fix branches. Named `b7r6/feature-name-SLI-123`. |

### Commit Message Convention

```
// project // area // description // 0x0N

Examples:
// sensenet // toolchain // add GHC 9.12 support // 0x01
// sensenet // buck2 // fix haskell_binary rule // 0x02
// sensenet // devshell // add tokenizers-cpp paths // 0x03
```

The `0x0N` suffix is a sequential counter within the branch for easy reference.

---

## Quick Start

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    sense.url = "github:straylight-software/sensenet";
  };

  outputs = { nixpkgs, sense, ... }: {
    # Import the default module
    imports = [ sense.flakeModules.default ];

    perSystem = { pkgs, config, ... }: {
      # Buck2 target → Nix derivation
      packages.myapp = config.buck2.build {
        target = "//src:myapp";
      };
    };
  };
}
```

Then:

```bash
nix fmt          # Format everything
nix flake check  # Lint everything
nix develop      # Shell with buck2 + toolchains
```

## What You Get

### LLVM 22 from git

SM120 (Blackwell) support. Clean clang without nixpkgs' CUDA wrapper hacks.

```nix
pkgs.llvm-git  # Available via overlay
```

### Formatting (`nix fmt`)

| Language | Tool |
|----------|------|
| Nix | nixfmt |
| C/C++/CUDA | clang-format |
| Python | ruff |
| Rust | rustfmt |
| Haskell | fourmolu |
| JavaScript/TypeScript | biome |
| Lua | stylua |
| TOML | taplo |
| YAML | yamlfmt |
| Markdown | mdformat |
| Shell | shfmt |

### Linting (`nix flake check`)

| Language | Tools |
|----------|-------|
| Nix | statix, deadnix, ast-grep rules |
| C/C++ | clang-tidy, cppcheck, ast-grep rules |
| Shell | shellcheck |
| Python | ruff check |

### Buck2 Integration

Dhall-typed toolchains and build specifications. No external prelude—we bring our own.

```dhall
-- dhall/Toolchain.dhall
let Toolchain = { cc : Text, cxx : Text, ar : Text, ... }
```

### Remote Execution

NativeLink CAS for distributed builds:

```nix
sense.build.remote.enable = true;
```

## Modules

| Module | Purpose |
|--------|---------|
| `flakeModules.default` | All of the below |
| `flakeModules.formatter` | treefmt integration |
| `flakeModules.lint` | Lint configs + rules |
| `flakeModules.buck2` | Buck2 → Nix derivation |
| `flakeModules.build` | Toolchain options |
| `flakeModules.devshell` | Development shell |
| `flakeModules.nativelink` | Remote execution |
| `flakeModules.std` | nixpkgs + llvm-git overlay |

## Overlays

```nix
{
  nixpkgs.overlays = [ sense.overlays.default ];
  # or
  nixpkgs.overlays = [ sense.overlays.llvm-git ];
}
```

## Lint Rules

AST-grep rules in `linter/rules/`:

| Rule | Description |
|------|-------------|
| `no-raw-mkderivation` | Use builders, not raw mkDerivation |
| `with-lib` | Avoid `with lib;` |
| `rec-in-derivation` | No `rec` in derivation attrs |
| `or-null-fallback` | Prefer `value or null` patterns |
| `missing-meta` | Require meta attributes |
| `cpp-raw-new-delete` | Ban raw new/delete in C++ |
| ... | See `linter/rules/` |

## Part of Sense

This is the bootstrap layer of the Sense project — a ground-up rethinking of Nix infrastructure with formal verification, typed derivations, and daemon-free operation.

## License

MIT
