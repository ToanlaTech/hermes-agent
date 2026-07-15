# Deploying Hermes Agent to Kubernetes

Production-grade, singleton deployment of Hermes on a DigitalOcean (DOKS)
cluster, with custom plugins delivered via a git submodule + GHCR + an
initContainer sync.

## Architecture

```
NousResearch/hermes-agent (upstream) --weekly PR--> ToanlaTech/hermes-agent
                                                         |-- main   (tracks upstream)
                                                         `-- deploy (triggers CI)
ToanlaTech/hermes-plugins (submodule) --------------------^
                                                         |
   GitHub Actions: build 2 images --push--> GHCR (:<sha>)
                                                         |
                            kubectl set image (KUBECONFIG_B64 secret)
                                                         v
   k8s/hermes namespace:
     StatefulSet hermes (1 replica, single SQLite writer)
       initContainer plugin-sync: cp plugins image -> PVC /opt/data/plugins
       container hermes: /init (s6) -> gateway run, envFrom Secret+ConfigMap
     PVC hermes-data (do-block-storage, RWO)  <- nightly VolumeSnapshot backup
     NetworkPolicy: deny ingress, egress 443 + DNS only
```

Why singleton / StatefulSet / not HPA: all agent state (sessions, memory,
skills, cron) is an embedded single-writer SQLite DB under `/opt/data`. Two
replicas would corrupt it. Scale = bigger node, not more pods.

## One-time setup

### 1. Fork + remotes
```bash
gh repo fork NousResearch/hermes-agent --org ToanlaTech --remote=false
git remote rename origin upstream
git remote add origin https://github.com/ToanlaTech/hermes-agent.git
git push -u origin main
git push -u origin deploy
```

### 2. Create the plugins repo + wire the submodule
```bash
# push the scaffold created at ../hermes-plugins
cd ../hermes-plugins && git init && git add -A \
  && git commit -m "init: hello_k8s scaffold plugin" \
  && gh repo create ToanlaTech/hermes-plugins --private --source=. --push
cd -                                   # back to hermes-agent
git checkout deploy
git submodule add https://github.com/ToanlaTech/hermes-plugins.git hermes-plugins
git commit -am "chore: add hermes-plugins submodule"
```

### 3. GitHub Actions secrets (repo ToanlaTech/hermes-agent)
- `KUBECONFIG_B64` — `base64 -w0 ~/WorkSpace/Certs/f5s-k8s-cluster-kubeconfig.yaml`
  (paste the output). GHCR push uses the built-in `GITHUB_TOKEN`, no secret needed.

### 4. Cluster prerequisites (run once with the f5s kubeconfig)
```bash
export KUBECONFIG=~/WorkSpace/Certs/f5s-k8s-cluster-kubeconfig.yaml

kubectl apply -f deploy/k8s/namespace.yaml

# GHCR pull secret (packages are private by default). Use a GitHub PAT with
# read:packages scope.
kubectl -n hermes create secret docker-registry ghcr-pull \
  --docker-server=ghcr.io \
  --docker-username=ToanlaTech \
  --docker-password=<GHCR_PAT_read_packages>

# Hermes app secrets (NOT in git). See secret.example.yaml.
kubectl -n hermes create secret generic hermes-secrets \
  --from-literal=OPENROUTER_API_KEY=sk-or-v1-xxxx \
  --from-literal=API_SERVER_KEY=$(openssl rand -hex 32)
```

### 5. First apply
```bash
kubectl apply -k deploy/k8s      # everything except the two secrets above
kubectl -n hermes rollout status statefulset/hermes
```

## Config that MUST change vs. the local/Docker setup

- **MCP server URLs**: anything pointing at `host.docker.internal` does not
  exist in-cluster. Point it at a k8s Service DNS name instead. Edit
  `config.yaml` on the PVC (`kubectl -n hermes exec -it hermes-0 -- \
  sh -c 'vi /opt/data/config.yaml'`) or seed it via bootstrap.
- **Secrets**: keep `/opt/data/.env` free of API keys — they come from the
  `hermes-secrets` env injection. Do not run `hermes config set <KEY>` in-pod.

## Everyday workflow

- **Ship code**: merge `main -> deploy` (or push to `deploy`) -> CI builds +
  rolls out automatically.
- **Ship a plugin**: commit in `hermes-plugins`, then in `hermes-agent`
  `git submodule update --remote hermes-plugins && git commit -am "bump plugins"`
  and push `deploy`.
- **Enable a new plugin**: add its name to `plugins.enabled` in the PVC
  `config.yaml`, then `kubectl -n hermes rollout restart statefulset/hermes`.
- **Rollback**: `kubectl -n hermes set image statefulset/hermes \
  hermes=ghcr.io/toanlatech/hermes-agent:<older-sha>`.
- **Upstream updates**: the weekly `sync-upstream` workflow opens a PR into
  `main`; review, merge, then release via `main -> deploy`.

## Verify plugin delivery

```bash
kubectl -n hermes logs hermes-0 -c plugin-sync            # "synced N plugin dir(s)"
kubectl -n hermes exec hermes-0 -- ls /opt/data/plugins   # hello_k8s present
```

## Caveats

- The liveness/startup probes scan `/proc` for the `gateway` process (no
  HTTP health endpoint assumed). If you enable the API server, switch to an
  `httpGet` probe on `API_SERVER_PORT`.
- Backups use DO CSI `VolumeSnapshot`. DOKS ships the snapshot CRDs +
  controller; if `kubectl get volumesnapshotclass` is empty, install the
  external-snapshotter first.
- CI builds both images on every `deploy` push. Layer caching keeps the
  unchanged Hermes image fast; optimize with path filters later if desired.
```
