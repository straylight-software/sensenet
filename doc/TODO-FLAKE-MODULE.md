# TODO: Production-Ready Buck2 Remote Build Flake Module

Goal: Make sensenet's flake module robust for downstream users to get working remote builds.

**Assumptions**: nvidia-sdk and nix2gpu are acceptable dependencies.

---

## Completed

### 1. [x] Create `nix/modules/flake/nativelink/scripts/`

All 8 scripts created:

| File | Purpose |
|------|---------|
| `toolchain-setup.sh` | Fetch Nix toolchains on worker boot via `nix copy` |
| `scheduler-fly.toml` | Fly.io scheduler deployment config |
| `cas-fly.toml` | Fly.io CAS deployment config |
| `worker-fly.toml` | Fly.io worker deployment config |
| `builder-fly.toml` | Fly.io builder deployment config |
| `deploy-all.sh` | Unified deployment: scheduler + cas + workers |
| `status.sh` | Health check for all services |
| `logs.sh` | Aggregate logs from all services |

### 2. [x] Add ISA to remote execution properties

Added `_get_isa()` helper and ISA property in `toolchains/execution.bzl:33,60`

### 3. [x] Ensure container-image matches across configs

Verified all use `nix-worker`:
- `toolchains/execution.bzl:59`
- `nix/modules/flake/sensenet/toolchains.nix:209`
- `nix/modules/flake/nativelink/flake-module.nix:354` (default)

### 4. [x] Worker OCI image with matching toolchains

Already implemented in `nix/modules/flake/nativelink/flake-module.nix`:

- `nativelink-worker` container defined (lines 1004-1025)
- `toolchain-packages` list defined (lines 704-719)
- `toolchain-manifest` exports store paths (lines 724-726)
- `worker-setup-script` fetches from cache at runtime (lines 730-747)

**Architecture**: Workers are minimal images that fetch toolchains at startup via `nix copy --from cache.nixos.org`. This keeps images small (<8GB for Fly.io) while ensuring exact path matching with clients.

### 5. [x] Add auth token support for production RE

Added `authtoken` option in:
- `nix/modules/flake/sensenet/options.nix:150`
- `nix/modules/flake/sensenet/toolchains.nix:185,205`
- `nix/modules/flake/sensenet/flake-module.nix:117`

### 6. [x] Create example downstream flake

Created `examples/downstream-project/`:
- `flake.nix` - Complete example with sensenet module import
- `.buckconfig` - Minimum required Buck2 config
- `src/main.cpp` - Example C++ source
- `src/BUCK` - Example BUCK file
- `README.md` - Usage documentation

### 7. [x] Add RE connection test to devshell

Added `re-test()` function to `nix/modules/flake/sensenet/shell-hook.bash`:
- Shows RE settings from `.buckconfig.local`
- Runs `buck2 audit execution-platform-resolution`
- Tests dry-run build with `--prefer-remote`

### 8. [x] Document minimum .buckconfig

Documented in:
- `examples/downstream-project/README.md`
- `examples/downstream-project/.buckconfig`
- `doc/FLAKE-MODULE.md` (Minimum .buckconfig section)

### 9. [x] Add GCP deployment for aarch64 workers

Fly.io only supports x86_64. Added GCP deployment scripts for aarch64 via T2A instances:

**Scripts created:**
- `nix/modules/flake/nativelink/scripts/deploy-gcp.sh` - Unified GCP deployment
- `nix/modules/flake/nativelink/scripts/worker-gcp.sh` - Worker instance (T2A aarch64)
- `nix/modules/flake/nativelink/scripts/scheduler-gcp.sh` - Scheduler instance
- `nix/modules/flake/nativelink/scripts/cas-gcp.sh` - CAS instance

**Options added to `sensenet.nativelink`:**
- `provider` - Choose `"fly"` or `"gcp"`
- `app-prefix` - Moved to top level (was under `fly`)
- `gcp.project` - GCP project ID
- `gcp.zone` - GCP zone (default: `us-central1-a`)
- `gcp.worker-machine-type` - Machine type (default: `t2a-standard-16` for aarch64)

**Packages exported:**
- `nativelink-deploy-gcp` - Deploy all GCP infrastructure
- `nativelink-deploy-gcp-worker` - Deploy worker only
- `nativelink-deploy-gcp-scheduler` - Deploy scheduler only
- `nativelink-deploy-gcp-cas` - Deploy CAS only

---

## Status: COMPLETE

All 9 items have been implemented. The flake module is now production-ready for downstream users with both x86_64 (Fly.io) and aarch64 (GCP) support.

---

## Verification

### Fly.io (x86_64)

```bash
# 1. Enable nativelink
sensenet.nativelink.enable = true;

# 2. Build and push worker image
nix build .#nativelink-worker
skopeo copy oci:result docker://ghcr.io/straylight-software/nativelink-worker:latest

# 3. Deploy infrastructure
nix run .#nativelink-deploy

# 4. Test remote build
nix develop
re-test  # Uses the new shell function
buck2 build --prefer-remote //src/examples/cxx:hello-cxx
```

### GCP (aarch64)

```bash
# 1. Configure GCP
sensenet.nativelink = {
  enable = true;
  provider = "gcp";
  gcp.project = "your-project-id";
  gcp.zone = "us-central1-a";
  gcp.worker-machine-type = "t2a-standard-16";  # aarch64
};

# 2. Build and push aarch64 worker image
nix build .#nativelink-worker
skopeo copy oci:result docker://ghcr.io/straylight-software/nativelink-worker:latest

# 3. Deploy to GCP
nix run .#nativelink-deploy-gcp

# 4. Test remote build
nix develop
re-test
buck2 build --prefer-remote //src/examples/cxx:hello-cxx
```

## For Downstream Users

See `examples/downstream-project/` for a complete working example, or:

```nix
{
  inputs.sensenet.url = "github:straylight-software/sensenet";
  
  outputs = { sensenet, ... }: {
    imports = [ sensenet.flakeModules.sensenet ];
    
    perSystem = { ... }: {
      sensenet.projects.myapp = {
        toolchain.cxx.enable = true;
        # Optional: remoteexecution.enable = true;
      };
    };
  };
}
```
