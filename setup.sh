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

# ───────────────────────────────────────────────────────────────────────────
# Model defaults — two vLLM instances on the pinned 0.25.1 release
# (ARM64 + CUDA 13 for DGX Spark):
#   LLM: Qwen 3.6 35B MoE, NVIDIA NVFP4 pre-quantized checkpoint
#   OCR: dots.mocr document-parsing VLM, FP8 quant (vision unquantized)
# ───────────────────────────────────────────────────────────────────────────
DEFAULT_VLLM_IMAGE="vllm/vllm-openai:vllm-arm64-cu13-0.25.1-7a33ba9"
DEFAULT_HF_MODEL_ID="nvidia/Qwen3.6-35B-A3B-NVFP4"
DEFAULT_SERVED_MODEL_NAME="qwen3.6-35b"
# Note: prefix caching is explicitly disabled for the Qwen instance —
# it corrupts hybrid-attention state when combined with MTP speculative
# decoding on this vLLM release (vLLM issue #43559).
DEFAULT_VLLM_EXTRA_FLAGS="--no-enable-prefix-caching --reasoning-parser qwen3 --tool-call-parser qwen3_xml --enable-auto-tool-choice --attention-backend flashinfer --moe-backend marlin --enable-chunked-prefill --async-scheduling --load-format fastsafetensors"
DEFAULT_MOCR_MODEL_ID="binedge/dots.mocr-FP8"
DEFAULT_MOCR_SERVED_MODEL_NAME="dots-mocr"
# kv-cache-memory-bytes: fixed 8GB KV for the OCR instance — on unified
# memory a fractional gpu-memory-utilization budget is consumed by the
# LLM instance's allocation before this instance starts.
DEFAULT_MOCR_VLLM_EXTRA_FLAGS="--enable-prefix-caching --enable-chunked-prefill --chat-template-content-format string --kv-cache-memory-bytes 8589934592"

