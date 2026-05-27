# swecc-infra

Production Swarm configs, env secrets sync, and the **api.swecc.org** TLS gateway (`prod_nginx`).

## What runs where

| Concern | Repo | Deploy |
|--------|------|--------|
| App images (server, bench-api, …) | [swecc-core](https://github.com/swecc-uw/swecc-core) | `deploy-*.yml` on push to `main` |
| Docker configs (`server_env`, …) | **this repo** | `Sync Docker Configs` (schedule + push to `main`) |
| TLS + routing `api.swecc.org` | **this repo** | `Deploy Gateway` / `Deploy Nginx` |

The live gateway is **`prod_nginx`** (stack `prod`, `nginx.conf` in this repo). It must stay on overlay **`prod_swecc-network`** with upstreams **`server:8000`**, **`bench-api:8000`**, **`sockets:8004`** (Swarm service names — not `swecc_stack_*`, which are optional aliases and break `nginx -t` when missing).

Reference SWAG snippets live in swecc-core [`infra/gateway/`](https://github.com/swecc-uw/swecc-core/tree/main/infra/gateway); mirror route changes into **both** repos’ nginx configs.

## Migrations vs API outages

**Bench schema migrations run in the `server` image** (`manage.py migrate` in swecc-core `s/ops/deploy.sh`). **Always deploy `server` before `bench-api`** (swecc-core `deploy-bench-api.yml` already does this).

- **swecc-core only** for app deploys: push to `main` on the relevant path, or run **Deploy Bench API** / **Deploy Server** manually.
- **swecc-infra only** when changing `nginx.conf`, `stack.yml`, or env configs — not for every migration.

If `api.swecc.org` is unreachable (connection refused on :443), run **Deploy Gateway** (`workflow_dispatch`) — do not redeploy bench-api until the gateway shows `1/1` and public `:443` checks pass in the job log.

## Workflows

- **Deploy Gateway** — stack deploy, publish :80/:443, sync `nginx.conf`, roll `prod_nginx`, verify loopback + EC2 public IP.
- **Deploy Nginx** — same script as gateway (config-only path).
- **Sync Docker Configs** — refresh Swarm configs; may trigger swecc-core / other service deploys when env changes.
