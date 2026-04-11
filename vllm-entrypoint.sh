#!/usr/bin/env bash
# Entrypoint wrapper that allows VLLM_EXTRA_FLAGS to be passed as a
# space-separated string from .env and properly split into arguments.
set -euo pipefail

echo "=== vLLM launch config ==="
echo "  HF_MODEL_ID=${HF_MODEL_ID}"
echo "  SERVED_MODEL_NAME=${SERVED_MODEL_NAME}"
echo "  MAX_MODEL_LEN=${MAX_MODEL_LEN:-131072}"
echo "  MAX_NUM_SEQS=${MAX_NUM_SEQS:-4}"
echo "  MAX_NUM_BATCHED_TOKENS=${MAX_NUM_BATCHED_TOKENS:-8192}"
echo "  KV_CACHE_DTYPE=${KV_CACHE_DTYPE:-fp8}"
echo "  GPU_MEMORY_UTIL=${GPU_MEMORY_UTIL:-0.75}"
echo "  VLLM_ENABLE_THINKING_DEFAULT=${VLLM_ENABLE_THINKING_DEFAULT:-}"
echo "  VLLM_EXTRA_FLAGS=${VLLM_EXTRA_FLAGS:-}"
echo "=========================="

# Build an optional --default-chat-template-kwargs flag for models that
# support toggling thinking per-request (e.g. Qwen 3.5 with
# --reasoning-parser deepseek_r1). Setting the serve-time default is what
# makes the per-request enable_thinking=false override actually work.
# Using a bash array preserves the embedded JSON as a single argv entry
# regardless of the quoting in VLLM_EXTRA_FLAGS.
THINKING_FLAG=()
if [[ -n "${VLLM_ENABLE_THINKING_DEFAULT:-}" ]]; then
    THINKING_FLAG=(--default-chat-template-kwargs "{\"enable_thinking\":${VLLM_ENABLE_THINKING_DEFAULT}}")
    echo "  → adding ${THINKING_FLAG[*]}"
fi

exec python3 -m vllm.entrypoints.openai.api_server \
    --model "${HF_MODEL_ID}" \
    --served-model-name "${SERVED_MODEL_NAME}" \
    --host 0.0.0.0 \
    --port "${VLLM_PORT:-8000}" \
    --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}" \
    --max-model-len "${MAX_MODEL_LEN:-131072}" \
    --max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS:-8192}" \
    --gpu-memory-utilization "${GPU_MEMORY_UTIL:-0.75}" \
    --max-num-seqs "${MAX_NUM_SEQS:-4}" \
    "${THINKING_FLAG[@]}" \
    ${VLLM_EXTRA_FLAGS:-}
