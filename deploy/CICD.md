# Hermes Agent — CI/CD & Deployment Architecture

Reference for how this fork builds, ships, and runs Hermes Agent on Kubernetes.
Operational how-to lives in [`deploy/README.md`](./README.md); this file is the
architecture + as-deployed state.

## Overview

```
NousResearch/hermes-agent (upstream, read-only)
        │  weekly PR via .github/workflows/sync-upstream.yml
        ▼
ToanlaTech/hermes-agent  (fork = origin)
  ├── main    ← tracks upstream (review PRs here, don't hand-edit)
  └── deploy  ← release branch; every push triggers build-deploy
        │
ToanlaTech/hermes-plugins (private, git submodule at ./hermes-plugins)
        │  pinned commit, checked out with SUBMODULE_TOKEN
        ▼
  .github/workflows/build-deploy.yml
     job build:  docker build ──push──►  GHCR
        • ghcr.io/toanlatech/hermes-agent   (main Dockerfile, untouched)
        • ghcr.io/toanlatech/hermes-plugins (deploy/plugins.Dockerfile, busybox)
        tags: :<commit-sha>  and  :deploy
     job deploy: kubectl set image (KUBECONFIG_B64) ──► rollout
        │
        ▼
  k8s cluster "f5s" (DigitalOcean DOKS), namespace `hermes`
     StatefulSet hermes (1 replica — single-writer SQLite, NOT scalable)
       initContainer plugin-sync: cp plugins image /plugins-src → PVC /opt/data/plugins
       container hermes: /init (s6) → `gateway run`, envFrom Secret + ConfigMap
     PVC hermes-data (do-block-storage, RWO, 10Gi)  ← nightly VolumeSnapshot
     Secret hermes-secrets (OpenRouter key, API key) + ghcr-pull (imagePullSecret)
     NetworkPolicy: deny ingress, egress 443 + DNS only
```

## Why a singleton StatefulSet (not Deployment + HPA)

All agent state — sessions, memory, learned skills, cron — is an **embedded
single-writer SQLite DB** under `/opt/data`. Two replicas would corrupt it.
Scale vertically (bigger node), never horizontally. StatefulSet's default
RollingUpdate terminates the old pod before creating the new one for a
1-replica set, preserving the single-writer guarantee.

## Two-image design

The custom plugin code lives in a **separate image** built from the
`hermes-plugins` submodule, not baked into the Hermes image. This:
- never touches the heavily-maintained upstream `Dockerfile` (no merge
  conflicts when syncing 1000+ upstream branches),
- rebuilds plugins in seconds instead of rebuilding all of Hermes,
- versions/rolls back plugins independently.

At pod start the `plugin-sync` initContainer `cp -a`'s (no `--delete`) the
plugin code onto the PVC at `/opt/data/plugins`, where Hermes discovers it as
**user plugins** (`$HERMES_HOME/plugins`). Plugin runtime data (jsonl logs,
generated files, learned skills) already on the PVC is preserved.

## Repos & branches

| Repo | Role |
|---|---|
| `NousResearch/hermes-agent` | upstream, remote `upstream`, read-only |
| `ToanlaTech/hermes-agent` | fork, remote `origin`; branches `main` (upstream sync) + `deploy` (release) |
| `ToanlaTech/hermes-plugins` | private, git submodule at `./hermes-plugins`; custom plugin code only |

## Images (GHCR)

| Image | Built from | Purpose |
|---|---|---|
| `ghcr.io/toanlatech/hermes-agent` | `Dockerfile` (upstream) | main app; entrypoint `/init` (s6), cmd `gateway run` |
| `ghcr.io/toanlatech/hermes-plugins` | `deploy/plugins.Dockerfile` (busybox + submodule) | plugin code carrier for the initContainer |

Tags: `:<commit-sha>` (what actually runs — pinned, rollback-able) and
`:deploy` (moving, used only as the first-apply placeholder in manifests).

## Secrets

### GitHub Actions (repo `ToanlaTech/hermes-agent`)
| Secret | What | Notes |
|---|---|---|
| `KUBECONFIG_B64` | base64 of the f5s kubeconfig | used by `deploy` job for `kubectl` |
| `SUBMODULE_TOKEN` | PAT `hermes-submodule-ro`, scope `repo` | clones the private submodule; `GITHUB_TOKEN` can't cross private repos |

GHCR **push** uses the built-in `GITHUB_TOKEN` (`packages: write`), no secret.

### Cluster (namespace `hermes`)
| Secret | What |
|---|---|
| `ghcr-pull` | docker-registry imagePullSecret, PAT `hermes-ghcr-pull` (scope `read:packages`) |
| `hermes-secrets` | `OPENROUTER_API_KEY`, `API_SERVER_KEY` (+ optional bot tokens) — injected via `envFrom`; Hermes reads them from `os.getenv`, so no `.env` file needed |

Token separation: `hermes-submodule-ro` (repo) and `hermes-ghcr-pull`
(read:packages) are distinct, least-privilege PATs.

## Workflows

- **`build-deploy.yml`** — on push to `deploy` (or manual dispatch): checkout
  `--recursive` with `SUBMODULE_TOKEN` → build+push both images (`:sha`,
  `:deploy`) with GHA layer cache → `kubectl set image` statefulset + patch
  initContainer image → `rollout status`.