banner() {
    clear 2>/dev/null || true
    echo ""
    echo -e "${CYAN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${CYAN}${BOLD}║           DGX Spark Stack Setup                          ║${RESET}"
    echo -e "${CYAN}${BOLD}║           vLLM + OCR Service                             ║${RESET}"
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
    # printf -v assigns without eval, so quotes/$()/backticks in the
    # answer are stored literally instead of being executed.
    printf -v "$var" '%s' "${input:-$default}"
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
    MOCR_RUNNING=false
    OCR_RUNNING=false
    VLLM_EXISTS=false
    MOCR_EXISTS=false
    OCR_EXISTS=false

    [[ -f ".env" ]] && HAS_ENV=true

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vllm-server$'; then
        VLLM_RUNNING=true
        VLLM_EXISTS=true
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^vllm-server$'; then
        VLLM_EXISTS=true
    fi

    if docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mocr-server$'; then
        MOCR_RUNNING=true
        MOCR_EXISTS=true
    elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q '^mocr-server$'; then
        MOCR_EXISTS=true
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
        model=$(grep -E '^SERVED_MODEL_NAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '"' || true)
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

    if [[ "$MOCR_RUNNING" == true ]]; then
        printf "  %-20s ${GREEN}running${RESET}\n" "mocr-server:"
    elif [[ "$MOCR_EXISTS" == true ]]; then
        printf "  %-20s ${YELLOW}stopped${RESET}\n" "mocr-server:"
    else
        printf "  %-20s ${DIM}not present${RESET}\n" "mocr-server:"
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
    echo -e "  ${BOLD}8)${RESET} Install MindRouter ${DIM}— optional API gateway/load balancer fronting this stack${RESET}"
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
        8) action_install_mindrouter ;;
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

    if [[ "$VLLM_EXISTS" == true ]] || [[ "$MOCR_EXISTS" == true ]] || [[ "$OCR_EXISTS" == true ]] || [[ "$HAS_ENV" == true ]]; then
        warn "Existing installation detected."
        echo ""
        echo "Fresh install will:"
        [[ "$VLLM_RUNNING" == true || "$MOCR_RUNNING" == true || "$OCR_RUNNING" == true ]] && echo "  • Stop running containers"
        [[ "$VLLM_EXISTS" == true || "$MOCR_EXISTS" == true || "$OCR_EXISTS" == true ]] && echo "  • Remove existing containers"
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

    set_model_defaults
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
        confirm "Return to menu?" "y" && main_menu || true
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

    # Re-Install deploys straight from .env, so a migrated legacy config
    # must be written back before compose reads it.
    if [[ "$ENV_MIGRATED" == true ]]; then
        info "Writing migrated configuration back to .env"
        write_env
    fi

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
        confirm "Return to menu?" "y" && main_menu || true
        return
    fi

    info "Loading current settings from .env..."
    load_env_values
    echo ""

    echo "Model: ${SERVED_MODEL_NAME:-unknown} (${HF_MODEL_ID:-unknown})"
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
        confirm "Return to menu?" "y" && main_menu || true
        return
    fi

    # Make sure VLLM_PORT / OCR_PORT etc. are in the environment for the checks.
    load_env_values

    if [[ "$VLLM_RUNNING" != true ]] && [[ "$MOCR_RUNNING" != true ]] && [[ "$OCR_RUNNING" != true ]]; then
        error "None of vllm-server, mocr-server, or ocr-service is running."
        info  "Start the stack with Re-Install (option 2) or 'docker compose up -d'."
        echo ""
        confirm "Return to menu?" "y" && main_menu || true
        return
    fi

    # ── Container / port health ────────────────────────────────────────────
    echo -e "${BOLD}── Container health ──${RESET}"
    if [[ "$VLLM_RUNNING" == true ]]; then
        info "vllm-server is running"
    else
        error "vllm-server is NOT running"
    fi
    if [[ "$MOCR_RUNNING" == true ]]; then
        info "mocr-server is running"
    else
        error "mocr-server is NOT running"
    fi
    if [[ "$OCR_RUNNING" == true ]]; then
        info "ocr-service is running"
    else
        error "ocr-service is NOT running"
    fi

    echo ""
    echo -e "${BOLD}── HTTP health ──${RESET}"
    if curl -sf --max-time 5 "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
        info "LLM   /health  OK  (port ${VLLM_PORT})"
    else
        error "LLM   /health  failed  (port ${VLLM_PORT})"
    fi
    if curl -sf --max-time 5 "http://localhost:${MOCR_PORT}/health" &>/dev/null; then
        info "MOCR  /health  OK  (port ${MOCR_PORT})"
    else
        error "MOCR  /health  failed  (port ${MOCR_PORT})"
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
    confirm "Return to menu?" "y" && main_menu || true
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
        confirm "Return to menu?" "y" && main_menu || true
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
            confirm "Return to menu?" "y" && main_menu || true
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
            confirm "Return to menu?" "y" && main_menu || true
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
        confirm "Return to menu?" "y" && main_menu || true
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

    confirm "Return to menu?" "y" && main_menu || true
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Install MindRouter (optional)
# Installs github.com/ui-insight/mindrouter locally, registers this DGX as
# a node and both vLLM instances as backends. Details and idempotency live
# in mindrouter/install-mindrouter.sh.
# ───────────────────────────────────────────────────────────────────────────

action_install_mindrouter() {
    # $1 == "auto": invoked from the post-deploy opt-in, where the user has
    # already said yes — skip the inner confirmation and the menu return.
    local mode="${1:-menu}"
    echo ""
    step "Install MindRouter"
    echo ""
    echo "MindRouter is an LLM gateway/load balancer (github.com/ui-insight/mindrouter)"
    echo "with an OpenAI-compatible API, per-user API keys, quotas, fair-share"
    echo "scheduling, dashboards, and audit logging. This will:"
    echo ""
    echo "  • Clone and build MindRouter locally (first build takes a while)"
    echo "  • Run its gateway alongside this stack (default port 8080)"
    echo "  • Register this DGX as a node (with GPU telemetry sidecar)"
    echo "  • Register both vLLM instances as backends"
    echo "  • Smoke-test a routed chat and OCR request"
    echo ""

    if [[ "$mode" != "auto" ]]; then
        echo "Requires the dgx-stack to be deployed and healthy first."
        echo ""
        if ! confirm "Install MindRouter now?" "n"; then
            echo ""
            main_menu || true
            return
        fi
    fi

    # Offer a gateway port. The installer auto-selects a free port if left
    # blank; showing a concrete free default helps users who want to pick
    # deliberately (e.g. because Vandalizer already holds 8080).
    local mr_port_hint=8080
    if command -v ss >/dev/null 2>&1 && ss -Htln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]8080$"; then
        mr_port_hint=8090
        warn "Port 8080 is already in use — the installer will pick a free port (e.g. ${mr_port_hint})."
    fi
    local mr_port
    echo -ne "${BOLD}MindRouter gateway port${RESET} ${DIM}[blank = auto-select, e.g. ${mr_port_hint}]${RESET}: "
    read -r mr_port
    [[ -n "$mr_port" ]] && export MINDROUTER_PORT="$mr_port"

    if bash "${SCRIPT_DIR}/mindrouter/install-mindrouter.sh"; then
        info "MindRouter installation finished."
    else
        error "MindRouter installation failed — see output above."
        error "Re-running is safe: the installer is idempotent."
    fi
    echo ""
    if [[ "$mode" != "auto" ]]; then
        confirm "Return to menu?" "y" && main_menu || true
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Action: Turn Off
# ───────────────────────────────────────────────────────────────────────────

action_turn_off() {
    echo ""
    step "Turn Off"
    echo ""

    if [[ "$VLLM_RUNNING" != true ]] && [[ "$MOCR_RUNNING" != true ]] && [[ "$OCR_RUNNING" != true ]]; then
        info "No containers are currently running."
        echo ""
        confirm "Return to menu?" "y" && main_menu || true
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
    echo "  1) All services"
    echo "  2) LLM (vllm-server) only"
    echo "  3) OCR model (mocr-server) only"
    echo "  4) OCR service only"
    echo "  b) Back to menu"
    echo ""
    local choice
    ask "Select" "1" choice

    case "$choice" in
        1) docker compose logs --tail=200 -f ;;
        2) docker compose logs --tail=200 -f vllm ;;
        3) docker compose logs --tail=200 -f mocr ;;
        4) docker compose logs --tail=200 -f ocr ;;
        *) main_menu ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────
# Helpers: stop/remove containers, load existing env
# ───────────────────────────────────────────────────────────────────────────

