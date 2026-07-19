# Optional MindRouter Installation

[MindRouter](https://github.com/ui-insight/mindrouter) is an LLM gateway and
load balancer: an OpenAI-compatible API surface with per-user API keys,
quotas, fair-share scheduling, health monitoring, dashboards, and full audit
logging. This directory installs it **locally on the DGX**, registering the
machine as a MindRouter **node** (with the GPU telemetry sidecar) and both
dgx-stack vLLM instances as **backends**.

After installation, clients can use `http://<dgx>:8080/v1` with MindRouter
API keys instead of hitting vLLM directly — with quotas, fairness, and audit
logging applied. The direct ports (8000 LLM, 8001 OCR model, 8010 OCR
service) keep working unchanged.

## Installing

The dgx-stack must be deployed and healthy first.

```bash
./setup.sh                        # → option 8, or answer yes when offered
# or standalone:
./mindrouter/install-mindrouter.sh
```

(The setup.sh offer appears after every successful deploy — Fresh Install,
Re-Install, or Repair/Reconfigure.)

Host prerequisites: `git`, `python3`, and `curl` (the installer preflights
these). It needs no interactive input, though it may prompt for a **sudo
password** once (docker access and making the artifact directory writable
for the container user). It:

1. Clones MindRouter to `~/mindrouter` (or updates an existing checkout)
2. Generates all secrets into `~/mindrouter/.env` (preserved across re-runs)
3. Writes a `docker-compose.override.yml` that moves MindRouter off the
   colliding defaults — gateway on **8080**, its MCP service on **8081**
   (8000/8001 belong to the vLLM instances) — and replaces its
   site-specific `/archivedb` bind mounts with local paths
4. Builds the images from source (**the first build takes a while** on the
   Grace CPU — the app image includes LibreOffice and PyTorch; subsequent
   runs use the build cache)
5. Starts the databases, runs migrations, seeds the admin account, and
   captures the one-time admin API key to `~/mindrouter/.admin_api_key`
   (mode 600)
6. Starts the gateway, MCP service, and GPU sidecar
7. Registers the node and both backends, waits for model discovery
8. Applies configuration MindRouter has no API for yet (direct SQL):
   marks both models multimodal (their names don't match MindRouter's
   vision-name heuristics), points MindRouter's own `/v1/ocr` +
   `/v1/ocrmd` endpoints at dots-mocr, and sets OCR chunking to
   **one page per request** (dots.mocr is a single-page model and the
   vLLM instance enforces `--limit-mm-per-prompt image=1`)
9. Smoke-tests a routed chat completion and a routed OCR request

## Installer configuration

Set via environment before running (defaults shown):

| Variable | Default | Purpose |
|----------|---------|---------|
| `MINDROUTER_DIR` | `~/mindrouter` | Install location (git clone) |
| `MINDROUTER_REPO` | `https://github.com/ui-insight/mindrouter.git` | Source repo |
| `MINDROUTER_PORT` | 8080 | Gateway port |
| `MINDROUTER_MCP_PORT` | 8081 | MCP service port |
| `MINDROUTER_DATA` | `~/mindrouter-data` | Artifact storage (owned by uid 1000) |
| `MINDROUTER_NODE_NAME` | `hostname -s` | Node name to register |

Host ports used (all on the host network, per MindRouter's compose):
**8080** gateway, **8081** MCP, **8007** GPU sidecar, **3306**/**3307**
MariaDB main/archive, **6379** Redis. The installer preflights that these
are free.

**Security note:** because MindRouter's compose uses host networking,
the databases (3306/3307), Redis (6379), and the GPU sidecar (8007)
listen on all host interfaces — not just localhost. On a network-exposed
DGX, firewall those ports (e.g. `ufw`) so only the gateway (8080) and,
if desired, the direct vLLM/OCR ports are reachable from clients.

The backend registrations mirror the dgx-stack `.env`: `dgx-qwen` gets
`max_concurrent` = `MAX_NUM_SEQS` (12), `dgx-mocr` is capped at 4 —
deliberately below the OCR instance's capacity because the dgx-stack OCR
service also talks to it directly and MindRouter's admission control cannot
see that traffic.

## After installation

- **Gateway**: `http://<dgx>:8080/v1` (OpenAI-compatible; also Ollama
  `/api/*` and Anthropic `/anthropic/v1/*` dialects)
- **Dashboard**: `http://<dgx>:8080/dashboard`
- **⚠ Change the seeded dashboard password immediately** — the seed creates
  `admin` / `admin123`; the Change Password card is on the `/dashboard`
  user page itself
- **Admin API key**: `~/mindrouter/.admin_api_key`. This is the only copy —
  MindRouter prints it exactly once at seed time. Guard the file.

Quick test:

```bash
KEY=$(cat ~/mindrouter/.admin_api_key)
curl -s http://localhost:8080/v1/chat/completions \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model": "qwen3.6-35b", "messages": [{"role": "user", "content": "Hello"}], "max_tokens": 64}'
```

Create end users and their API keys via the admin API (or the dashboard):

```bash
# groups: GET /api/admin/groups → pick a group_id. On a fresh install:
# 1=students, 2=staff, 3=faculty (1M tokens/120 rpm), 4=researchers, 5=admin
curl -s -X POST http://localhost:8080/api/admin/users \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"username": "alice", "email": "alice@example.edu", "password": "changeme123", "group_id": 3}'
curl -s -X POST http://localhost:8080/api/admin/users/<user_id>/api-keys \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"name": "alice-key"}'      # response contains full_key — shown once
```

## Operations

```bash
cd ~/mindrouter
sudo docker compose --profile gpu ps            # status
sudo docker compose logs -f app                 # gateway logs
sudo docker compose --profile gpu restart       # restart
sudo docker compose --profile gpu down          # stop (data preserved)
sudo docker compose --profile gpu up -d         # start again
```

MindRouter polls both backends' `/health` every 30s; backends the dgx-stack
restarts (e.g. via `./setup.sh` → Re-Install) are picked back up
automatically once healthy — no re-registration needed.

## Re-running and recovery

Re-running the installer is always safe: existing secrets, key, node, and
backends are detected and kept. Two recovery scenarios:

- **Admin key file lost** (but MindRouter still installed): the key cannot
  be re-printed. Reset and reinstall:
  `cd ~/mindrouter && sudo docker compose --profile gpu down -v && rm -f .admin_api_key`
  then re-run the installer (model/DB data in MindRouter is discarded;
  the dgx-stack itself is untouched).
- **Hand-written `.env` from a previous manual MindRouter install**: the
  installer validates it and fails with a clear message if required keys
  (`SECRET_KEY`, `MYSQL_ROOT_PASSWORD`, `MYSQL_PASSWORD`) are missing.

## Uninstalling

```bash
cd ~/mindrouter && sudo docker compose --profile gpu down -v   # containers + data
rm -rf ~/mindrouter ~/mindrouter-data                          # code + artifacts
```

The dgx-stack is unaffected.
