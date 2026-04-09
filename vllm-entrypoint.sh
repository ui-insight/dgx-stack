#!/usr/bin/env bash
# Entrypoint wrapper that allows VLLM_EXTRA_FLAGS to be passed as a
# space-separated string from .env and properly split into arguments.
set -euo pipefail

exec python -m vllm.entrypoints.openai.api_server \
    --model "${HF_MODEL_ID}" \
    --served-model-name "${SERVED_MODEL_NAME}" \
    --host 0.0.0.0 \
    --port "${VLLM_PORT:-8000}" \
    --kv-cache-dtype "${KV_CACHE_DTYPE:-fp8}" \
    --max-model-len "${MAX_MODEL_LEN:-131072}" \
    --gpu-memory-utilization "${GPU_MEMORY_UTIL:-0.75}" \
    --max-num-seqs "${MAX_NUM_SEQS:-4}" \
    --trust-remote-code \
    ${VLLM_EXTRA_FLAGS:-}
