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
# MindRouter's stock dev compose uses host networking and binds a fixed set
# of ports (app 8000, MCP 8001, MariaDB 3306/3307, Redis 6379, sidecar 8007)
# — several of which collide with the dgx-stack vLLM ports or with a sibling
# app like Vandalizer. This installer therefore AUTO-SELECTS free ports for
# every host-bound MindRouter service and writes a docker-compose.override.yml
# that moves them there (rewriting the app's DB/Redis/MCP connection URLs to
# match), and replaces the site-specific /archivedb bind mounts with local
# paths. Chosen ports are pinned in ${MINDROUTER_DIR}/.dgx-ports so re-runs
# stay stable (moving MariaDB's port after data exists would orphan nothing —
# the volume is by name — but stable ports avoid surprises).
#
# Idempotent: safe to re-run. State that must survive re-runs:
#   ${MINDROUTER_DIR}/.env             (generated secrets)
#   ${MINDROUTER_DIR}/.admin_api_key   (admin API key — printed exactly once
#                                       by MindRouter's seed script)
#   ${MINDROUTER_DIR}/.dgx-ports       (selected ports)
#
# Usage:  ./mindrouter/install-mindrouter.sh
# Config via environment (all optional; unset ports are auto-selected):
#   MINDROUTER_DIR=$HOME/mindrouter        install location (git clone)
#   MINDROUTER_REPO=https://github.com/ui-insight/mindrouter.git
#   MINDROUTER_PORT=<auto>                 gateway port (preferred 8080)
#   MINDROUTER_MCP_PORT=<auto>             MCP service port (preferred 8081)
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
MINDROUTER_DATA="${MINDROUTER_DATA:-$HOME/mindrouter-data}"
MINDROUTER_NODE_NAME="${MINDROUTER_NODE_NAME:-$(hostname -s)}"
# Ports: an explicit env value is honored; anything left blank is
# auto-selected (see the port-selection block after the clone).
MINDROUTER_PORT="${MINDROUTER_PORT:-}"
MINDROUTER_MCP_PORT="${MINDROUTER_MCP_PORT:-}"

# ── Port helpers ───────────────────────────────────────────────────────────
port_free() {  # exit 0 if nothing is LISTENing on TCP port $1
    local p="$1"
    if command -v ss >/dev/null 2>&1; then
        ! ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${p}\$"
    else
        ! (exec 3<>"/dev/tcp/127.0.0.1/${p}") 2>/dev/null
    fi
}
pick_port() {  # pick_port PREFERRED EXCLUDE... -> first free port near PREFERRED
    local pref="$1"; shift; local excl=" $* " cand
    for cand in "$pref" $(seq $((pref + 10)) $((pref + 60))); do
        [[ "$excl" == *" $cand "* ]] && continue
        if port_free "$cand"; then echo "$cand"; return 0; fi
    done
    return 1
}

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

# ── Clone / update ─────────────────────────────────────────────────────────
if [[ -d "$MINDROUTER_DIR/.git" ]]; then
    info "Updating existing checkout at $MINDROUTER_DIR"
    git -C "$MINDROUTER_DIR" pull --ff-only 2>/dev/null || warn "git pull skipped (local changes?)"
else
    info "Cloning MindRouter to $MINDROUTER_DIR"
    git clone "$MINDROUTER_REPO" "$MINDROUTER_DIR"
fi

# Vendor the dashboard's CDN assets locally so the UI works air-gapped. This
# needs internet (like the model download) and runs once; it's best-effort —
# a failure just leaves the dashboard using the CDN when online, so it must
# not abort the install.
info "Vendoring MindRouter dashboard assets for offline use"
bash "$SCRIPT_DIR/vendor-assets.sh" "$MINDROUTER_DIR" \
    || warn "asset vendoring skipped/failed — dashboard will use the CDN when online"

# ── Port selection ─────────────────────────────────────────────────────────
# MindRouter binds six host ports. Pin the choices in .dgx-ports so re-runs
# reuse them; auto-select free ports on first install. An explicit env value
# always wins (and is validated free). Preferred values match MindRouter's
# conventions where they don't clash with the dgx-stack (8000/8001 do, so the
# gateway/MCP default to 8080/8081).
PORT_STATE="$MINDROUTER_DIR/.dgx-ports"
declare -A PREF=( [MR_GATEWAY]=8080 [MR_MCP]=8081 [MR_MARIADB]=3306
                  [MR_ARCHIVE]=3307 [MR_REDIS]=6379 [MR_SIDECAR]=8007 )