- **`sync-upstream.yml`** — weekly (Mon 06:00 UTC) / manual: merge
  `upstream/main` into a `sync/upstream` branch and open a PR into `main`
  (never auto-deploys; conflicts surface in the PR).

## As-deployed state (2026-07-15)

- Cluster: DOKS "f5s", 2 nodes, k8s v1.33, no GPU
- Namespace `hermes`; StatefulSet `hermes` 1/1 on node `f5s-prod-cluster03`
- PVC `hermes-data` 10Gi `do-block-storage` (Bound)
- Default model: `deepseek/deepseek-v4-flash` via OpenRouter
  (`model.default` in `/opt/data/config.yaml`)
- Backup: `hermes-backup` CronJob, DO CSI VolumeSnapshot nightly 03:00, keep 7
- Dashboard: https://hermes.operamind.one (form login, creds in `hermes-secrets`)
- Init containers (run in order): `config-seed` (busybox) → `plugin-sync`

## Dashboard exposure (hermes.operamind.one)

The web dashboard is served publicly with two independent protection layers:

- **App auth**: `HERMES_DASHBOARD=1` makes the gateway serve the dashboard on
  `0.0.0.0:9119`. Its form-login gate engages on any non-loopback bind and
  **fails closed** unless `HERMES_DASHBOARD_BASIC_AUTH_USERNAME/_PASSWORD` are
  set (stored in `hermes-secrets`).
- **TLS**: `ingress.yaml` routes `hermes.operamind.one` → `hermes:9119` via the
  shared `ingress-nginx` controller (LB IP `137.184.251.25`). cert-manager
  issues a Let's Encrypt cert through the existing cluster-wide
  `letsencrypt-prod` ClusterIssuer; HTTP is force-redirected to HTTPS.

DNS: an `A` record `hermes` → `137.184.251.25` at the registrar (Mắt Bão).
`NetworkPolicy` allows ingress only from the `ingress-nginx` namespace to 9119.

Change the dashboard password:
```bash
kubectl -n hermes patch secret hermes-secrets --type=merge \
  -p '{"stringData":{"HERMES_DASHBOARD_BASIC_AUTH_PASSWORD":"<new>"}}'
kubectl -n hermes rollout restart statefulset/hermes
```

## Config reproducibility (config-seed)

`config.yaml` lives on the PVC and is mutable (Hermes self-modifies it). It is
NOT a read-only ConfigMap mount — that would break Hermes. Instead the
`config-seed` initContainer copies a baseline `config.yaml` (from ConfigMap
`hermes-config-seed`: default model, `plugins.enabled`, MCP servers) onto the
PVC **only when absent**, so a PVC recreate restores the critical settings
without ever overwriting Hermes's live config.

## Everyday operations

```bash
export KUBECONFIG=~/WorkSpace/Certs/f5s-k8s-cluster-kubeconfig.yaml

# Ship code / plugins:
#   push to `deploy`  -> CI builds + rolls out automatically
# Update the plugin submodule pointer, then release:
git submodule update --remote hermes-plugins
git commit -am "bump plugins" && git push origin deploy

# Enable a new plugin (after it's synced onto the PVC):
kubectl -n hermes exec hermes-0 -c hermes -- hermes config set plugins.enabled '[hello_k8s, ...]'
kubectl -n hermes rollout restart statefulset/hermes

# Change default model:
kubectl -n hermes exec hermes-0 -c hermes -- hermes config set model.default <provider/model>
kubectl -n hermes rollout restart statefulset/hermes

# Rotate a secret value:
kubectl -n hermes patch secret hermes-secrets --type=merge \
  -p '{"stringData":{"OPENROUTER_API_KEY":"sk-or-v1-..."}}'
kubectl -n hermes rollout restart statefulset/hermes

# Rollback to an older image:
kubectl -n hermes set image statefulset/hermes hermes=ghcr.io/toanlatech/hermes-agent:<older-sha>

# Verify plugin delivery:
kubectl -n hermes logs hermes-0 -c plugin-sync
kubectl -n hermes exec hermes-0 -c hermes -- ls /opt/data/plugins
```

## Gotchas

- Manifests must NOT reference `host.docker.internal` (doesn't exist in-cluster);
  point MCP server URLs at k8s Service DNS instead.
- Liveness/startup probes scan `/proc` for the `gateway` process (no HTTP health
  endpoint assumed). If you enable the API server, switch to an `httpGet` probe.
- PAT expiry: classic PATs expire; when `SUBMODULE_TOKEN` or `ghcr-pull` stop
  working, regenerate and update the GitHub secret / cluster secret respectively.
- First-time only: `kubectl apply -k deploy/k8s` must run once to create the
  StatefulSet before CI's `kubectl set image` has something to update.
- Init-image updates go by NAME, not index: CI uses
  `kubectl set image ... plugin-sync=...` (not a JSON-path patch on
  `initContainers/0`) so adding/reordering initContainers (e.g. config-seed)
  can't misfire. `config-seed` uses a static `busybox` image CI never touches.
- **DO block-storage (RWO) attach desync**: triggering many StatefulSet
  rollouts in quick succession can leave the volume with `attached=true` in the
  VolumeAttachment while the block device is absent on the node — the pod hangs
  in `Init` with `mkfs.ext4 ... does not exist`. Fix: delete the stale
  VolumeAttachment for the PV so the attacher reattaches cleanly (blkid then
  finds the existing ext4 and mounts without formatting — data is safe). Avoid
  rapid back-to-back rollouts on the single RWO volume.
```