stop_and_remove_containers() {
    if [[ "$VLLM_EXISTS" == true ]] || [[ "$MOCR_EXISTS" == true ]] || [[ "$OCR_EXISTS" == true ]]; then
        step "Stopping and removing existing containers..."
        docker compose down 2>/dev/null || {
            # Fallback if compose state is inconsistent
            docker rm -f vllm-server mocr-server ocr-service 2>/dev/null || true
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
        # Strip surrounding single or double quotes from value; for
        # unquoted values also strip inline comments and trailing
        # whitespace (matching Docker Compose's dotenv behavior).
        if [[ "$value" =~ ^\"([^\"]*)\" ]]; then
            value="${BASH_REMATCH[1]}"
        elif [[ "$value" =~ ^\'([^\']*)\' ]]; then
            value="${BASH_REMATCH[1]}"
        else
            value="${value%%[[:space:]]#*}"
            value="${value%"${value##*[![:space:]]}"}"
        fi
        # Only allow valid identifier keys; skip readonly names (UID,
        # EUID, …) that would abort the script under set -e.
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        printf -v "$key" '%s' "$value" 2>/dev/null || true
    done < .env

    # Set defaults for anything missing
    VLLM_IMAGE="${VLLM_IMAGE:-$DEFAULT_VLLM_IMAGE}"
    HF_MODEL_ID="${HF_MODEL_ID:-$DEFAULT_HF_MODEL_ID}"
    SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-$DEFAULT_SERVED_MODEL_NAME}"
    VLLM_EXTRA_FLAGS="${VLLM_EXTRA_FLAGS:-$DEFAULT_VLLM_EXTRA_FLAGS}"
    VLLM_SPECULATIVE_TOKENS="${VLLM_SPECULATIVE_TOKENS:-3}"
    VLLM_ENABLE_THINKING_DEFAULT="${VLLM_ENABLE_THINKING_DEFAULT:-false}"
    HF_TOKEN="${HF_TOKEN:-}"
    HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
    HF_OFFLINE="${HF_OFFLINE:-0}"
    VLLM_PORT="${VLLM_PORT:-8000}"
    OCR_PORT="${OCR_PORT:-8010}"
    DGX_NET_SUBNET="${DGX_NET_SUBNET:-10.10.99.0/24}"
    DGX_NET_GATEWAY="${DGX_NET_GATEWAY:-10.10.99.1}"
    GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.4}"
    MAX_MODEL_LEN="${MAX_MODEL_LEN:-262144}"
    MAX_NUM_SEQS="${MAX_NUM_SEQS:-12}"
    MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-8192}"
    KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"
    MOCR_MODEL_ID="${MOCR_MODEL_ID:-$DEFAULT_MOCR_MODEL_ID}"
    MOCR_SERVED_MODEL_NAME="${MOCR_SERVED_MODEL_NAME:-$DEFAULT_MOCR_SERVED_MODEL_NAME}"
    MOCR_VLLM_EXTRA_FLAGS="${MOCR_VLLM_EXTRA_FLAGS:-$DEFAULT_MOCR_VLLM_EXTRA_FLAGS}"
    MOCR_PORT="${MOCR_PORT:-8001}"
    MOCR_GPU_MEMORY_UTIL="${MOCR_GPU_MEMORY_UTIL:-0.10}"
    MOCR_MAX_MODEL_LEN="${MOCR_MAX_MODEL_LEN:-32768}"
    MOCR_MAX_NUM_SEQS="${MOCR_MAX_NUM_SEQS:-12}"
    MOCR_MAX_NUM_BATCHED_TOKENS="${MOCR_MAX_NUM_BATCHED_TOKENS:-16384}"
    MOCR_KV_CACHE_DTYPE="${MOCR_KV_CACHE_DTYPE:-auto}"
    OCR_DPI="${OCR_DPI:-200}"
    OCR_MAX_TOKENS="${OCR_MAX_TOKENS:-16384}"
    OCR_TEMPERATURE="${OCR_TEMPERATURE:-0.1}"
    OCR_TOP_P="${OCR_TOP_P:-0.9}"
    OCR_MAX_CONCURRENT_PAGES="${OCR_MAX_CONCURRENT_PAGES:-12}"
    OCR_MAX_RETRIES="${OCR_MAX_RETRIES:-2}"
    OCR_MAX_PAGES="${OCR_MAX_PAGES:-200}"
    OCR_MAX_FILE_SIZE_MB="${OCR_MAX_FILE_SIZE_MB:-100}"

    # Migrate pre-dots.mocr configs. Old .envs pin images/models that the
    # three-container stack cannot run: the mocr service would inherit a
    # pre-0.25.1 image with no dots_ocr support, and the entrypoint would
    # add an MTP speculative config to a model without an MTP head.
    ENV_MIGRATED=false
    case "${VLLM_IMAGE:-}" in
        *gemma4-cu130*|*cu130-nightly*)
            warn "Legacy model config detected in .env (model: ${SERVED_MODEL_NAME:-unknown})."
            warn "Resetting model, image, and serving flags to the current defaults."
            VLLM_IMAGE="$DEFAULT_VLLM_IMAGE"
            HF_MODEL_ID="$DEFAULT_HF_MODEL_ID"
            SERVED_MODEL_NAME="$DEFAULT_SERVED_MODEL_NAME"
            VLLM_EXTRA_FLAGS="$DEFAULT_VLLM_EXTRA_FLAGS"
            VLLM_ENABLE_THINKING_DEFAULT="false"
            VLLM_SPECULATIVE_TOKENS=3
            MAX_MODEL_LEN=262144
            GPU_MEMORY_UTIL=0.4
            ENV_MIGRATED=true
            ;;
    esac
}

# ───────────────────────────────────────────────────────────────────────────
# Model defaults
# ───────────────────────────────────────────────────────────────────────────

set_model_defaults() {
    echo -e "${BOLD}── Models ──${RESET}"
    echo ""
    echo -e "  ${BOLD}LLM: Qwen 3.6 35B NVFP4${RESET} ${DIM}(nvidia/Qwen3.6-35B-A3B-NVFP4)${RESET}"
    echo "     MoE 35B total / 3B active, NVFP4 ~23GB weights"
    echo "     262K context, MTP speculative decoding, port 8000"
    echo ""
    echo -e "  ${BOLD}OCR: dots.mocr FP8${RESET} ${DIM}(binedge/dots.mocr-FP8)${RESET}"
    echo "     ~3B document-parsing VLM, FP8 ~5GB weights"
    echo "     Vision tower unquantized, port 8001"
    echo ""
    echo "  Both are open access — no HuggingFace token required."
    echo ""

    VLLM_IMAGE="$DEFAULT_VLLM_IMAGE"
    HF_MODEL_ID="$DEFAULT_HF_MODEL_ID"
    SERVED_MODEL_NAME="$DEFAULT_SERVED_MODEL_NAME"
    VLLM_EXTRA_FLAGS="$DEFAULT_VLLM_EXTRA_FLAGS"
    VLLM_SPECULATIVE_TOKENS="${VLLM_SPECULATIVE_TOKENS:-3}"
    # Serve-time default for the chat template: thinking OFF unless a
    # request opts in with chat_template_kwargs.enable_thinking=true.
    # Setting an explicit default is what makes per-request overrides
    # take effect with --reasoning-parser qwen3.
    VLLM_ENABLE_THINKING_DEFAULT="false"

    MOCR_MODEL_ID="$DEFAULT_MOCR_MODEL_ID"
    MOCR_SERVED_MODEL_NAME="$DEFAULT_MOCR_SERVED_MODEL_NAME"
    MOCR_VLLM_EXTRA_FLAGS="$DEFAULT_MOCR_VLLM_EXTRA_FLAGS"

    # Defaults for values that configure_interactive does not prompt for —
    # on Fresh Install (no .env, load_env_values never runs) write_env
    # would otherwise hit unbound variables under set -u.
    MOCR_MAX_MODEL_LEN="${MOCR_MAX_MODEL_LEN:-32768}"
    MOCR_MAX_NUM_SEQS="${MOCR_MAX_NUM_SEQS:-12}"
    MOCR_MAX_NUM_BATCHED_TOKENS="${MOCR_MAX_NUM_BATCHED_TOKENS:-16384}"
    MOCR_KV_CACHE_DTYPE="${MOCR_KV_CACHE_DTYPE:-auto}"
    OCR_TEMPERATURE="${OCR_TEMPERATURE:-0.1}"
    OCR_TOP_P="${OCR_TOP_P:-0.9}"
    OCR_MAX_RETRIES="${OCR_MAX_RETRIES:-2}"
}

# ───────────────────────────────────────────────────────────────────────────
# Interactive configuration
# ───────────────────────────────────────────────────────────────────────────

configure_interactive() {
    # ── HuggingFace Token ──
    echo -e "${BOLD}── HuggingFace Token ──${RESET}"
    echo "The NVFP4 checkpoint is open access. Token is optional."
    echo ""

    local hf_default="${HF_TOKEN:-}"
    if [[ -z "$hf_default" ]] && [[ -f "$HOME/.cache/huggingface/token" ]]; then
        hf_default=$(cat "$HOME/.cache/huggingface/token" 2>/dev/null || true)
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
    echo ""

    # ── Ports ──
    echo -e "${BOLD}── Network Ports ──${RESET}"
    ask "LLM API port (Qwen, OpenAI-compatible)" "${VLLM_PORT:-8000}" VLLM_PORT
    ask "OCR model port (dots.mocr, OpenAI-compatible)" "${MOCR_PORT:-8001}" MOCR_PORT
    ask "OCR service port" "${OCR_PORT:-8010}" OCR_PORT
    if [[ "$VLLM_PORT" == "$MOCR_PORT" ]] || [[ "$VLLM_PORT" == "$OCR_PORT" ]] || [[ "$MOCR_PORT" == "$OCR_PORT" ]]; then
        error "The three ports must be distinct (got LLM=$VLLM_PORT, OCR model=$MOCR_PORT, OCR service=$OCR_PORT)."
        exit 1
    fi
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
    echo "DGX Spark has 128GB unified memory shared between CPU, GPU, and"
    echo "BOTH vLLM instances. Defaults: Qwen 0.4 (~51GB, NVIDIA's Spark"
    echo "recommendation for this checkpoint) + dots.mocr 0.10 (~13GB)."
    echo "That leaves ~64GB for the OS and the OCR service container."
    echo ""
    ask "LLM (Qwen) GPU memory utilization (0.30 - 0.80)" "${GPU_MEMORY_UTIL:-0.4}" GPU_MEMORY_UTIL
    ask "OCR (dots.mocr) GPU memory utilization (0.05 - 0.20)" "${MOCR_GPU_MEMORY_UTIL:-0.10}" MOCR_GPU_MEMORY_UTIL
    echo ""

    if (( $(echo "$GPU_MEMORY_UTIL < 0.3" | bc -l 2>/dev/null || echo 0) )) || \
       (( $(echo "$GPU_MEMORY_UTIL > 0.8" | bc -l 2>/dev/null || echo 0) )); then
        warn "Unusual value: $GPU_MEMORY_UTIL. Recommended range is 0.30 - 0.80."
        if ! confirm "Continue with this value?" "n"; then
            exit 1
        fi
    fi

    # Warn when the two instances together claim most of unified memory.
    local total_util
    total_util="$(echo "$GPU_MEMORY_UTIL + $MOCR_GPU_MEMORY_UTIL" | bc -l 2>/dev/null || echo 0)"
    if (( $(echo "$total_util > 0.85" | bc -l 2>/dev/null || echo 0) )); then
        warn "Combined GPU memory utilization is ${total_util} of 128GB —"
        warn "this can starve the OS and OCR container on unified memory."
        if ! confirm "Continue with these values?" "n"; then
            exit 1
        fi
    fi

    # ── Model Config ──
    echo -e "${BOLD}── Model Configuration ──${RESET}"
    ask "Max context length (tokens)" "${MAX_MODEL_LEN:-262144}" MAX_MODEL_LEN
    ask "Max concurrent sequences" "${MAX_NUM_SEQS:-12}" MAX_NUM_SEQS
    ask "Max batched tokens (required ≥ Mamba block size for Qwen)" "${MAX_NUM_BATCHED_TOKENS:-8192}" MAX_NUM_BATCHED_TOKENS
    ask "Speculative decode tokens (MTP draft length, 0 = off)" "${VLLM_SPECULATIVE_TOKENS:-3}" VLLM_SPECULATIVE_TOKENS
    echo ""

    # ── KV Cache ──
    echo -e "${BOLD}── KV Cache ──${RESET}"
    echo "auto (BF16) is the stable default. fp8 doubles KV capacity but has"
    echo "caused intermittent CUDA illegal-memory crashes under mixed load on"
    echo "SM12.1. The dots.mocr instance always uses auto."
    echo ""
    ask "Qwen KV cache dtype (auto or fp8)" "${KV_CACHE_DTYPE:-auto}" KV_CACHE_DTYPE
    echo ""

    # ── HuggingFace Cache ──
    echo -e "${BOLD}── Storage ──${RESET}"
    echo "Model weights (~23GB Qwen NVFP4 + ~5GB dots.mocr FP8) are cached"
    echo "locally to avoid re-downloading."
    ask "HuggingFace cache directory" "${HF_CACHE:-$HOME/.cache/huggingface}" HF_CACHE
    echo ""

    # ── OCR Tuning ──
    echo -e "${BOLD}── OCR Settings ──${RESET}"
    echo -e "${DIM}dots.mocr processes one page per request; pages run in parallel.${RESET}"
    ask "PDF rendering DPI (200 recommended by dots.mocr)" "${OCR_DPI:-200}" OCR_DPI
    ask "Max tokens per page response" "${OCR_MAX_TOKENS:-16384}" OCR_MAX_TOKENS
    ask "Max concurrent pages" "${OCR_MAX_CONCURRENT_PAGES:-12}" OCR_MAX_CONCURRENT_PAGES
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
    printf "  %-30s %s\n" "LLM model:" "${SERVED_MODEL_NAME} (${HF_MODEL_ID})"
    printf "  %-30s %s\n" "OCR model:" "${MOCR_SERVED_MODEL_NAME} (${MOCR_MODEL_ID})"
    printf "  %-30s %s\n" "Container:" "${VLLM_IMAGE}"
    printf "  %-30s %s\n" "LLM port:" "$VLLM_PORT"
    printf "  %-30s %s\n" "OCR model port:" "$MOCR_PORT"
    printf "  %-30s %s\n" "OCR service port:" "$OCR_PORT"
    printf "  %-30s %s\n" "LLM GPU memory util:" "$GPU_MEMORY_UTIL ($(echo "$GPU_MEMORY_UTIL * 128" | bc 2>/dev/null || echo "?")GB of 128GB)"
    printf "  %-30s %s\n" "OCR GPU memory util:" "$MOCR_GPU_MEMORY_UTIL ($(echo "$MOCR_GPU_MEMORY_UTIL * 128" | bc 2>/dev/null || echo "?")GB of 128GB)"
    printf "  %-30s %s\n" "Max context length (LLM):" "$MAX_MODEL_LEN tokens"
    printf "  %-30s %s\n" "Max concurrent sequences:" "$MAX_NUM_SEQS"
    printf "  %-30s %s\n" "Speculative tokens (MTP):" "${VLLM_SPECULATIVE_TOKENS:-3}"
    printf "  %-30s %s\n" "KV cache dtype (LLM):" "$KV_CACHE_DTYPE"
    printf "  %-30s %s\n" "HF cache:" "$HF_CACHE"
    printf "  %-30s %s\n" "OCR DPI:" "$OCR_DPI"
    printf "  %-30s %s\n" "OCR max tokens/page:" "$OCR_MAX_TOKENS"
    printf "  %-30s %s\n" "OCR concurrent pages:" "$OCR_MAX_CONCURRENT_PAGES"
    if [[ -n "$VLLM_EXTRA_FLAGS" ]]; then
        printf "  %-30s %s\n" "Extra vLLM flags (LLM):" "$VLLM_EXTRA_FLAGS"
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
# Model: ${SERVED_MODEL_NAME}
# ─────────────────────────────────────────────

# LLM (Qwen 3.6 NVFP4)
VLLM_IMAGE="${VLLM_IMAGE}"
HF_MODEL_ID="${HF_MODEL_ID}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME}"
VLLM_EXTRA_FLAGS="${VLLM_EXTRA_FLAGS}"

# OCR model (dots.mocr)
MOCR_MODEL_ID="${MOCR_MODEL_ID}"
MOCR_SERVED_MODEL_NAME="${MOCR_SERVED_MODEL_NAME}"
MOCR_VLLM_EXTRA_FLAGS="${MOCR_VLLM_EXTRA_FLAGS}"
MOCR_PORT=${MOCR_PORT}
MOCR_GPU_MEMORY_UTIL=${MOCR_GPU_MEMORY_UTIL}
MOCR_MAX_MODEL_LEN=${MOCR_MAX_MODEL_LEN}
MOCR_MAX_NUM_SEQS=${MOCR_MAX_NUM_SEQS}
MOCR_MAX_NUM_BATCHED_TOKENS=${MOCR_MAX_NUM_BATCHED_TOKENS}
MOCR_KV_CACHE_DTYPE=${MOCR_KV_CACHE_DTYPE}

# HuggingFace
HF_TOKEN="${HF_TOKEN}"
HF_CACHE="${HF_CACHE}"
HF_OFFLINE=${HF_OFFLINE}

# Network
VLLM_PORT=${VLLM_PORT}
OCR_PORT=${OCR_PORT}
DGX_NET_SUBNET=${DGX_NET_SUBNET}
DGX_NET_GATEWAY=${DGX_NET_GATEWAY}

# GPU / Model (LLM)
GPU_MEMORY_UTIL=${GPU_MEMORY_UTIL}
MAX_MODEL_LEN=${MAX_MODEL_LEN}
MAX_NUM_SEQS=${MAX_NUM_SEQS}
KV_CACHE_DTYPE=${KV_CACHE_DTYPE}
MAX_NUM_BATCHED_TOKENS=${MAX_NUM_BATCHED_TOKENS}
VLLM_SPECULATIVE_TOKENS=${VLLM_SPECULATIVE_TOKENS}
VLLM_ENABLE_THINKING_DEFAULT=${VLLM_ENABLE_THINKING_DEFAULT}

# OCR service
OCR_DPI=${OCR_DPI}
OCR_MAX_TOKENS=${OCR_MAX_TOKENS}
OCR_TEMPERATURE=${OCR_TEMPERATURE}
OCR_TOP_P=${OCR_TOP_P}
OCR_MAX_CONCURRENT_PAGES=${OCR_MAX_CONCURRENT_PAGES}
OCR_MAX_RETRIES=${OCR_MAX_RETRIES}
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
    echo ""
    echo -e "  ${YELLOW}${BOLD}NOTE: Loading the model into GPU memory can take 5+ minutes.${RESET}"
    echo -e "  ${YELLOW}${BOLD}      Please be patient — the health check will wait.${RESET}"
    echo ""
    docker compose up -d

    echo ""
    step "Waiting for both vLLM instances to load their models..."
    info "Qwen 3.6 35B NVFP4 is ~23GB; dots.mocr FP8 is ~5GB."
    info "First request to each may take ~60s to warm up."
    echo ""
    echo -e "${DIM}  Watch progress:  docker compose logs -f vllm mocr${RESET}"
    echo -e "${DIM}  Check health:    curl http://localhost:${VLLM_PORT}/health${RESET}"
    echo -e "${DIM}                   curl http://localhost:${MOCR_PORT:-8001}/health${RESET}"
    echo ""

    local max_wait=600
    local elapsed=0
    local interval=10
    local vllm_up=false mocr_up=false

    while (( elapsed < max_wait )); do
        if [[ "$vllm_up" != true ]] && curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
            vllm_up=true
            echo ""
            info "vllm-server (LLM) is healthy and serving."
        fi
        if [[ "$mocr_up" != true ]] && curl -sf "http://localhost:${MOCR_PORT:-8001}/health" &>/dev/null; then
            mocr_up=true
            echo ""
            info "mocr-server (OCR model) is healthy and serving."
        fi
        if [[ "$vllm_up" == true ]] && [[ "$mocr_up" == true ]]; then
            break
        fi
        # Check whether either container crashed
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^vllm-server$'; then
            echo ""
            error "vllm-server container is no longer running."
            error "Check logs: docker compose logs vllm"
            return
        fi
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^mocr-server$'; then
            echo ""
            error "mocr-server container is no longer running."
            error "Check logs: docker compose logs mocr"
            return
        fi
        echo -ne "\r  Waiting... ${elapsed}s / ${max_wait}s  (LLM: ${vllm_up}, OCR model: ${mocr_up})"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if [[ "$vllm_up" != true ]] || [[ "$mocr_up" != true ]]; then
        echo ""
        warn "Not all instances became healthy after ${max_wait}s (LLM: ${vllm_up}, OCR model: ${mocr_up})."
        warn "Check logs: docker compose logs vllm mocr"
        warn "The services may still be loading. Healthchecks will restart them if needed."
        return
    fi

    run_smoke_tests

    echo ""
    echo -e "${GREEN}${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${GREEN}${BOLD}║  Stack is running!                                       ║${RESET}"
    echo -e "${GREEN}${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  LLM model: ${SERVED_MODEL_NAME}    OCR model: ${MOCR_SERVED_MODEL_NAME:-dots-mocr}"
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

    # Optional add-on: MindRouter gateway fronting the freshly deployed stack.
    if confirm "Also install MindRouter (optional API gateway/load balancer)?" "n"; then
        action_install_mindrouter auto
    fi
}

# ───────────────────────────────────────────────────────────────────────────
# Smoke tests — exercise both vLLM instances and the OCR pipeline against
# the committed examples/test-doc.pdf after a successful deploy:
#   1. LLM  /v1/models          (served id matches config)
#   2. OCR  /v1/models          (served id matches config)
#   3. LLM  chat completion     (real answer in content)
#   4. dots.mocr direct         (page 1 → layout JSON → markdown, in-container)
#   5. OCR  /v1/ocr JSON        (3 pages, sentinel, table-fidelity assertions)
#   6. OCR  /v1/ocrmd           (raw markdown + sentinel)
# followed by a unified-memory usage report.
# ───────────────────────────────────────────────────────────────────────────

run_smoke_tests() {
    echo ""
    if ! confirm "Run end-to-end smoke tests now?" "y"; then
        return
    fi

    local pass=0 fail=0
    local chat_url="http://localhost:${VLLM_PORT}"
    local mocr_url="http://localhost:${MOCR_PORT:-8001}"
    local ocr_url="http://localhost:${OCR_PORT}"
    local test_pdf="${SCRIPT_DIR}/examples/test-doc.pdf"

    # ── Test 1: LLM /v1/models ─────────────────────────────────────────────
    echo ""
    step "Test 1/6 — GET ${chat_url}/v1/models  (LLM)"
    local models_json served_id
    models_json="$(curl -sf --max-time 15 "${chat_url}/v1/models" 2>/dev/null || true)"
    if [[ -n "$models_json" ]]; then
        served_id="$(printf '%s' "$models_json" \
            | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["data"][0]["id"])' 2>/dev/null || true)"
        if [[ -n "$served_id" ]]; then
            info "LLM served model id: ${BOLD}${served_id}${RESET}"
            pass=$((pass + 1))
        else
            error "Could not parse model id from response."
            echo "$models_json" | head -c 400
            echo
            fail=$((fail + 1))
        fi
    else
        error "Request to LLM /v1/models failed."
        fail=$((fail + 1))
    fi

    # ── Test 2: OCR model /v1/models ───────────────────────────────────────
    echo ""
    step "Test 2/6 — GET ${mocr_url}/v1/models  (OCR model)"
    local mocr_models_json mocr_served_id
    mocr_models_json="$(curl -sf --max-time 15 "${mocr_url}/v1/models" 2>/dev/null || true)"
    if [[ -n "$mocr_models_json" ]]; then
        mocr_served_id="$(printf '%s' "$mocr_models_json" \
            | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["data"][0]["id"])' 2>/dev/null || true)"
        if [[ -n "$mocr_served_id" ]]; then
            info "OCR served model id: ${BOLD}${mocr_served_id}${RESET}"
            pass=$((pass + 1))
        else
            error "Could not parse model id from response."
            echo "$mocr_models_json" | head -c 400
            echo
            fail=$((fail + 1))
        fi
    else
        error "Request to OCR model /v1/models failed."
        fail=$((fail + 1))
    fi

    # ── Test 3: LLM chat completion ────────────────────────────────────────
    echo ""
    step "Test 3/6 — POST ${chat_url}/v1/chat/completions  (LLM)"
    if [[ -n "${served_id:-}" ]]; then
        # Reasoning models (Qwen with --reasoning-parser qwen3) split
        # output into reasoning_content + content. Ask for enough tokens to
        # finish thinking *and* produce a final answer, and tell the template
        # not to emit a thinking block so the request returns fast without
        # burning tokens on a <think> block. The per-request override works
        # because VLLM_ENABLE_THINKING_DEFAULT is plumbed through at serve
        # time (--default-chat-template-kwargs).
        local chat_body chat_resp http_code chat_content reasoning_content
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
            -d "$chat_body" 2>/dev/null || true)"
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

    # ── Test 4: dots.mocr direct (in-container, exercises the exact
    #    client code path: prompt, placeholder, JSON→markdown) ─────────────
    echo ""
    step "Test 4/6 — dots.mocr direct page OCR (via ocr-service container)"
    if [[ ! -f "$test_pdf" ]]; then
        warn "Test PDF not found at ${test_pdf} — skipping."
        fail=$((fail + 1))
    else
        local direct_out
        direct_out="$(docker exec -i ocr-service python3 -c '
import json, sys
import httpx
from pdf2image import convert_from_bytes
from app.main import (DOTS_LAYOUT_PROMPT, IMG_PLACEHOLDER, MAX_TOKENS,
                      TEMPERATURE, TOP_P, VLLM_BASE_URL, VLLM_MODEL,
                      _image_to_b64, layout_json_to_markdown)

pdf = sys.stdin.buffer.read()
page = convert_from_bytes(pdf, dpi=200, first_page=1, last_page=1)[0]
payload = {
    "model": VLLM_MODEL,
    "messages": [{"role": "user", "content": [
        {"type": "image_url",
         "image_url": {"url": "data:image/png;base64," + _image_to_b64(page)}},
        {"type": "text", "text": IMG_PLACEHOLDER + DOTS_LAYOUT_PROMPT},
    ]}],
    "max_tokens": MAX_TOKENS, "temperature": TEMPERATURE, "top_p": TOP_P,
}
out = {"status": 0, "raw_chars": 0, "md_chars": 0, "json_ok": False, "has_title": False}
try:
    r = httpx.post(VLLM_BASE_URL + "/v1/chat/completions", json=payload, timeout=600)
    out["status"] = r.status_code
    raw = (r.json()["choices"][0]["message"]["content"] or "")
    out["raw_chars"] = len(raw)
    md = layout_json_to_markdown(raw)
    out["json_ok"] = True
    out["md_chars"] = len(md)
    out["has_title"] = "DGX Stack OCR Test Document" in md
except Exception as e:
    out["error"] = str(e)[:300]
print(json.dumps(out))
' < "$test_pdf" 2>/dev/null || echo '{"status":0,"error":"docker exec failed"}')"
        local direct_verdict
        direct_verdict="$(printf '%s' "$direct_out" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read().strip().splitlines()[-1])
except Exception:
    print("FAIL|unparseable test output"); raise SystemExit
if d.get("status") == 200 and d.get("json_ok") and d.get("has_title"):
    print("PASS|status=200 layout JSON parsed, %d md chars, page title found" % d.get("md_chars", 0))
elif d.get("status") == 200 and d.get("json_ok"):
    print("WARN|layout parsed (%d md chars) but page title missing" % d.get("md_chars", 0))
else:
    print("FAIL|" + json.dumps(d)[:300])
' 2>/dev/null || echo 'FAIL|verdict parse error')"
        case "$direct_verdict" in
            PASS\|*)
                info "dots.mocr direct OCR: ${direct_verdict#PASS|}"
                pass=$((pass + 1)) ;;
            WARN\|*)
                warn "dots.mocr direct OCR: ${direct_verdict#WARN|}"
                pass=$((pass + 1)) ;;
            *)
                error "dots.mocr direct OCR failed: ${direct_verdict#FAIL|}"
                fail=$((fail + 1)) ;;
        esac
    fi

    # ── Tests 5+6: OCR service end-to-end ──────────────────────────────────
    echo ""
    step "Test 5/6 — POST ${ocr_url}/v1/ocr  (JSON + table fidelity)"
    if [[ ! -f "$test_pdf" ]]; then
        warn "Test PDF not found at ${test_pdf} — skipping tests 5 and 6."
        fail=$((fail + 2))
    else
        # Preflight: is the OCR container actually up, and is /health reachable?
        local ocr_container_state ocr_health_code
        ocr_container_state="$(docker inspect -f '{{.State.Status}}' ocr-service 2>/dev/null || echo 'missing')"
        if [[ "$ocr_container_state" != "running" ]]; then
            error "ocr-service container is not running (state: ${ocr_container_state})."
            info  "Recent logs (last 30 lines):"
            docker logs --tail 30 ocr-service 2>&1 | sed 's/^/    /' || true
            fail=$((fail + 2))
        else
            local ocr_ready=false
            for _ in 1 2 3 4 5 6; do
                # curl -w writes %{http_code} to stdout even on connection
                # failure (it writes "000"), so do NOT add `|| echo 000` —
                # that would concatenate two copies of the failure code.
                ocr_health_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
                    "${ocr_url}/health" 2>/dev/null || true)"
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
                fail=$((fail + 2))
            else
                info "OCR /health OK — uploading test PDF (3 pages, JSON endpoint)..."
                local json_tmp json_code
                json_tmp="$(mktemp)"
                json_code="$(curl -s -o "$json_tmp" -w '%{http_code}' --max-time 900 \
                    -X POST "${ocr_url}/v1/ocr" \
                    -F "file=@${test_pdf}" 2>/dev/null || true)"
                [[ -z "$json_code" ]] && json_code="000"

                if [[ "$json_code" != "200" ]]; then
                    error "OCR /v1/ocr HTTP ${json_code}."
                    head -c 500 "$json_tmp"
                    echo
                    fail=$((fail + 1))
                else
                    # Content assertions: page count, sentinel, and table
                    # fidelity (all 6 column headers + key cell values from
                    # page 2 — catches merged-column table regressions).
                    local ocr_verdict
                    ocr_verdict="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