# Migration: an install from before .dgx-ports existed encoded the gateway/MCP
# ports in its override and left the infra ports at MindRouter's defaults.
# Reconstruct the pins so a re-run adopts the running instance instead of
# moving it onto fresh ports.
OVERRIDE="$MINDROUTER_DIR/docker-compose.override.yml"
if [[ ! -f "$PORT_STATE" && -f "$OVERRIDE" ]]; then
    mapfile -t _oldports < <(grep -oE '"--port", "[0-9]+"' "$OVERRIDE" | grep -oE '[0-9]+')
    if [[ ${#_oldports[@]} -ge 2 ]]; then
        info "Migrating a pre-existing install to pinned ports (adopting current ports)"
        { echo "# migrated from a pre-.dgx-ports install"
          echo "MR_GATEWAY=${_oldports[0]}"; echo "MR_MCP=${_oldports[1]}"
          echo "MR_MARIADB=3306"; echo "MR_ARCHIVE=3307"
          echo "MR_REDIS=6379";   echo "MR_SIDECAR=8007"
        } > "$PORT_STATE"
    fi
fi

# Load pinned ports from a prior install (KEY=VALUE, safe to grep-parse).
declare -A PORT=()
if [[ -f "$PORT_STATE" ]]; then
    while IFS='=' read -r k v; do [[ "$k" == MR_* ]] && PORT[$k]="$v"; done < "$PORT_STATE"
    info "Reusing pinned ports from $PORT_STATE"
fi
# Explicit env overrides take precedence over pinned/auto for the two public ports.
[[ -n "$MINDROUTER_PORT" ]] && PORT[MR_GATEWAY]="$MINDROUTER_PORT"
[[ -n "$MINDROUTER_MCP_PORT" ]] && PORT[MR_MCP]="$MINDROUTER_MCP_PORT"

chosen=""
for key in MR_GATEWAY MR_MCP MR_MARIADB MR_ARCHIVE MR_REDIS MR_SIDECAR; do
    if [[ -n "${PORT[$key]:-}" ]]; then
        # Already decided (pinned or explicit). Validate it is usable: free,
        # or already held by our own running MindRouter (re-run case).
        if ! port_free "${PORT[$key]}" \
           && ! $DOCKER ps --filter name=mindrouter --format '{{.Names}}' 2>/dev/null | grep -q .; then
            die "requested port ${PORT[$key]} for ${key#MR_} is in use by another process — free it or set a different value"
        fi
    else
        PORT[$key]="$(pick_port "${PREF[$key]}" $chosen)" \
            || die "could not find a free port near ${PREF[$key]} for ${key#MR_}"
    fi
    chosen="$chosen ${PORT[$key]}"
done

# Persist the decisions.
{ echo "# MindRouter host ports — pinned by install-mindrouter.sh; do not reorder"
  for key in MR_GATEWAY MR_MCP MR_MARIADB MR_ARCHIVE MR_REDIS MR_SIDECAR; do
      echo "${key}=${PORT[$key]}"; done
} > "$PORT_STATE"

MINDROUTER_PORT="${PORT[MR_GATEWAY]}"
MINDROUTER_MCP_PORT="${PORT[MR_MCP]}"
MARIADB_PORT="${PORT[MR_MARIADB]}"
ARCHIVE_PORT="${PORT[MR_ARCHIVE]}"
REDIS_PORT="${PORT[MR_REDIS]}"
SIDECAR_PORT="${PORT[MR_SIDECAR]}"
info "Ports: gateway ${MINDROUTER_PORT}, mcp ${MINDROUTER_MCP_PORT}, mariadb ${MARIADB_PORT}, archive ${ARCHIVE_PORT}, redis ${REDIS_PORT}, sidecar ${SIDECAR_PORT}"

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
envval() { grep "^${1}=" "$MINDROUTER_DIR/.env" | head -1 | cut -d= -f2-; }
SIDECAR_SECRET_KEY="$(envval SIDECAR_SECRET_KEY)"
MYSQL_ROOT_PASSWORD="$(envval MYSQL_ROOT_PASSWORD)"
MYSQL_PASSWORD="$(envval MYSQL_PASSWORD)"
MYSQL_ARCHIVE_PASSWORD="$(envval MYSQL_ARCHIVE_PASSWORD)"
: "${MYSQL_PASSWORD:=mindrouter_password}"      # compose defaults if .env predates this installer
: "${MYSQL_ARCHIVE_PASSWORD:=archive_password}"

# ── Compose override: ports + connection URLs + local storage ──────────────
# Every MindRouter service uses host networking, so each host port moved here
# must be moved in BOTH places: the service's own listen port, and the URL
# the app/mcp containers use to reach it (they dial 127.0.0.1:<port>).
# compose merges `environment` by key with the override winning.
DB_URL="mysql+pymysql://mindrouter:${MYSQL_PASSWORD}@127.0.0.1:${MARIADB_PORT}/mindrouter"
ARCHIVE_URL="mysql+pymysql://mindrouter_archive:${MYSQL_ARCHIVE_PASSWORD}@127.0.0.1:${ARCHIVE_PORT}/mindrouter_archive"
REDIS_URL="redis://127.0.0.1:${REDIS_PORT}/0"

# The archive DB's my.cnf (mariadb/archive.cnf, mounted at conf.d/custom.cnf)
# hardcodes `port = 3307`, which overrides MYSQL_TCP_PORT. Generate a
# replacement cnf carrying the chosen port so the archive binds where we
# told it. (The main DB's custom.cnf sets no port, so MYSQL_TCP_PORT alone
# moves it.)
cat > "$MINDROUTER_DIR/.mr-archive.cnf" <<EOF
# Generated by dgx-stack install-mindrouter.sh — overrides mariadb/archive.cnf
[mysqld]
port = ${ARCHIVE_PORT}
character_set_server = utf8mb4
collation_server = utf8mb4_unicode_ci
max_allowed_packet = 64M
EOF
info "Writing docker-compose.override.yml (gateway :${MINDROUTER_PORT}, and remapped infra ports)"
cat > "$MINDROUTER_DIR/docker-compose.override.yml" <<EOF
# Generated by dgx-stack install-mindrouter.sh — do not edit by hand.
# Moves every host-bound MindRouter port to an auto-selected free port
# (pinned in .dgx-ports) and rewrites the app/mcp connection URLs to match,
# and replaces site-specific /archivedb bind mounts with a named volume.
services:
  app:
    command: ["uvicorn", "backend.app.main:app", "--host", "0.0.0.0", "--port", "${MINDROUTER_PORT}", "--workers", "2", "--timeout-graceful-shutdown", "60"]
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:${MINDROUTER_PORT}/healthz"]
      interval: 10s
      timeout: 5s
      retries: 3
      start_period: 15s
    environment:
      - DATABASE_URL=${DB_URL}
      - ARCHIVE_DATABASE_URL=${ARCHIVE_URL}
      - REDIS_URL=${REDIS_URL}
      - MCP_SERVER_URL=http://127.0.0.1:${MINDROUTER_MCP_PORT}
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
    environment:
      - DATABASE_URL=${DB_URL}
      - REDIS_URL=${REDIS_URL}
  mariadb:
    environment:
      - MYSQL_TCP_PORT=${MARIADB_PORT}
  mariadb-archive:
    environment:
      - MYSQL_TCP_PORT=${ARCHIVE_PORT}
    volumes:
      - mariadb_archive_data:/var/lib/mysql
      # Replace the port-pinning archive.cnf (mounted at the same target in
      # the base compose) with our port-aware copy.
      - ${MINDROUTER_DIR}/.mr-archive.cnf:/etc/mysql/conf.d/custom.cnf:ro
  redis:
    # redis-cli in the healthcheck defaults to 6379, so it must be told the
    # moved port explicitly or the container reports unhealthy forever.
    command: redis-server --appendonly yes --port ${REDIS_PORT}
    healthcheck:
      test: ["CMD", "redis-cli", "-p", "${REDIS_PORT}", "ping"]
      interval: 10s
      timeout: 5s
      retries: 5
  gpu-sidecar:
    # Only the port changes; compose merges environment by key, so the base
    # service's SIDECAR_SECRET_KEY and GPU_AGENT_HOST are preserved.
    environment:
      - GPU_AGENT_PORT=${SIDECAR_PORT}
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
    info "Seeding admin user (groups, admin account, quota)"
    # The seed creates the groups + admin user. Its one-time key print is
    # unreliable — a benign aiomysql "Event loop is closed" teardown warning
    # can eat the line while the key is still committed — so we IGNORE the
    # seed's output entirely and mint our own key deterministically below.
    # This also removes the old unrecoverable-key trap: if a prior partial
    # install left an admin user, we simply mint a fresh key for it.
    (cd "$MINDROUTER_DIR" && $DOCKER compose run --rm --no-deps -T app python scripts/seed_dev_data.py >/dev/null 2>&1) \
        || warn "seed returned nonzero (usually just the asyncio teardown warning) — continuing"

    info "Minting an admin API key via MindRouter's own key helpers"
    mint_out="$(cd "$MINDROUTER_DIR" && $DOCKER compose run --rm --no-deps -T app python - 2>/dev/null <<'PY'
import asyncio
from backend.app.db.session import get_async_db_context
from backend.app.db import crud
from backend.app.security import generate_api_key

async def main():
    async with get_async_db_context() as db:
        user = await crud.get_user_by_username(db, "admin")
        if user is None:
            print("DGX_KEY_ERROR=no-admin-user"); return
        full_key, key_hash, key_prefix = generate_api_key()
        await crud.create_api_key(db=db, user_id=user.id, key_hash=key_hash,
                                  key_prefix=key_prefix, name="dgx-stack installer")
        await db.commit()
        print("DGX_ADMIN_KEY=" + full_key)

asyncio.run(main())
PY
)" || true
    # Anchor on our sentinel so any interleaved teardown noise is ignored.
    admin_key="$(printf '%s\n' "$mint_out" | sed -n 's/^DGX_ADMIN_KEY=//p' | head -1)"
    if [[ -z "$admin_key" ]]; then
        printf '%s\n' "$mint_out" | tail -5
        die "Could not mint an admin API key — check: $DOCKER compose -f $MINDROUTER_DIR/docker-compose.yml run --rm app python scripts/seed_dev_data.py"
    fi
    printf '%s' "$admin_key" > "$MINDROUTER_DIR/.admin_api_key"
    chmod 600 "$MINDROUTER_DIR/.admin_api_key"
    info "Admin API key minted and saved to $MINDROUTER_DIR/.admin_api_key (chmod 600)"
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
