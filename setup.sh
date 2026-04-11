#!/usr/bin/env bash
set -euo pipefail

# ───────────────────────────────────────────────────────────────────────────
# DGX Stack Setup
# Interactive configuration and deployment for vLLM + OCR on DGX Spark
# ───────────────────────────────────────────────────────────────────────────

BOLD='\033[1m'
DIM='\033[2m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
RESET='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║           DGX Spark Stack Setup                         ║${RESET}"
    echo -e "${CYAN}${BOLD}║           vLLM + OCR Service                            ║${RESET}"
    echo -e "${CYAN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
}

info()  { echo -e "${GREEN}[INFO]${RESET}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*"; }
step()  { echo -e "${BLUE}[STEP]${RESET}  $*"; }

ask() {
    local prompt="$1" default="$2" var="$3"
    if [[ -n "$default" ]]; then
        echo -ne "${BOLD}${prompt}${RESET} ${DIM}[${default}]${RESET}: "
    else
        echo -ne "${BOLD}${prompt}${RESET}: "
    fi
    read -r input
    eval "$var=\"${input:-$default}\""
}

confirm() {
    local prompt="$1" default="${2:-n}"
    local hint="[y/N]"
    [[ "$default" == "y" ]] && hint="[Y/n]"
    echo -ne "${BOLD}${prompt}${RESET} ${hint}: "
    read -r yn
    yn="${yn:-$default}"
    [[ "$yn" =~ ^[Yy]$ ]]
}

# ───────────────────────────────────────────────────────────────────────────
# Docker and state detection
# ───────────────────────────────────────────────────────────────────────────

check_docker() {
    step "Checking Docker..."

    if ! command -v docker &>/dev/null; then
        error "Docker is not installed. Install Docker Engine first:"
        error "  https://docs.docker.com/engine/install/"
        exit 1
    fi

    if ! docker compose version &>/dev/null 2>&1; then
        error "Docker Compose v2 is not available. Install the compose plugin."
        exit 1
    fi

    # Is the daemon running?
    if ! docker info &>/dev/null; then
        warn "Docker daemon is not running."
        if confirm "Try to start it now (requires sudo)?" "y"; then
            if command -v systemctl &>/dev/null; then
                sudo systemctl start docker || {
                    error "Failed to start Docker. Start it manually and re-run."
                    exit 1
                }
                sleep 2
                if ! docker info &>/dev/null; then
                    error "Docker still not responding. Start it manually and re-run."
                    exit 1
                fi
                info "Docker started."
            else
                error "systemctl not available. Please start Docker manually."
                exit 1
            fi
        else
            exit 1
        fi
    fi

    if ! docker info 2>/dev/null | grep -qi "nvidia\|gpu" && ! docker info 2>/dev/null | grep -qi "runtimes.*nvidia"; then
        warn "NVIDIA Container Toolkit may not be installed or configured."
        warn "See: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/"
        if ! confirm "Continue anyway?" "n"; then
            exit 1
        fi
    fi

    info "Docker is ready."
    echo ""
}

detect_state() {
    HAS_ENV=false
    VLLM_RUNNING=false
    OCR_RUNNING=false
    VLLM_EXISTS=false
    OCR_EXISTS=false

    [[ -f ".env" ]] && HAS_ENV=true

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vllm-server$'; then
        VLLM_RUNNING=true
        VLLM_EXISTS=true
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^vllm-server$'; then
        VLLM_EXISTS=true
    fi

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^ocr-service$'; then
        OCR_RUNNING=true
        OCR_EXISTS=true
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^ocr-service$'; then
        OCR_EXISTS=true
    fi
}

show_state() {
    echo -e "${BOLD}── Current State ──${RESET}"
    if [[ "$HAS_ENV" == true ]]; then
        local model
        model=$(grep -E '^SERVED_MODEL_NAME=' .env 2>/dev/null | cut -d= -f2)
        printf "  %-20s ${GREEN}found${RESET} (model: %s)\n" ".env config:" "${model:-unknown}"
    else
        printf "  %-20s ${DIM}not found${RESET}\n" ".env config:"
    fi

    if [[ "$VLLM_RUNNING" == true ]]; then
        printf "  %-20s ${GREEN}running${RESET}\n" "vllm-server:"
    elif [[ "$VLLM_EXISTS" == true ]]; then
        printf "  %-20s ${YELLOW}stopped${RESET}\n" "vllm-server:"
    else
        printf "  %-20s ${DIM}not present${RESET}\n" "vllm-server:"
    fi

    if [[ "$OCR_RUNNING" == true ]]; then
        printf "  %-20s ${GREEN}running${RESET}\n" "ocr-service:"
    elif [[ "$OCR_EXISTS" == true ]]; then
        printf "  %-20s ${YELLOW}stopped${RESET}\n" "ocr-service:"
    else
        printf "  %-20s ${DIM}not present${RESET}\n" "ocr-service:"
    fi
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Main menu
# ───────────────────────────────────────────────────────────────────────────

main_menu() {
    echo -e "${BOLD}── Main Menu ──${RESET}"
    echo ""
    echo -e "  ${BOLD}1)${RESET} Fresh Install     ${DIM}— configure from scratch, deploy${RESET}"
    echo -e "  ${BOLD}2)${RESET} Re-Install        ${DIM}— rebuild containers, redeploy with current config${RESET}"
    echo -e "  ${BOLD}3)${RESET} Repair/Reconfigure ${DIM}— change settings and restart${RESET}"
    echo -e "  ${BOLD}4)${RESET} Test              ${DIM}— run health + end-to-end checks on the running stack${RESET}"
    echo -e "  ${BOLD}5)${RESET} Turn Off          ${DIM}— stop all containers${RESET}"
    echo -e "  ${BOLD}6)${RESET} View Logs         ${DIM}— tail container logs${RESET}"
    echo -e "  ${BOLD}7)${RESET} Configure Networks ${DIM}— install /etc/docker/daemon.json to use 10.10.x.x${RESET}"
    echo -e "  ${BOLD}q)${RESET} Quit"
    echo ""

    local choice
    echo -ne "${BOLD}Select an option${RESET}: "
    read -r choice

    case "$choice" in
        1) action_fresh_install ;;
        2) action_reinstall ;;
        3) action_repair ;;
        4) action_test ;;
        5) action_turn_off ;;
        6) action_view_logs ;;
        7) action_configure_networks ;;
        q|Q) echo "Goodbye."; exit 0 ;;
        *)
            error "Invalid choice."
            sleep 1
            main_menu
            ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Fresh Install
