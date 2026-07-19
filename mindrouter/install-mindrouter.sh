#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────────────────────────
# Optional MindRouter installation for the DGX Stack.
#
# Installs https://github.com/ui-insight/mindrouter locally on the DGX,
# registers this machine as a MindRouter NODE (with the GPU sidecar for
# telemetry), and registers both dgx-stack vLLM instances as BACKENDS:
#   - qwen  (chat LLM)   http://127.0.0.1:${VLLM_PORT}
#   - mocr  (OCR model)  http://127.0.0.1:${MOCR_PORT}
#
# MindRouter's stock dev compose uses host networking with the app on port
# 8000 and its MCP service on 8001 — both collide with the dgx-stack vLLM
# ports — so this installer writes a docker-compose.override.yml that moves
# them (default 8080/8081) and replaces the site-specific /archivedb bind
# mounts with local paths.
#
# Idempotent: safe to re-run. State that must survive re-runs:
#   ${MINDROUTER_DIR}/.env             (generated secrets)
#   ${MINDROUTER_DIR}/.admin_api_key   (admin API key — printed exactly once
#                                       by MindRouter's seed script)
#
# Usage:  ./mindrouter/install-mindrouter.sh
# Config via environment (defaults shown):
#   MINDROUTER_DIR=$HOME/mindrouter        install location (git clone)
#   MINDROUTER_REPO=https://github.com/ui-insight/mindrouter.git
#   MINDROUTER_PORT=8080                   gateway port
#   MINDROUTER_MCP_PORT=8081               MCP sidecar port
#   MINDROUTER_DATA=$HOME/mindrouter-data  artifact storage
#   MINDROUTER_NODE_NAME=$(hostname -s)    node name to register
#   DGX_STACK_DIR=<dir of this script>/..  where the dgx-stack .env lives
# ───────────────────────────────────────────────────────────────────────────

