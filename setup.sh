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
RESET='\033[0m'

banner() {
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

# ───────────────────────────────────────────────────────────────────────────
# Preflight checks
# ───────────────────────────────────────────────────────────────────────────

preflight() {
    info "Running preflight checks..."
    local ok=true

    if ! command -v docker &>/dev/null; then
        error "Docker is not installed. Install Docker Engine first."
        ok=false
    fi

    if ! docker compose version &>/dev/null 2>&1; then
        error "Docker Compose v2 is not available. Install the compose plugin."
        ok=false
    fi

    if ! docker info 2>/dev/null | grep -qi "nvidia\|gpu"; then
        warn "NVIDIA Container Toolkit may not be installed."
        warn "GPU containers require: https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/"
        echo ""
        echo -ne "${BOLD}Continue anyway? [y/N]${RESET}: "
        read -r yn
        if [[ ! "$yn" =~ ^[Yy]$ ]]; then
            echo "Aborting."
            exit 1
        fi
    fi

    if [[ "$ok" == false ]]; then
        error "Preflight checks failed. Fix the issues above and re-run."
        exit 1
    fi

    info "Preflight checks passed."
    echo ""
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
            VLLM_EXTRA_FLAGS="--enable-prefix-caching --reasoning-parser qwen3 --max-num-batched-tokens 8192"
            VLLM_TEST_FORCE_FP8_MARLIN=1
            VLLM_USE_DEEP_GEMM=0
            NEEDS_HF_TOKEN=false
            info "Selected: Qwen 3.5 35B (FP8 pre-quantized)"
            info "FP8 weights ~35GB — leaves ~61GB for KV cache at 0.75 util."
            ;;
        *)
            error "Invalid choice. Please enter 1 or 2."
            exit 1
            ;;
    esac
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Configuration prompts
# ───────────────────────────────────────────────────────────────────────────

configure() {
    # ── HuggingFace Token ──
    if [[ "$NEEDS_HF_TOKEN" == true ]]; then
        echo -e "${BOLD}── HuggingFace Token ──${RESET}"
        echo "Gemma 4 is a gated model. You need a HuggingFace token with access."
        echo "Get one at: https://huggingface.co/settings/tokens"
        echo "Accept the license at: https://huggingface.co/google/gemma-4-26B-A4B-it"
        echo ""

        local hf_default=""
        if [[ -n "${HF_TOKEN:-}" ]]; then
            hf_default="$HF_TOKEN"
            info "Found HF_TOKEN in environment."
        elif [[ -f "$HOME/.cache/huggingface/token" ]]; then
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
        echo "Qwen 3.5 is open access. A token is optional but recommended"
        echo "for faster downloads from HuggingFace."
        echo ""

        local hf_default=""
        if [[ -n "${HF_TOKEN:-}" ]]; then
            hf_default="$HF_TOKEN"
        elif [[ -f "$HOME/.cache/huggingface/token" ]]; then
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
    ask "vLLM API port (OpenAI-compatible)" "8000" VLLM_PORT
    ask "OCR service port" "8001" OCR_PORT
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
    ask "GPU memory utilization (0.5 - 0.90)" "$DEFAULT_GPU_MEMORY_UTIL" GPU_MEMORY_UTIL
    echo ""

    if (( $(echo "$GPU_MEMORY_UTIL < 0.5" | bc -l 2>/dev/null || echo 0) )) || \
       (( $(echo "$GPU_MEMORY_UTIL > 0.95" | bc -l 2>/dev/null || echo 0) )); then
        warn "Unusual value: $GPU_MEMORY_UTIL. Recommended range is 0.60 - 0.85."
        echo -ne "${BOLD}Continue with this value? [y/N]${RESET}: "
        read -r yn
        if [[ ! "$yn" =~ ^[Yy]$ ]]; then
            echo "Aborting."
            exit 1
        fi
    fi

    # ── Model Config ──
    echo -e "${BOLD}── Model Configuration ──${RESET}"
    ask "Max context length (tokens)" "$DEFAULT_MAX_MODEL_LEN" MAX_MODEL_LEN
    ask "Max concurrent sequences" "4" MAX_NUM_SEQS
    echo ""

    # ── KV Cache ──
    echo -e "${BOLD}── KV Cache ──${RESET}"
    echo "FP8 KV cache saves memory but may cause FlashInfer errors on some builds."
    echo "Use 'auto' (BF16) as a fallback if you see CUDA stream capture errors."
    echo ""
    ask "KV cache dtype (fp8 or auto)" "$DEFAULT_KV_CACHE_DTYPE" KV_CACHE_DTYPE
    echo ""

    # ── HuggingFace Cache ──
    echo -e "${BOLD}── Storage ──${RESET}"
    if [[ "$MODEL_CHOICE" == "qwen35" ]]; then
        echo "Model weights (~35GB FP8) are cached locally to avoid re-downloading."
    else
        echo "Model weights (~52GB) are cached locally to avoid re-downloading."
    fi
    ask "HuggingFace cache directory" "$HOME/.cache/huggingface" HF_CACHE
    echo ""

    # ── OCR Tuning ──
    echo -e "${BOLD}── OCR Settings ──${RESET}"
    echo -e "${DIM}These control how documents are split and processed.${RESET}"
    ask "Pages per chunk" "6" OCR_CHUNK_SIZE
    ask "Overlap pages between chunks" "2" OCR_OVERLAP
    ask "PDF rendering DPI" "200" OCR_DPI
    ask "Max tokens per LLM response" "16384" OCR_MAX_TOKENS
    ask "Max concurrent chunks" "4" OCR_MAX_CONCURRENT_CHUNKS
    ask "Max pages per document" "200" OCR_MAX_PAGES
    ask "Max upload file size (MB)" "100" OCR_MAX_FILE_SIZE_MB
    echo ""
}

# ───────────────────────────────────────────────────────────────────────────
# Write .env
# ───────────────────────────────────────────────────────────────────────────

write_env() {
    local envfile=".env"

    if [[ -f "$envfile" ]]; then
        warn "Existing .env file found."
        echo -ne "${BOLD}Overwrite? [Y/n]${RESET}: "
        read -r yn
        if [[ "$yn" =~ ^[Nn]$ ]]; then
            info "Keeping existing .env. Skipping write."
            return
        fi
        cp "$envfile" ".env.backup"
        info "Backed up to .env.backup"
    fi

    cat > "$envfile" <<EOF
# ─────────────────────────────────────────────
# DGX Stack Configuration
# Generated by setup.sh on $(date -u +"%Y-%m-%d %H:%M:%S UTC")
# Model: ${MODEL_CHOICE}
# ─────────────────────────────────────────────

# Model
VLLM_IMAGE=${VLLM_IMAGE}
HF_MODEL_ID=${HF_MODEL_ID}
SERVED_MODEL_NAME=${SERVED_MODEL_NAME}
VLLM_EXTRA_FLAGS=${VLLM_EXTRA_FLAGS:---no-enable-prefix-caching}

# HuggingFace
HF_TOKEN=${HF_TOKEN}
HF_CACHE=${HF_CACHE}

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
# Review configuration
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
# Deploy
# ───────────────────────────────────────────────────────────────────────────

deploy() {
    echo -ne "${BOLD}Deploy now? [Y/n]${RESET}: "
    read -r yn
    if [[ "$yn" =~ ^[Nn]$ ]]; then
        echo ""
        info "To deploy later, run:"
        echo "  docker compose up -d"
        echo ""
        info "To view logs:"
        echo "  docker compose logs -f"
        return
    fi

    echo ""
    info "Building OCR container..."
    docker compose build ocr

    echo ""
    info "Pulling vLLM container (this may take a while on first run)..."
    docker compose pull vllm

    echo ""
    info "Starting services..."
    docker compose up -d

    echo ""
    info "Waiting for vLLM to load the model..."
    if [[ "$MODEL_CHOICE" == "qwen35" ]]; then
        info "Qwen 3.5 35B FP8 is ~35GB. First request may take ~60s to warm up."
    else
        info "Gemma 4 26B is ~52GB. This takes several minutes."
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
        echo -ne "\r  Waiting... ${elapsed}s / ${max_wait}s"
        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    if (( elapsed >= max_wait )); then
        echo ""
        warn "vLLM hasn't become healthy after ${max_wait}s."
        warn "Check logs: docker compose logs vllm"
        warn "The service may still be loading. The healthcheck will restart it if needed."
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
    preflight
    select_model
    configure
    review
    write_env
    deploy
}

main "$@"