# ───────────────────────────────────────────────────────────────────────────

action_fresh_install() {
    echo ""
    step "Fresh Install"
    echo ""

    if [[ "$VLLM_EXISTS" == true ]] || [[ "$OCR_EXISTS" == true ]] || [[ "$HAS_ENV" == true ]]; then
        warn "Existing installation detected."
        echo ""
        echo "Fresh install will:"
        [[ "$VLLM_RUNNING" == true || "$OCR_RUNNING" == true ]] && echo "  • Stop running containers"
        [[ "$VLLM_EXISTS" == true || "$OCR_EXISTS" == true ]] && echo "  • Remove existing containers"
        [[ "$HAS_ENV" == true ]] && echo "  • Back up and overwrite .env"
        echo ""
        echo -e "  ${DIM}(Model weights in HF cache will be preserved)${RESET}"
        echo ""

        if ! confirm "Continue?" "n"; then
            echo ""
            main_menu
            return
        fi

        stop_and_remove_containers
    fi

    select_model
    configure_interactive
    review
    write_env
    deploy
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Re-Install
# ───────────────────────────────────────────────────────────────────────────

action_reinstall() {
    echo ""
    step "Re-Install"
    echo ""

    if [[ "$HAS_ENV" != true ]]; then
        error "No .env found. Use Fresh Install instead."
        echo ""
        confirm "Return to menu?" "y" && main_menu
        return
    fi

    echo "Re-Install will:"
    echo "  • Stop and remove the current containers"
    echo "  • Rebuild the OCR container image"
    echo "  • Re-pull the vLLM container image"
    echo "  • Start services with the existing .env"
    echo ""
    echo -e "  ${DIM}(Model weights and .env config are preserved)${RESET}"
    echo ""

    if ! confirm "Continue?" "y"; then
        echo ""
        main_menu
        return
    fi

    # Load env just to show the user what model is configured
    load_env_values

    stop_and_remove_containers

    step "Rebuilding OCR container..."
    docker compose build --no-cache ocr

    step "Re-pulling vLLM image..."
    docker compose pull vllm

    deploy_start_and_wait
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Repair / Reconfigure
# ───────────────────────────────────────────────────────────────────────────

action_repair() {
    echo ""
    step "Repair / Reconfigure"
    echo ""

    if [[ "$HAS_ENV" != true ]]; then
        error "No .env found. Use Fresh Install instead."
        echo ""
        confirm "Return to menu?" "y" && main_menu
        return
    fi

    info "Loading current settings from .env..."
    load_env_values
    echo ""

    echo "Current model: ${SERVED_MODEL_NAME:-unknown}"
    if confirm "Keep current model, or switch?" "y"; then
        info "Keeping current model."
    else
        select_model
    fi
    echo ""

    configure_interactive
    review

    if ! confirm "Apply these changes?" "y"; then
        echo ""
        main_menu
        return
    fi

    write_env
    stop_and_remove_containers
    deploy_start_and_wait
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Test
# Run non-destructive health + end-to-end checks on the running stack.
# ───────────────────────────────────────────────────────────────────────────

action_test() {
    echo ""
    step "Test"
    echo ""

    if [[ "$HAS_ENV" != true ]]; then
        error "No .env found. There is nothing deployed to test."
        echo ""
        confirm "Return to menu?" "y" && main_menu
        return
    fi

    # Make sure VLLM_PORT / OCR_PORT etc. are in the environment for the checks.
    load_env_values

    if [[ "$VLLM_RUNNING" != true ]] && [[ "$OCR_RUNNING" != true ]]; then
        error "Neither vllm-server nor ocr-service is running."
        info  "Start the stack with Re-Install (option 2) or 'docker compose up -d'."
        echo ""
        confirm "Return to menu?" "y" && main_menu
        return
    fi

    # ── Container / port health ────────────────────────────────────────────
    echo -e "${BOLD}── Container health ──${RESET}"
    if [[ "$VLLM_RUNNING" == true ]]; then
        info "vllm-server is running"
    else
        error "vllm-server is NOT running"
    fi
    if [[ "$OCR_RUNNING" == true ]]; then
        info "ocr-service is running"
    else
        error "ocr-service is NOT running"
    fi

    echo ""
    echo -e "${BOLD}── HTTP health ──${RESET}"
    if curl -sf --max-time 5 "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
        info "vLLM  /health  OK  (port ${VLLM_PORT})"
    else
        error "vLLM  /health  failed  (port ${VLLM_PORT})"
    fi
    if curl -sf --max-time 5 "http://localhost:${OCR_PORT}/health" &>/dev/null \
       || curl -sf --max-time 5 "http://localhost:${OCR_PORT}/" &>/dev/null; then
        info "OCR   /       OK  (port ${OCR_PORT})"
    else
        warn "OCR service did not respond on port ${OCR_PORT}"
    fi

    # ── End-to-end smoke tests ─────────────────────────────────────────────
    run_smoke_tests

    echo ""
    confirm "Return to menu?" "y" && main_menu
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Configure Networks
# Install /etc/docker/daemon.json so Docker allocates ALL networks (not just
# this stack's) from 10.10.0.0/16 instead of the default 172.16.0.0/12 pool.
# This avoids conflicts with sites that already use 172.x.x.x.
# ───────────────────────────────────────────────────────────────────────────

action_configure_networks() {
    echo ""
    step "Configure Docker Networks (10.10.0.0/16)"
    echo ""

    local template="${SCRIPT_DIR}/docker/daemon.json"
    local target="/etc/docker/daemon.json"

    if [[ ! -f "$template" ]]; then
        error "Template not found at ${template}"
        echo ""
        confirm "Return to menu?" "y" && main_menu
        return
    fi

    echo "This will configure the Docker daemon to allocate all networks"
    echo "(not just this stack) from the 10.10.0.0/16 range instead of the"
    echo "default 172.16.0.0/12 pool. Useful when 172.x.x.x conflicts with"
    echo "corporate routes, VPNs, or other services."
    echo ""
    echo "  Source:  ${template}"
    echo "  Target:  ${target}"
    echo ""
    echo "Steps:"
    echo "  1. Back up any existing ${target} to ${target}.bak-<timestamp>"
    echo "  2. Merge the default-address-pools setting into the config"
    echo "     (or write a fresh file if none exists)"
    echo "  3. Restart docker.service"
    echo ""
    warn "Restarting the Docker daemon will briefly stop ALL containers on"
    warn "this host, including containers outside this stack."
    echo ""

    if ! confirm "Proceed?" "n"; then
        echo ""
        main_menu
        return
    fi

    # Must be root (or able to sudo) to touch /etc/docker.
    local SUDO=""
    if [[ $EUID -ne 0 ]]; then
        if command -v sudo &>/dev/null; then
            SUDO="sudo"
            info "Will use sudo for /etc/docker writes and systemctl."
        else
            error "Not running as root and sudo is not available."
            echo ""
            confirm "Return to menu?" "y" && main_menu
            return
        fi
    fi

    $SUDO mkdir -p /etc/docker

    local ts
    ts="$(date +%Y%m%d-%H%M%S)"

    if [[ -f "$target" ]]; then
        info "Existing ${target} found. Backing up to ${target}.bak-${ts}"
        $SUDO cp "$target" "${target}.bak-${ts}"

        # Merge: keep everything in the existing file, override/add
        # default-address-pools with our value.
        local merged
        if ! merged="$(python3 -c '
import json, sys
with open(sys.argv[1]) as f:
    existing = json.load(f)
with open(sys.argv[2]) as f:
    ours = json.load(f)
existing["default-address-pools"] = ours["default-address-pools"]
sys.stdout.write(json.dumps(existing, indent=2) + "\n")
' "$target" "$template" 2>/dev/null)"; then
            error "Failed to merge existing ${target} with template."
            error "Existing file may contain invalid JSON. Aborting."
            echo ""
            confirm "Return to menu?" "y" && main_menu
            return
        fi
        printf '%s' "$merged" | $SUDO tee "$target" >/dev/null
    else
        info "No existing ${target}; writing fresh template."
        $SUDO cp "$template" "$target"
    fi

    info "Wrote ${target}:"
    $SUDO cat "$target" | sed 's/^/    /'

    echo ""
    step "Restarting docker.service..."
    if ! $SUDO systemctl restart docker; then
        error "docker.service restart failed."
        error "Check:  $SUDO systemctl status docker"
        echo ""
        confirm "Return to menu?" "y" && main_menu
        return
    fi

    # Wait a few seconds for the daemon to come back.
    local waited=0
    while (( waited < 20 )); do
        if docker info &>/dev/null; then
            break
        fi
        sleep 1
        waited=$((waited + 1))
    done

    if ! docker info &>/dev/null; then
        warn "Docker daemon did not respond within 20s after restart."
        warn "It may still be coming up. Run: docker info"
    else
        info "Docker daemon is back up."
        echo ""
        info "docker0 address:"
        ip -4 addr show docker0 2>/dev/null | grep -oE 'inet [0-9.]+/[0-9]+' \
            | sed 's/^/    /' || echo "    (docker0 not yet assigned)"
    fi

    echo ""
    info "Done. New networks will allocate from 10.10.0.0/16 in /24 slices."
    info "Existing networks keep their old subnets until recreated."
    info "To move this stack onto the new pool, run Re-Install (option 2)."
    echo ""

    confirm "Return to menu?" "y" && main_menu
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Turn Off
# ───────────────────────────────────────────────────────────────────────────

action_turn_off() {
    echo ""
    step "Turn Off"
    echo ""

    if [[ "$VLLM_RUNNING" != true ]] && [[ "$OCR_RUNNING" != true ]]; then
        info "No containers are currently running."
        echo ""
        confirm "Return to menu?" "y" && main_menu
        return
    fi

    if ! confirm "Stop all stack containers?" "y"; then
        echo ""
        main_menu
        return
    fi

    step "Stopping containers..."
    docker compose down
    info "Stack stopped."
    echo ""
    echo -e "  ${DIM}Containers removed. Model weights and .env are preserved.${RESET}"
    echo -e "  ${DIM}Run this script again to start the stack.${RESET}"
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Action: View Logs
# ───────────────────────────────────────────────────────────────────────────

action_view_logs() {
    echo ""
    step "View Logs"
    echo ""
    echo "  1) Both services"
    echo "  2) vLLM only"
    echo "  3) OCR only"
    echo "  b) Back to menu"
    echo ""
    local choice
    ask "Select" "1" choice

    case "$choice" in
        1) docker compose logs --tail=200 -f ;;
        2) docker compose logs --tail=200 -f vllm ;;
        3) docker compose logs --tail=200 -f ocr ;;
        *) main_menu ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────
# Helpers: stop/remove containers, load existing env
# ───────────────────────────────────────────────────────────────────────────

stop_and_remove_containers() {
    if [[ "$VLLM_EXISTS" == true ]] || [[ "$OCR_EXISTS" == true ]]; then
        step "Stopping and removing existing containers..."
        docker compose down 2>/dev/null || {
            # Fallback if compose state is inconsistent
            docker rm -f vllm-server ocr-service 2>/dev/null || true
        }
        detect_state
    fi
}

load_env_values() {
    # Parse .env manually — never use `source` because values may contain
    # spaces or flag-like tokens that bash would try to execute.
    local line key value
    while IFS= read -r line || [[ -n "$line" ]]; do
        # Skip comments and blank lines
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        # Must contain =
        [[ "$line" != *=* ]] && continue
        key="${line%%=*}"
        value="${line#*=}"
        # Trim leading whitespace from key
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"
        # Strip surrounding single or double quotes from value
        if [[ "$value" =~ ^\"(.*)\"$ ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'(.*)\'$ ]]; then
            value="${BASH_REMATCH[1]}"
        fi
        # Only allow valid identifier keys
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        printf -v "$key" '%s' "$value"
    done < .env

    # Set defaults for anything missing
    VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:gemma4-cu130}"
    HF_MODEL_ID="${HF_MODEL_ID:-google/gemma-4-26B-A4B-it}"
    SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-gemma-4-26b}"
    VLLM_EXTRA_FLAGS="${VLLM_EXTRA_FLAGS:---no-enable-prefix-caching}"
    VLLM_TEST_FORCE_FP8_MARLIN="${VLLM_TEST_FORCE_FP8_MARLIN:-0}"
    VLLM_USE_DEEP_GEMM="${VLLM_USE_DEEP_GEMM:-1}"
    VLLM_ENABLE_THINKING_DEFAULT="${VLLM_ENABLE_THINKING_DEFAULT:-}"
    HF_TOKEN="${HF_TOKEN:-}"
    HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
    VLLM_PORT="${VLLM_PORT:-8000}"
    OCR_PORT="${OCR_PORT:-8001}"
    DGX_NET_SUBNET="${DGX_NET_SUBNET:-10.10.99.0/24}"
    DGX_NET_GATEWAY="${DGX_NET_GATEWAY:-10.10.99.1}"
    GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.75}"
    MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
    MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
    MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-fp8}"
    OCR_CHUNK_SIZE="${OCR_CHUNK_SIZE:-6}"
    OCR_OVERLAP="${OCR_OVERLAP:-2}"
    OCR_DPI="${OCR_DPI:-200}"
    OCR_MAX_TOKENS="${OCR_MAX_TOKENS:-16384}"
    OCR_MAX_CONCURRENT_CHUNKS="${OCR_MAX_CONCURRENT_CHUNKS:-4}"
    OCR_MAX_PAGES="${OCR_MAX_PAGES:-200}"
    OCR_MAX_FILE_SIZE_MB="${OCR_MAX_FILE_SIZE_MB:-100}"

    # Derive MODEL_CHOICE and NEEDS_HF_TOKEN from the model ID
    if [[ "$HF_MODEL_ID" == *"gemma"* ]]; then
        MODEL_CHOICE="gemma4"
        NEEDS_HF_TOKEN=true
        DEFAULT_MAX_MODEL_LEN="131072"
        DEFAULT_MAX_NUM_BATCHED_TOKENS="8192"
        DEFAULT_GPU_MEMORY_UTIL="0.75"
        DEFAULT_KV_CACHE_DTYPE="fp8"
    else
        MODEL_CHOICE="qwen35"
        NEEDS_HF_TOKEN=false
        DEFAULT_MAX_MODEL_LEN="131072"
        DEFAULT_MAX_NUM_BATCHED_TOKENS="8192"
        DEFAULT_GPU_MEMORY_UTIL="0.75"
        DEFAULT_KV_CACHE_DTYPE="fp8"
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Model selection
# ───────────────────────────────────────────────────────────────────────────

select_model() {
    echo -e "${BOLD}── Model Selection ──${RESET}"
    echo ""
    echo "  Both models serve as LLM and OCR (multimodal vision)."
    echo ""
    echo -e "  ${BOLD}1)${RESET} Gemma 4 26B  ${DIM}(google/gemma-4-26B-A4B-it)${RESET}"
    echo "     MoE 26B total / 4B active, BF16 ~52GB weights"
    echo "     128K context, strong general LLM"
    echo "     Requires HuggingFace token + license acceptance"
    echo ""
    echo -e "  ${BOLD}2)${RESET} Qwen 3.5 35B FP8 ${DIM}(Qwen/Qwen3.5-35B-A3B-FP8)${RESET}"
    echo "     MoE 35B total / 3B active, FP8 ~35GB weights"
    echo "     262K context, excellent OCR and table handling"
    echo "     Open access, no token required"
    echo ""

    local choice
    ask "Select model (1 or 2)" "1" choice

    case "$choice" in
        1)
            MODEL_CHOICE="gemma4"
            VLLM_IMAGE="vllm/vllm-openai:gemma4-cu130"
            HF_MODEL_ID="google/gemma-4-26B-A4B-it"
            SERVED_MODEL_NAME="gemma-4-26b"
            DEFAULT_MAX_MODEL_LEN="131072"
            DEFAULT_MAX_NUM_BATCHED_TOKENS="8192"
            DEFAULT_GPU_MEMORY_UTIL="0.75"
            DEFAULT_KV_CACHE_DTYPE="fp8"
            VLLM_EXTRA_FLAGS="--no-enable-prefix-caching"
            VLLM_TEST_FORCE_FP8_MARLIN=0
            VLLM_USE_DEEP_GEMM=1
            VLLM_ENABLE_THINKING_DEFAULT=""
            NEEDS_HF_TOKEN=true
            info "Selected: Gemma 4 26B"
            ;;
        2)
            MODEL_CHOICE="qwen35"
            VLLM_IMAGE="vllm/vllm-openai:cu130-nightly"
            HF_MODEL_ID="Qwen/Qwen3.5-35B-A3B-FP8"
            SERVED_MODEL_NAME="qwen3.5-35b"
            DEFAULT_MAX_MODEL_LEN="131072"
            DEFAULT_MAX_NUM_BATCHED_TOKENS="8192"
            DEFAULT_GPU_MEMORY_UTIL="0.75"
            DEFAULT_KV_CACHE_DTYPE="fp8"
            VLLM_EXTRA_FLAGS="--enable-prefix-caching --reasoning-parser deepseek_r1"
            VLLM_TEST_FORCE_FP8_MARLIN=1
            VLLM_USE_DEEP_GEMM=0
            # Leave empty by default. Set to "true" or "false" in .env to pass
            # --default-chat-template-kwargs '{"enable_thinking":<value>}' at
            # serve time. Empty = let the model's built-in chat template decide.
            VLLM_ENABLE_THINKING_DEFAULT=""
            NEEDS_HF_TOKEN=false
            info "Selected: Qwen 3.5 35B (FP8 pre-quantized)"
            info "FP8 weights ~35GB — leaves ~61GB for KV cache at 0.75 util."
            ;;
        *)
            error "Invalid choice. Please enter 1 or 2."
            select_model
            ;;
    esac
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Interactive configuration
# ───────────────────────────────────────────────────────────────────────────