content = d.get("content", "")
checks = {
    "pages==3": d.get("pages") == 3,
    "sentinel": "END-OF-TEST-DOCUMENT" in content,
    "title": "DGX Stack OCR Test Document" in content,
}
for header in ["Model", "Params", "Active", "Weights", "Context", "Tok/s"]:
    checks["col:" + header] = header in content
for cell in ["Qwen 3.6 35B", "23 GB (NVFP4)", "58.2", "71.3", "Llama 3.1 70B", "94.6"]:
    checks["cell:" + cell] = cell in content
failed = [k for k, v in checks.items() if not v]
if failed:
    print("FAIL|" + ",".join(failed) + "|%d chars" % len(content))
else:
    print("PASS|%d pages, %d chars, table intact" % (d.get("pages", 0), len(content)))
' "$json_tmp" 2>/dev/null || echo 'FAIL|response parse error|')"
                    case "$ocr_verdict" in
                        PASS\|*)
                            info "OCR JSON: ${ocr_verdict#PASS|}"
                            pass=$((pass + 1)) ;;
                        *)
                            error "OCR JSON content checks failed: ${ocr_verdict#FAIL|}"
                            warn  "Failed checks often mean table columns were merged or pages dropped."
                            fail=$((fail + 1)) ;;
                    esac
                fi
                rm -f "$json_tmp"

                # ── Test 6: raw markdown endpoint ──────────────────────────
                echo ""
                step "Test 6/6 — POST ${ocr_url}/v1/ocrmd  (raw markdown)"
                local ocr_tmp ocr_code
                ocr_tmp="$(mktemp)"
                ocr_code="$(curl -s -o "$ocr_tmp" -w '%{http_code}' --max-time 900 \
                    -X POST "${ocr_url}/v1/ocrmd" \
                    -F "file=@${test_pdf}" 2>/dev/null || true)"
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
                    echo ""
                    echo -e "${DIM}    ── OCR markdown output ─────────────────────────────────${RESET}"
                    printf '%s\n' "$ocr_out" | sed 's/^/    /'
                    echo -e "${DIM}    ────────────────────────────────────────────────────────${RESET}"
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

    # ── Memory report ──────────────────────────────────────────────────────
    echo ""
    echo -e "${BOLD}── Unified memory usage ──${RESET}"
    free -g 2>/dev/null | sed 's/^/  /' || vm_stat 2>/dev/null | head -5 | sed 's/^/  /' || true
    docker stats --no-stream --format '  {{.Name}}: {{.MemUsage}}' \
        vllm-server mocr-server ocr-service 2>/dev/null || true

    # ── Summary ────────────────────────────────────────────────────────────
    echo ""
    if (( fail == 0 )); then
        echo -e "${GREEN}${BOLD}  Smoke tests: ${pass}/6 passed ✓${RESET}"
    else
        echo -e "${YELLOW}${BOLD}  Smoke tests: ${pass}/6 passed, ${fail} failed${RESET}"
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