BOLD='\033[1m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; RED='\033[0;31m'; RESET='\033[0m'
info()  { echo -e "${GREEN}[MR]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[MR]${RESET}  $*"; }
error() { echo -e "${RED}[MR]${RESET}  $*"; }
die()   { error "$*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DGX_STACK_DIR="${DGX_STACK_DIR:-$(dirname "$SCRIPT_DIR")}"
MINDROUTER_DIR="${MINDROUTER_DIR:-$HOME/mindrouter}"
MINDROUTER_REPO="${MINDROUTER_REPO:-https://github.com/ui-insight/mindrouter.git}"
MINDROUTER_PORT="${MINDROUTER_PORT:-8080}"
MINDROUTER_MCP_PORT="${MINDROUTER_MCP_PORT:-8081}"
MINDROUTER_DATA="${MINDROUTER_DATA:-$HOME/mindrouter-data}"
MINDROUTER_NODE_NAME="${MINDROUTER_NODE_NAME:-$(hostname -s)}"
SIDECAR_PORT=8007

# Docker may require sudo depending on group membership.
DOCKER="docker"
if ! docker info &>/dev/null; then
    if sudo docker info &>/dev/null; then
        DOCKER="sudo docker"
    else
        die "Docker is not reachable (tried with and without sudo)."
    fi
fi

# ── Read the dgx-stack configuration for backend details ───────────────────
VLLM_PORT=8000; MOCR_PORT=8001
SERVED_MODEL_NAME="qwen3.6-35b"; MOCR_SERVED_MODEL_NAME="dots-mocr"
MAX_NUM_SEQS=12
if [[ -f "$DGX_STACK_DIR/.env" ]]; then
    # Same defensive parser as setup.sh: never `source` an env file.
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"; value="${line#*=}"
        if [[ "$value" =~ ^\"([^\"]*)\" ]]; then value="${BASH_REMATCH[1]}";
        elif [[ "$value" =~ ^\'([^\']*)\' ]]; then value="${BASH_REMATCH[1]}";
        else value="${value%%[[:space:]]#*}"; value="${value%"${value##*[![:space:]]}"}"; fi
        case "$key" in
            VLLM_PORT) VLLM_PORT="$value" ;;
            MOCR_PORT) MOCR_PORT="$value" ;;
            SERVED_MODEL_NAME) SERVED_MODEL_NAME="$value" ;;
            MOCR_SERVED_MODEL_NAME) MOCR_SERVED_MODEL_NAME="$value" ;;
            MAX_NUM_SEQS) MAX_NUM_SEQS="$value" ;;
        esac
    done < "$DGX_STACK_DIR/.env"
fi

api() {  # api METHOD PATH [JSON_BODY] — admin API helper
    local method="$1" path="$2" body="${3:-}"
    local key; key="$(cat "$MINDROUTER_DIR/.admin_api_key")"
    if [[ -n "$body" ]]; then
        curl -sf --max-time 30 -X "$method" "http://127.0.0.1:${MINDROUTER_PORT}${path}" \
            -H "Authorization: Bearer ${key}" -H "Content-Type: application/json" -d "$body"
    else
        curl -sf --max-time 30 -X "$method" "http://127.0.0.1:${MINDROUTER_PORT}${path}" \
            -H "Authorization: Bearer ${key}"
    fi
}

jsonq() {  # jsonq 'python expr over d' — parse JSON on stdin
    python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"
}

# ── Preflight ──────────────────────────────────────────────────────────────
info "Preflight checks"
command -v git >/dev/null || die "git is required"
command -v python3 >/dev/null || die "python3 is required"
command -v curl >/dev/null || die "curl is required"

curl -sf --max-time 5 "http://127.0.0.1:${VLLM_PORT}/health" >/dev/null \
    || die "dgx-stack LLM not healthy on :${VLLM_PORT} — deploy the stack first"
curl -sf --max-time 5 "http://127.0.0.1:${MOCR_PORT}/health" >/dev/null \
    || die "dgx-stack OCR model not healthy on :${MOCR_PORT} — deploy the stack first"

# Ports MindRouter's host-networked services will bind
for p in "$MINDROUTER_PORT" "$MINDROUTER_MCP_PORT" 3306 3307 6379 "$SIDECAR_PORT"; do
    if curl -sf --max-time 2 -o /dev/null "http://127.0.0.1:${p}/" 2>/dev/null \
       || (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null; then
        exec 3>&- 2>/dev/null || true
        # Port in use is fine on re-runs when it's MindRouter itself
        if [[ -d "$MINDROUTER_DIR/.git" ]]; then
            warn "port ${p} in use (expected on re-run)"
        else
            die "port ${p} is already in use — set MINDROUTER_PORT/MINDROUTER_MCP_PORT or free it"
        fi
    fi
done

# ── Clone / update ─────────────────────────────────────────────────────────
if [[ -d "$MINDROUTER_DIR/.git" ]]; then
    info "Updating existing checkout at $MINDROUTER_DIR"
    git -C "$MINDROUTER_DIR" pull --ff-only 2>/dev/null || warn "git pull skipped (local changes?)"
else
    info "Cloning MindRouter to $MINDROUTER_DIR"
    git clone "$MINDROUTER_REPO" "$MINDROUTER_DIR"
fi

mkdir -p "$MINDROUTER_DATA/artifacts"
# The app container writes artifacts as uid 1000 (appuser); the bind mount
# shadows the image's chown, so the host directory must be writable for it.
if ! sudo chown -R 1000:1000 "$MINDROUTER_DATA" 2>/dev/null; then
    chmod -R a+rwX "$MINDROUTER_DATA" 2>/dev/null \
        || warn "could not make $MINDROUTER_DATA writable for uid 1000 — artifact writes may fail"
fi

# ── Secrets / .env (generated once, preserved on re-run) ───────────────────
if [[ ! -f "$MINDROUTER_DIR/.env" ]]; then
    info "Generating secrets and .env"
    gen() { python3 -c "import secrets; print(secrets.token_hex($1))"; }
    cat > "$MINDROUTER_DIR/.env" <<EOF
# Generated by dgx-stack install-mindrouter.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
SECRET_KEY=$(gen 32)
MYSQL_ROOT_PASSWORD=$(gen 16)
MYSQL_PASSWORD=$(gen 16)
MYSQL_ARCHIVE_ROOT_PASSWORD=$(gen 16)
MYSQL_ARCHIVE_PASSWORD=$(gen 16)
SIDECAR_SECRET_KEY=$(gen 32)
APP_BASE_URL=http://$(hostname -f 2>/dev/null || hostname):${MINDROUTER_PORT}
MCP_SERVER_URL=http://127.0.0.1:${MINDROUTER_MCP_PORT}
LOG_LEVEL=INFO
EOF
    chmod 600 "$MINDROUTER_DIR/.env"
else
    info "Keeping existing .env — validating required keys"
    # A hand-written .env (MindRouter's documented dev flow) may lack keys
    # this installer depends on. Missing DB/crypto values cannot be safely
    # invented once the databases exist — fail loudly instead of silently.
    envget() { grep "^${1}=" "$MINDROUTER_DIR/.env" | head -1 | cut -d= -f2- || true; }
    for required in SECRET_KEY MYSQL_ROOT_PASSWORD MYSQL_PASSWORD; do
        [[ -n "$(envget "$required")" ]] \
            || die "existing $MINDROUTER_DIR/.env is missing ${required} — add it, or remove the .env (and MindRouter volumes) to let the installer regenerate everything"
    done
    # SIDECAR_SECRET_KEY is safe to fill in: the sidecar reads it at the
    # compose up that follows, and node registration sends the same value.
    if [[ -z "$(envget SIDECAR_SECRET_KEY)" ]]; then
        info "Adding generated SIDECAR_SECRET_KEY to existing .env"
        sed -i '/^SIDECAR_SECRET_KEY=/d' "$MINDROUTER_DIR/.env"
        echo "SIDECAR_SECRET_KEY=$(python3 -c 'import secrets; print(secrets.token_hex(32))')" >> "$MINDROUTER_DIR/.env"
    fi
    # Without this, compose's default MCP_SERVER_URL points at 127.0.0.1:8001
    # — which on this machine is the dgx-stack OCR vLLM instance.
    if [[ -z "$(envget MCP_SERVER_URL)" ]]; then
        info "Adding MCP_SERVER_URL=http://127.0.0.1:${MINDROUTER_MCP_PORT} to existing .env"
        sed -i '/^MCP_SERVER_URL=/d' "$MINDROUTER_DIR/.env"
        echo "MCP_SERVER_URL=http://127.0.0.1:${MINDROUTER_MCP_PORT}" >> "$MINDROUTER_DIR/.env"
    fi
fi
# Read generated values we need later
SIDECAR_SECRET_KEY="$(grep '^SIDECAR_SECRET_KEY=' "$MINDROUTER_DIR/.env" | head -1 | cut -d= -f2-)"
MYSQL_ROOT_PASSWORD="$(grep '^MYSQL_ROOT_PASSWORD=' "$MINDROUTER_DIR/.env" | head -1 | cut -d= -f2-)"

# ── Compose override: ports + local storage paths ──────────────────────────
info "Writing docker-compose.override.yml (app :${MINDROUTER_PORT}, mcp :${MINDROUTER_MCP_PORT})"
cat > "$MINDROUTER_DIR/docker-compose.override.yml" <<EOF
# Generated by dgx-stack install-mindrouter.sh — do not edit by hand.
# Moves MindRouter off ports 8000/8001 (used by the dgx-stack vLLM
# instances) and replaces site-specific /archivedb bind mounts.
services:
  app:
    command: ["uvicorn", "backend.app.main:app", "--host", "0.0.0.0", "--port", "${MINDROUTER_PORT}", "--workers", "2", "--timeout-graceful-shutdown", "60"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${MINDROUTER_PORT}/healthz"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
    volumes:
      - ${MINDROUTER_DATA}/artifacts:/data/artifacts
  mcp:
    command: ["uvicorn", "backend.app.mcp_entrypoint:app", "--host", "0.0.0.0", "--port", "${MINDROUTER_MCP_PORT}", "--workers", "1", "--timeout-graceful-shutdown", "30"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${MINDROUTER_MCP_PORT}/healthz"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 10s
  mariadb-archive:
    volumes:
      - mariadb_archive_data:/var/lib/mysql
EOF

# ── Build ──────────────────────────────────────────────────────────────────
info "Building MindRouter images (first build on the Grace CPU can take a while)..."
(cd "$MINDROUTER_DIR" && $DOCKER compose --profile gpu build) \
    || die "docker compose build failed"

# ── Databases first, then migrations BEFORE the app starts ─────────────────
# The app crash-loops on a schema-less database, and `compose exec`
# needs a running container — so migrations/seeding run in one-shot
# `compose run` containers against the databases alone.
info "Starting databases (mariadb, mariadb-archive, redis)..."
(cd "$MINDROUTER_DIR" && $DOCKER compose up -d --wait mariadb mariadb-archive redis) \
    || die "database startup failed"

info "Running database migrations"
(cd "$MINDROUTER_DIR" && $DOCKER compose run --rm --no-deps app alembic upgrade head) \
    || die "alembic upgrade head failed"

if [[ -f "$MINDROUTER_DIR/.admin_api_key" ]]; then
    info "Reusing saved admin API key"
else
    info "Seeding admin user and capturing the admin API key"
    seed_out="$(cd "$MINDROUTER_DIR" && $DOCKER compose run --rm --no-deps app python scripts/seed_dev_data.py 2>&1 || true)"
    # The seed output prints the key PREFIX on one line and the full key on
    # the "FULL KEY (save this!)" line — anchor on the latter.
    admin_key="$(printf '%s\n' "$seed_out" | grep 'FULL KEY' | grep -o 'mr2_[A-Za-z0-9_-]*' | head -1 || true)"
    if [[ -z "$admin_key" ]]; then
        printf '%s\n' "$seed_out" | tail -5
        die "Could not capture the admin API key. If the admin user already exists from a previous partial install, the key cannot be re-printed — remove the MindRouter volumes and re-run, or mint a key manually."
    fi
    printf '%s' "$admin_key" > "$MINDROUTER_DIR/.admin_api_key"
    chmod 600 "$MINDROUTER_DIR/.admin_api_key"
    info "Admin API key saved to $MINDROUTER_DIR/.admin_api_key (chmod 600)"
fi

# ── Start the full stack ───────────────────────────────────────────────────
info "Starting MindRouter services (app, mcp, gpu-sidecar)..."
(cd "$MINDROUTER_DIR" && $DOCKER compose --profile gpu up -d) \
    || die "docker compose up failed"

info "Waiting for the gateway on :${MINDROUTER_PORT} ..."
for i in $(seq 1 60); do
    curl -sf --max-time 3 "http://127.0.0.1:${MINDROUTER_PORT}/healthz" >/dev/null && break
    [[ "$i" == 60 ]] && die "MindRouter app did not become healthy — check: $DOCKER compose -f $MINDROUTER_DIR/docker-compose.yml logs app"
    sleep 5
done
info "Gateway is up."

# Fail fast if the saved admin key does not actually authenticate —
# a partial earlier install can leave a stale or truncated key file.
if ! api GET /api/admin/nodes >/dev/null 2>&1; then
    die "Saved admin API key does not authenticate against /api/admin. Remove $MINDROUTER_DIR/.admin_api_key and the MindRouter volumes ($DOCKER compose --profile gpu down -v in $MINDROUTER_DIR), then re-run."
fi

# ── Register the DGX as a node ─────────────────────────────────────────────
info "Registering node '${MINDROUTER_NODE_NAME}'"
# List first so re-runs are idempotent. A failed LIST must be fatal —
# treating it as "not registered" would turn a transient error into a
# duplicate-registration 409 on the next line.
nodes_json="$(api GET /api/admin/nodes)" || die "could not list nodes — is the gateway healthy and the admin key valid?"
node_id="$(printf '%s' "$nodes_json" | jsonq "next((n['id'] for n in (d if isinstance(d, list) else d.get('nodes', d.get('items', []))) if n.get('name')=='${MINDROUTER_NODE_NAME}'), '')")" \
    || die "could not parse node list response"
if [[ -n "$node_id" ]]; then
    info "Node already registered (id=${node_id})"
else
    node_id="$(api POST /api/admin/nodes/register "{
        \"name\": \"${MINDROUTER_NODE_NAME}\",
        \"hostname\": \"$(hostname -f 2>/dev/null || hostname)\",
        \"sidecar_url\": \"http://127.0.0.1:${SIDECAR_PORT}\",
        \"sidecar_key\": \"${SIDECAR_SECRET_KEY}\"
    }" | jsonq "d['id']")" || die "node registration failed"
    info "Node registered (id=${node_id})"
fi

# ── Register both vLLM instances as backends ───────────────────────────────
register_backend() {  # name url max_concurrent
    local name="$1" url="$2" maxc="$3"
    local backends_json existing
    backends_json="$(api GET /api/admin/backends)" || die "could not list backends — is the gateway healthy and the admin key valid?"
    existing="$(printf '%s' "$backends_json" | jsonq "next((b['id'] for b in (d if isinstance(d, list) else d.get('backends', d.get('items', []))) if b.get('name')=='${name}' or b.get('url')=='${url}'), '')")" \
        || die "could not parse backend list response"
    if [[ -n "$existing" ]]; then
        info "Backend '${name}' already registered (id=${existing})"
        return 0
    fi
    api POST /api/admin/backends/register "{
        \"name\": \"${name}\",
        \"url\": \"${url}\",
        \"engine\": \"vllm\",
        \"max_concurrent\": ${maxc},
        \"node_id\": ${node_id}
    }" >/dev/null || die "backend registration failed for ${name}"
    info "Backend '${name}' registered (${url}, max_concurrent=${maxc})"
}

register_backend "dgx-qwen" "http://127.0.0.1:${VLLM_PORT}" "${MAX_NUM_SEQS}"
# The dgx-stack OCR service also talks to mocr directly; MindRouter's
# admission control cannot see that traffic, so leave it headroom.
register_backend "dgx-mocr" "http://127.0.0.1:${MOCR_PORT}" "4"

# ── Wait for model discovery ───────────────────────────────────────────────
info "Waiting for model discovery (${SERVED_MODEL_NAME}, ${MOCR_SERVED_MODEL_NAME})..."
for i in $(seq 1 30); do
    models="$(api GET /v1/models | jsonq "','.join(m['id'] for m in d.get('data', []))" || echo "")"
    if [[ "$models" == *"${SERVED_MODEL_NAME}"* ]] && [[ "$models" == *"${MOCR_SERVED_MODEL_NAME}"* ]]; then
        info "Models discovered: ${models}"
        break
    fi
    [[ "$i" == 30 ]] && die "models not discovered after 150s (have: ${models:-none})"
    sleep 5
done

# ── Post-registration fixups (no REST endpoints exist for these yet) ───────
# 1. Both models are multimodal, but MindRouter's vLLM name heuristics
#    don't match "qwen3.6-*" or "dots-mocr" — set the admin override.
# 2. Point MindRouter's own /v1/ocr[md] endpoints at dots-mocr.
info "Applying multimodal overrides and OCR default model"
(cd "$MINDROUTER_DIR" && $DOCKER compose exec -T mariadb \
    mariadb -u root -p"${MYSQL_ROOT_PASSWORD}" mindrouter -e "
UPDATE models SET multimodal_override=1, supports_multimodal=1
 WHERE name IN ('${SERVED_MODEL_NAME}', '${MOCR_SERVED_MODEL_NAME}');
INSERT INTO app_config (\`key\`, value, description, created_at, updated_at)
 VALUES ('ocr.default_model', '\"${MOCR_SERVED_MODEL_NAME}\"', 'set by dgx-stack installer', NOW(), NOW())
 ON DUPLICATE KEY UPDATE value='\"${MOCR_SERVED_MODEL_NAME}\"', updated_at=NOW();
-- dots.mocr is a single-page model and the dgx-stack vLLM instance
-- enforces --limit-mm-per-prompt image=1, so MindRouter's OCR chunker
-- must send exactly one page image per request.
INSERT INTO app_config (\`key\`, value, description, created_at, updated_at)
 VALUES ('ocr.chunk_size', '1', 'set by dgx-stack installer', NOW(), NOW())
 ON DUPLICATE KEY UPDATE value='1', updated_at=NOW();
INSERT INTO app_config (\`key\`, value, description, created_at, updated_at)
 VALUES ('ocr.overlap', '0', 'set by dgx-stack installer', NOW(), NOW())
 ON DUPLICATE KEY UPDATE value='0', updated_at=NOW();
") || die "database fixups failed"

# ── Smoke tests through the gateway ────────────────────────────────────────
info "Smoke test 1/3: routed chat completion (${SERVED_MODEL_NAME})"
chat="$(api POST /v1/chat/completions "{
    \"model\": \"${SERVED_MODEL_NAME}\",
    \"messages\": [{\"role\": \"user\", \"content\": \"What is 6*7? Reply with only the number.\"}],
    \"max_tokens\": 512
}" | jsonq "d['choices'][0]['message'].get('content') or ''" || echo "")"
if [[ "$chat" == *"42"* ]]; then info "  chat OK: ${chat:0:40}"; else warn "  chat unexpected: ${chat:0:80}"; fi

info "Smoke test 2/3: routed OCR (${MOCR_SERVED_MODEL_NAME} via /v1/ocrmd)"
test_pdf="$DGX_STACK_DIR/examples/test-doc.pdf"
if [[ -f "$test_pdf" ]]; then
    key="$(cat "$MINDROUTER_DIR/.admin_api_key")"
    ocr_out="$(curl -sf --max-time 600 -X POST "http://127.0.0.1:${MINDROUTER_PORT}/v1/ocrmd" \
        -H "Authorization: Bearer ${key}" -F "file=@${test_pdf}" || echo "")"
    if [[ "$ocr_out" == *"END-OF-TEST-DOCUMENT"* ]]; then
        info "  OCR OK ($(printf '%s' "$ocr_out" | wc -c | tr -d ' ') chars, sentinel found)"
    else
        warn "  OCR output missing sentinel ($(printf '%s' "$ocr_out" | wc -c | tr -d ' ') chars)"
    fi
else
    warn "  test PDF not found at ${test_pdf} — skipped"
fi

info "Smoke test 3/3: /v1/models capability listing"
api GET /v1/models | jsonq "chr(10).join(f\"  {m['id']}: multimodal={m.get('capabilities',{}).get('multimodal')}, tools={m.get('capabilities',{}).get('tools')}\" for m in d.get('data',[]))" || true

# ── Summary ────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}MindRouter installed.${RESET}"
echo ""
echo "  Gateway (OpenAI-compatible):  http://$(hostname -f 2>/dev/null || hostname):${MINDROUTER_PORT}/v1"
echo "  Dashboard:                    http://$(hostname -f 2>/dev/null || hostname):${MINDROUTER_PORT}/dashboard"
echo "  Node:                         ${MINDROUTER_NODE_NAME} (GPU sidecar on :${SIDECAR_PORT})"
echo "  Backends:                     dgx-qwen -> :${VLLM_PORT} (${SERVED_MODEL_NAME})"
echo "                                dgx-mocr -> :${MOCR_PORT} (${MOCR_SERVED_MODEL_NAME})"
echo "  Admin API key:                ${MINDROUTER_DIR}/.admin_api_key"
echo ""
echo -e "  ${YELLOW}SECURITY: the seeded dashboard login is admin/admin123 —${RESET}"
echo -e "  ${YELLOW}change it immediately at /dashboard (Settings -> Change Password).${RESET}"
echo ""