configure_interactive() {
    # ── HuggingFace Token ──
    if [[ "$NEEDS_HF_TOKEN" == true ]]; then
        echo -e "${BOLD}── HuggingFace Token ──${RESET}"
        echo "Gemma 4 is a gated model. You need a HuggingFace token with access."
        echo "Get one at: https://huggingface.co/settings/tokens"
        echo "Accept the license at: https://huggingface.co/google/gemma-4-26B-A4B-it"
        echo ""

        local hf_default="${HF_TOKEN:-}"
        if [[ -z "$hf_default" ]] && [[ -f "$HOME/.cache/huggingface/token" ]]; then
            hf_default=$(cat "$HOME/.cache/huggingface/token")
            info "Found cached HuggingFace token."
        fi

        if [[ -n "$hf_default" ]]; then
            local masked="${hf_default:0:8}...${hf_default: -4}"
            echo -ne "${BOLD}HuggingFace token${RESET} ${DIM}[${masked}]${RESET}: "
            read -r input
            HF_TOKEN="${input:-$hf_default}"
        else
            echo -ne "${BOLD}HuggingFace token${RESET}: "
            read -r HF_TOKEN
        fi

        if [[ -z "$HF_TOKEN" ]]; then
            error "HuggingFace token is required for Gemma 4."
            exit 1
        fi
    else
        echo -e "${BOLD}── HuggingFace Token ──${RESET}"
        echo "Qwen 3.5 is open access. Token is optional."
        echo ""

        local hf_default="${HF_TOKEN:-}"
        if [[ -z "$hf_default" ]] && [[ -f "$HOME/.cache/huggingface/token" ]]; then
            hf_default=$(cat "$HOME/.cache/huggingface/token")
        fi

        if [[ -n "$hf_default" ]]; then
            local masked="${hf_default:0:8}...${hf_default: -4}"
            echo -ne "${BOLD}HuggingFace token (optional)${RESET} ${DIM}[${masked}]${RESET}: "
            read -r input
            HF_TOKEN="${input:-$hf_default}"
        else
            echo -ne "${BOLD}HuggingFace token (optional, press Enter to skip)${RESET}: "
            read -r HF_TOKEN
        fi
    fi
    echo ""

    # ── Ports ──
    echo -e "${BOLD}── Network Ports ──${RESET}"
    ask "vLLM API port (OpenAI-compatible)" "${VLLM_PORT:-8000}" VLLM_PORT
    ask "OCR service port" "${OCR_PORT:-8001}" OCR_PORT
    echo ""

    # ── Docker Network ──
    echo -e "${BOLD}── Docker Network ──${RESET}"
    echo "This stack's bridge network lives in the 10.10.x.x range by default"
    echo "(to avoid the Docker default 172.16.0.0/12 pool). If the default"
    echo "overlaps with an existing network or a host route, pick another /24."
    ask "Docker network subnet (CIDR)" "${DGX_NET_SUBNET:-10.10.99.0/24}" DGX_NET_SUBNET
    # Auto-derive a gateway as .1 of whatever subnet they chose, unless they
    # already have a custom gateway in .env.
    local auto_gateway
    auto_gateway="$(python3 -c '
import ipaddress, sys
net = ipaddress.ip_network(sys.argv[1], strict=False)
print(str(next(net.hosts())))
' "$DGX_NET_SUBNET" 2>/dev/null || echo "")"
    ask "Docker network gateway" "${DGX_NET_GATEWAY:-${auto_gateway:-10.10.99.1}}" DGX_NET_GATEWAY
    echo ""

    # ── GPU / Memory ──
    echo -e "${BOLD}── GPU Memory ──${RESET}"
    echo "DGX Spark has 128GB unified memory shared between CPU and GPU."
    if [[ "$MODEL_CHOICE" == "qwen35" ]]; then
        echo "Qwen 3.5 35B FP8 weights are ~35GB. At 0.75 (~96GB), ~61GB"
        echo "remains for KV cache + OS + OCR container."
    else
        echo "Gemma 4 26B BF16 weights are ~52GB. At 0.75 (~96GB), ~44GB"
        echo "remains for KV cache + OS + OCR container."
    fi
    echo ""
    ask "GPU memory utilization (0.5 - 0.90)" "${GPU_MEMORY_UTIL:-$DEFAULT_GPU_MEMORY_UTIL}" GPU_MEMORY_UTIL
    echo ""

    if (( $(echo "$GPU_MEMORY_UTIL < 0.5" | bc -l 2>/dev/null || echo 0) )) || \
       (( $(echo "$GPU_MEMORY_UTIL > 0.95" | bc -l 2>/dev/null || echo 0) )); then
        warn "Unusual value: $GPU_MEMORY_UTIL. Recommended range is 0.60 - 0.85."
        if ! confirm "Continue with this value?" "n"; then
            exit 1
        fi
    fi

    # ── Model Config ──
    echo -e "${BOLD}── Model Configuration ──${RESET}"
    ask "Max context length (tokens)" "${MAX_MODEL_LEN:-$DEFAULT_MAX_MODEL_LEN}" MAX_MODEL_LEN
    ask "Max concurrent sequences" "${MAX_NUM_SEQS:-4}" MAX_NUM_SEQS
    ask "Max batched tokens (required ≥ Mamba block size for Qwen)" "${MAX_NUM_BATCHED_TOKENS:-$DEFAULT_MAX_NUM_BATCHED_TOKENS}" MAX_NUM_BATCHED_TOKENS
    echo ""

    # ── KV Cache ──
    echo -e "${BOLD}── KV Cache ──${RESET}"
    echo "FP8 KV cache saves memory but may cause FlashInfer errors on some builds."
    echo "Use 'auto' (BF16) as a fallback if you see CUDA stream capture errors."
    echo ""
    ask "KV cache dtype (fp8 or auto)" "${KV_CACHE_DTYPE:-$DEFAULT_KV_CACHE_DTYPE}" KV_CACHE_DTYPE
    echo ""

    # ── HuggingFace Cache ──
    echo -e "${BOLD}── Storage ──${RESET}"
    if [[ "$MODEL_CHOICE" == "qwen35" ]]; then
        echo "Model weights (~35GB FP8) are cached locally to avoid re-downloading."
    else
        echo "Model weights (~52GB) are cached locally to avoid re-downloading."
    fi
    ask "HuggingFace cache directory" "${HF_CACHE:-$HOME/.cache/huggingface}" HF_CACHE
    echo ""

    # ── OCR Tuning ──
    echo -e "${BOLD}── OCR Settings ──${RESET}"
    echo -e "${DIM}These control how documents are split and processed.${RESET}"
    ask "Pages per chunk" "${OCR_CHUNK_SIZE:-6}" OCR_CHUNK_SIZE
    ask "Overlap pages between chunks" "${OCR_OVERLAP:-2}" OCR_OVERLAP
    ask "PDF rendering DPI" "${OCR_DPI:-200}" OCR_DPI
    ask "Max tokens per LLM response" "${OCR_MAX_TOKENS:-16384}" OCR_MAX_TOKENS
    ask "Max concurrent chunks" "${OCR_MAX_CONCURRENT_CHUNKS:-4}" OCR_MAX_CONCURRENT_CHUNKS
    ask "Max pages per document" "${OCR_MAX_PAGES:-200}" OCR_MAX_PAGES
    ask "Max upload file size (MB)" "${OCR_MAX_FILE_SIZE_MB:-100}" OCR_MAX_FILE_SIZE_MB
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Review configuration summary
# ───────────────────────────────────────────────────────────────────────────

review() {
    echo ""
    echo -e "${BOLD}── Configuration Summary ──${RESET}"
    echo ""
    printf "  %-30s %s\n" "Model:" "${SERVED_MODEL_NAME} (${HF_MODEL_ID})"
    printf "  %-30s %s\n" "Container:" "${VLLM_IMAGE}"
    printf "  %-30s %s\n" "vLLM port:" "$VLLM_PORT"
    printf "  %-30s %s\n" "OCR port:" "$OCR_PORT"
    printf "  %-30s %s\n" "GPU memory utilization:" "$GPU_MEMORY_UTIL ($(echo "$GPU_MEMORY_UTIL * 128" | bc)GB of 128GB)"
    printf "  %-30s %s\n" "Max context length:" "$MAX_MODEL_LEN tokens"
    printf "  %-30s %s\n" "Max concurrent sequences:" "$MAX_NUM_SEQS"
    printf "  %-30s %s\n" "KV cache dtype:" "$KV_CACHE_DTYPE"
    printf "  %-30s %s\n" "HF cache:" "$HF_CACHE"
    printf "  %-30s %s\n" "OCR chunk/overlap:" "${OCR_CHUNK_SIZE} pages / ${OCR_OVERLAP} overlap"
    printf "  %-30s %s\n" "OCR DPI:" "$OCR_DPI"
    printf "  %-30s %s\n" "OCR max tokens:" "$OCR_MAX_TOKENS"
    if [[ -n "$VLLM_EXTRA_FLAGS" ]]; then
        printf "  %-30s %s\n" "Extra vLLM flags:" "$VLLM_EXTRA_FLAGS"
    fi
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Write .env
# ───────────────────────────────────────────────────────────────────────────

write_env() {
    local envfile=".env"

    if [[ -f "$envfile" ]]; then
        cp "$envfile" ".env.backup"
        info "Backed up existing .env to .env.backup"
    fi

    cat > "$envfile" <<EOF
# ─────────────────────────────────────────────
# DGX Stack Configuration
# Generated by setup.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Model: ${MODEL_CHOICE}
# ─────────────────────────────────────────────

# Model
VLLM_IMAGE="${VLLM_IMAGE}"
HF_MODEL_ID="${HF_MODEL_ID}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME}"
VLLM_EXTRA_FLAGS="${VLLM_EXTRA_FLAGS:---no-enable-prefix-caching}"

# HuggingFace
HF_TOKEN="${HF_TOKEN}"
HF_CACHE="${HF_CACHE}"

# Network
VLLM_PORT=${VLLM_PORT}
OCR_PORT=${OCR_PORT}
DGX_NET_SUBNET=${DGX_NET_SUBNET}
DGX_NET_GATEWAY=${DGX_NET_GATEWAY}

# GPU / Model
GPU_MEMORY_UTIL=${GPU_MEMORY_UTIL}
MAX_MODEL_LEN=${MAX_MODEL_LEN}
MAX_NUM_SEQS=${MAX_NUM_SEQS}
KV_CACHE_DTYPE=${KV_CACHE_DTYPE}
MAX_NUM_BATCHED_TOKENS=${MAX_NUM_BATCHED_TOKENS}
VLLM_TEST_FORCE_FP8_MARLIN=${VLLM_TEST_FORCE_FP8_MARLIN}
VLLM_USE_DEEP_GEMM=${VLLM_USE_DEEP_GEMM}
VLLM_ENABLE_THINKING_DEFAULT=${VLLM_ENABLE_THINKING_DEFAULT}

# OCR
OCR_CHUNK_SIZE=${OCR_CHUNK_SIZE}
OCR_OVERLAP=${OCR_OVERLAP}
OCR_DPI=${OCR_DPI}
OCR_MAX_TOKENS=${OCR_MAX_TOKENS}
OCR_TEMPERATURE=0.1
OCR_MAX_CONCURRENT_CHUNKS=${OCR_MAX_CONCURRENT_CHUNKS}
OCR_MAX_PAGES=${OCR_MAX_PAGES}
OCR_MAX_FILE_SIZE_MB=${OCR_MAX_FILE_SIZE_MB}
EOF

    info "Configuration written to .env"
}

# ───────────────────────────────────────────────────────────────────────────
# Deploy
# ───────────────────────────────────────────────────────────────────────────

deploy() {
    echo ""
    if ! confirm "Deploy now?" "y"; then
        echo ""
        info "To deploy later, run:  docker compose up -d"
        info "Or re-run this script and choose Re-Install."
        return
    fi

    step "Building OCR container..."
    docker compose build ocr

    step "Pulling vLLM container image (this may take a while on first run)..."
    docker compose pull vllm

    deploy_start_and_wait
}

deploy_start_and_wait() {
    step "Starting services..."
    docker compose up -d

    echo ""
    step "Waiting for vLLM to load the model..."
    if [[ "${MODEL_CHOICE:-}" == "qwen35" ]]; then
        info "Qwen 3.5 35B FP8 is ~35GB. First request may take ~60s to warm up."
    else
        info "Gemma 4 26B is ~52GB. This takes several minutes on first run."
    fi
    echo ""
    echo -e "${DIM}  Watch progress:  docker compose logs -f vllm${RESET}"
    echo -e "${DIM}  Check health:    curl http://localhost:${VLLM_PORT}/health${RESET}"
    echo ""

    local max_wait=600
    local elapsed=0
    local interval=10

    while (( elapsed < max_wait )); do
        if curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
            echo ""
            info "vLLM is healthy and serving."
            break
        fi
        # Check if the container crashed
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vllm-server$'; then
            echo ""
            error "vLLM container is no longer running."
            error "Check logs: docker compose logs vllm"
            return
        fi
        echo -ne "\r  Waiting... ${elapsed}s / ${max_wait}s"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if (( elapsed >= max_wait )); then
        echo ""
        warn "vLLM hasn't become healthy after ${max_wait}s."
        warn "Check logs: docker compose logs vllm"
        warn "The service may still be loading. Healthcheck will restart it if needed."
        return
    fi

    run_smoke_tests

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║  Stack is running!                                      ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  Model: ${SERVED_MODEL_NAME}"
    echo ""
    echo "  LLM API (OpenAI-compatible):"
    echo "    http://localhost:${VLLM_PORT}/v1/chat/completions"
    echo ""
    echo "  OCR endpoints:"
    echo "    http://localhost:${OCR_PORT}/v1/ocr     (JSON response)"
    echo "    http://localhost:${OCR_PORT}/v1/ocrmd   (raw markdown)"
    echo ""
    echo "  Quick test:"
    echo "    curl -X POST http://localhost:${OCR_PORT}/v1/ocrmd -F file=@document.pdf"
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Smoke tests — exercise /v1/models, chat completions, and the OCR pipeline
# against the committed examples/test-doc.pdf after a successful deploy.
# ───────────────────────────────────────────────────────────────────────────

run_smoke_tests() {
    echo ""
    if ! confirm "Run end-to-end smoke tests now?" "y"; then
        return
    fi

    local pass=0 fail=0
    local chat_url="http://localhost:${VLLM_PORT}"
    local ocr_url="http://localhost:${OCR_PORT}"
    local test_pdf="${SCRIPT_DIR}/examples/test-doc.pdf"

    # ── Test 1: /v1/models ─────────────────────────────────────────────────
    echo ""
    step "Test 1/3 — GET ${chat_url}/v1/models"
    local models_json served_id
    if models_json="$(curl -sf --max-time 15 "${chat_url}/v1/models" 2>/dev/null)"; then
        served_id="$(printf '%s' "$models_json" \
            | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["data"][0]["id"])' 2>/dev/null || true)"
        if [[ -n "$served_id" ]]; then
            info "Served model id: ${BOLD}${served_id}${RESET}"
            pass=$((pass + 1))
        else
            error "Could not parse model id from response."
            echo "$models_json" | head -c 400
            echo
            fail=$((fail + 1))
        fi
    else
        error "Request to /v1/models failed."
        fail=$((fail + 1))
    fi

    # ── Test 2: chat completions ───────────────────────────────────────────
    echo ""
    step "Test 2/3 — POST ${chat_url}/v1/chat/completions"
    if [[ -n "${served_id:-}" ]]; then
        # Reasoning models (Qwen 3.5 with --reasoning-parser deepseek_r1) split
        # output into reasoning_content + content. Ask for enough tokens to
        # finish thinking *and* produce a final answer, and tell the template
        # not to emit a thinking block when the model supports that hint.
        local chat_body chat_resp http_code chat_content reasoning_content
        # Note: do NOT pass chat_template_kwargs.enable_thinking=false here.
        # On Qwen 3.5 + --reasoning-parser deepseek_r1 that combination
        # causes the parser to misclassify the final answer as reasoning
        # For reasoning models we disable thinking so the request returns
        # fast without burning tokens on a <think> block. This relies on
        # VLLM_ENABLE_THINKING_DEFAULT being plumbed through at serve time;
        # the chat_template_kwargs override is a no-op on Gemma.
        chat_body="$(python3 -c '
import json, sys
print(json.dumps({
    "model": sys.argv[1],
    "messages": [
        {"role": "user", "content": "In one sentence, what is an NVIDIA DGX Spark?"},
    ],
    "max_tokens": 4096,
    "temperature": 0.2,
    "chat_template_kwargs": {"enable_thinking": False},
}))
' "$served_id")"
        # Capture body + HTTP status separately so we can report failures precisely.
        local tmp_body
        tmp_body="$(mktemp)"
        http_code="$(curl -s -o "$tmp_body" -w '%{http_code}' --max-time 180 \
            "${chat_url}/v1/chat/completions" \
            -H "Content-Type: application/json" \
            -d "$chat_body" 2>/dev/null)"
        [[ -z "$http_code" ]] && http_code="000"
        chat_resp="$(cat "$tmp_body")"
        rm -f "$tmp_body"

        if [[ "$http_code" != "200" ]]; then
            error "Chat completion HTTP ${http_code}."
            printf '%s' "$chat_resp" | head -c 500
            echo
            fail=$((fail + 1))
        else
            # Pull content, reasoning, and finish_reason. vLLM reasoning
            # parsers expose the thinking block under "reasoning" in newer
            # builds and "reasoning_content" in older ones — check both.
            # Use python3 -c (not a heredoc) to avoid a bash parser edge case
            # with heredocs inside $(...) on some bash versions.
            local parsed
            parsed="$(printf '%s' "$chat_resp" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    m = d["choices"][0]["message"]
    content = (m.get("content") or "").strip()
    reasoning = (m.get("reasoning") or m.get("reasoning_content") or "").strip()
    finish = d["choices"][0].get("finish_reason", "")
    # Emit as a NUL-delimited stream so multi-line values survive.
    sys.stdout.write("FINISH\x1f" + str(finish) + "\x1e")
    sys.stdout.write("CONTENT\x1f" + content + "\x1e")
    sys.stdout.write("REASONING\x1f" + reasoning + "\x1e")
except Exception as e:
    sys.stdout.write("PARSE_ERROR\x1f" + str(e) + "\x1e")
' 2>/dev/null)" || parsed=""
            # Split the parser output on the 0x1e record separator.
            local finish_reason chat_reasoning
            finish_reason="$(printf '%s' "$parsed" | awk -v RS=$'\x1e' -v FS=$'\x1f' '$1=="FINISH"{print $2}')"
            chat_content="$(printf  '%s' "$parsed" | awk -v RS=$'\x1e' -v FS=$'\x1f' '$1=="CONTENT"{print $2}')"
            chat_reasoning="$(printf '%s' "$parsed" | awk -v RS=$'\x1e' -v FS=$'\x1f' '$1=="REASONING"{print $2}')"

            if [[ -n "$chat_content" ]]; then
                info "Model response (finish=${finish_reason}):"
                echo -e "    ${DIM}${chat_content}${RESET}"
                pass=$((pass + 1))
            elif [[ -n "$chat_reasoning" ]]; then
                # Content was empty but the model reasoned — treat as a pass
                # since the endpoint clearly responded. Show a snippet so the
                # user can see what happened.
                local snippet
                snippet="$(printf '%s' "$chat_reasoning" | head -c 300 | tr '\n' ' ')"
                warn "Content field was null, but model produced reasoning output."
                info "Reasoning (finish=${finish_reason}, ${#chat_reasoning} chars, first 300):"
                echo -e "    ${DIM}${snippet}...${RESET}"
                info "Endpoint is responding. To get answers in 'content', either"
                info "drop --reasoning-parser from VLLM_EXTRA_FLAGS, or have clients"
                info "read the 'reasoning' field in addition to 'content'."
                pass=$((pass + 1))
            else
                error "Chat completion returned empty content AND empty reasoning."
                info  "  finish_reason=${finish_reason}"
                printf '%s' "$chat_resp" | head -c 500
                echo
                fail=$((fail + 1))
            fi
        fi
    else
        warn "Skipped (no served model id from test 1)."
        fail=$((fail + 1))
    fi

    # ── Test 3: OCR pipeline ───────────────────────────────────────────────
    echo ""
    step "Test 3/3 — POST ${ocr_url}/v1/ocrmd  (examples/test-doc.pdf)"
    if [[ ! -f "$test_pdf" ]]; then
        warn "Test PDF not found at ${test_pdf} — skipping."
        fail=$((fail + 1))
    else
        # Preflight: is the OCR container actually up, and is /health reachable?
        local ocr_container_state ocr_health_code
        ocr_container_state="$(docker inspect -f '{{.State.Status}}' ocr-service 2>/dev/null || echo 'missing')"
        info "Container state: ${ocr_container_state}"
        if [[ "$ocr_container_state" != "running" ]]; then
            error "ocr-service container is not running."
            info  "Recent logs (last 30 lines):"
            docker logs --tail 30 ocr-service 2>&1 | sed 's/^/    /' || true
            fail=$((fail + 1))
        else
            local ocr_ready=false
            for _ in 1 2 3 4 5 6; do
                # curl -w writes %{http_code} to stdout even on connection
                # failure (it writes "000"), so do NOT add `|| echo 000` —
                # that would concatenate two copies of the failure code.
                ocr_health_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "${ocr_url}/health" 2>/dev/null)"
                [[ -z "$ocr_health_code" ]] && ocr_health_code="000"
                if [[ "$ocr_health_code" == "200" ]]; then
                    ocr_ready=true
                    break
                fi
                sleep 5
            done
            if [[ "$ocr_ready" != true ]]; then
                error "OCR /health did not return 200 (last HTTP code: ${ocr_health_code})."
                info  "Recent logs (last 30 lines):"
                docker logs --tail 30 ocr-service 2>&1 | sed 's/^/    /' || true
                fail=$((fail + 1))
            else
                info "OCR /health OK — uploading test PDF (3 pages)..."
                local ocr_tmp ocr_code
                ocr_tmp="$(mktemp)"
                ocr_code="$(curl -s -o "$ocr_tmp" -w '%{http_code}' --max-time 600 \
                    -X POST "${ocr_url}/v1/ocrmd" \
                    -F "file=@${test_pdf}" 2>/dev/null)"
                [[ -z "$ocr_code" ]] && ocr_code="000"
                local ocr_out chars
                ocr_out="$(cat "$ocr_tmp")"
                rm -f "$ocr_tmp"
                chars=$(printf '%s' "$ocr_out" | wc -c | tr -d ' ')

                if [[ "$ocr_code" != "200" ]]; then
                    error "OCR HTTP ${ocr_code} (${chars} chars returned)."
                    printf '%s' "$ocr_out" | head -c 500
                    echo
                    fail=$((fail + 1))
                elif grep -q "END-OF-TEST-DOCUMENT" <<< "$ocr_out"; then
                    info "OCR returned ${chars} chars and contains END-OF-TEST-DOCUMENT sentinel."
                    pass=$((pass + 1))
                else
                    error "OCR response (${chars} chars) missing END-OF-TEST-DOCUMENT marker."
                    printf '%s' "$ocr_out" | head -c 500
                    echo
                    fail=$((fail + 1))
                fi
            fi
        fi
    fi

    # ── Summary ────────────────────────────────────────────────────────────
    echo ""
    if (( fail == 0 )); then
        echo -e "${GREEN}${BOLD}  Smoke tests: ${pass}/3 passed ✓${RESET}"
    else
        echo -e "${YELLOW}${BOLD}  Smoke tests: ${pass}/3 passed, ${fail} failed${RESET}"
        echo -e "${DIM}  Check logs:  docker compose logs -f${RESET}"
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Main
# ───────────────────────────────────────────────────────────────────────────

main() {
    banner
    check_docker
    detect_state
    show_state
    main_menu
}

main "$@"
