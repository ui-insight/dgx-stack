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
    echo -e "  ${BOLD}4)${RESET} Turn Off          ${DIM}— stop all containers${RESET}"
    echo -e "  ${BOLD}5)${RESET} View Logs         ${DIM}— tail container logs${RESET}"
    echo -e "  ${BOLD}q)${RESET} Quit"
    echo ""

    local choice
    echo -ne "${BOLD}Select an option${RESET}: "
    read -r choice

    case "$choice" in
        1) action_fresh_install ;;
        2) action_reinstall ;;
        3) action_repair ;;
        4) action_turn_off ;;
        5) action_view_logs ;;
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
    HF_TOKEN="${HF_TOKEN:-}"
    HF_CACHE="${HF_CACHE:-$HOME/.cache/huggingface}"
    VLLM_PORT="${VLLM_PORT:-8000}"
    OCR_PORT="${OCR_PORT:-8001}"
    GPU_MEMORY_UTIL="${GPU_MEMORY_UTIL:-0.75}"
    MAX_MODEL_LEN="${MAX_MODEL_LEN:-131072}"
    MAX_NUM_SEQS="${MAX_NUM_SEQS:-4}"
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
        DEFAULT_GPU_MEMORY_UTIL="0.75"
        DEFAULT_KV_CACHE_DTYPE="fp8"
    else
        MODEL_CHOICE="qwen35"
        NEEDS_HF_TOKEN=false
        DEFAULT_MAX_MODEL_LEN="131072"
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
            DEFAULT_GPU_MEMORY_UTIL="0.75"
            DEFAULT_KV_CACHE_DTYPE="fp8"
            VLLM_EXTRA_FLAGS=""
            VLLM_TEST_FORCE_FP8_MARLIN=0
            VLLM_USE_DEEP_GEMM=1
            NEEDS_HF_TOKEN=true
            info "Selected: Gemma 4 26B"
            ;;
        2)
            MODEL_CHOICE="qwen35"
            VLLM_IMAGE="vllm/vllm-openai:cu130-nightly"
            HF_MODEL_ID="Qwen/Qwen3.5-35B-A3B-FP8"
            SERVED_MODEL_NAME="qwen3.5-35b"
            DEFAULT_MAX_MODEL_LEN="131072"
            DEFAULT_GPU_MEMORY_UTIL="0.75"
            DEFAULT_KV_CACHE_DTYPE="fp8"
            VLLM_EXTRA_FLAGS="--enable-prefix-caching --reasoning-parser deepseek_r1 --max-num-batched-tokens 8192"
            VLLM_TEST_FORCE_FP8_MARLIN=1
            VLLM_USE_DEEP_GEMM=0
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

# GPU / Model
GPU_MEMORY_UTIL=${GPU_MEMORY_UTIL}
MAX_MODEL_LEN=${MAX_MODEL_LEN}
MAX_NUM_SEQS=${MAX_NUM_SEQS}
KV_CACHE_DTYPE=${KV_CACHE_DTYPE}
VLLM_TEST_FORCE_FP8_MARLIN=${VLLM_TEST_FORCE_FP8_MARLIN}
VLLM_USE_DEEP_GEMM=${VLLM_USE_DEEP_GEMM}

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
