# DGX Stack

<img width="1714" height="624" alt="Gemini_Generated_Image_y4377ry4377ry437" src="https://github.com/user-attachments/assets/6d127295-b5b4-4201-a8f3-d5efd41d24ae" />
  
&nbsp;

Three-container stack for running a chat LLM **and** a dedicated document-OCR model side by side on an **NVIDIA DGX Spark** (ARM Grace CPU + Blackwell GPU, 128GB unified memory). Two vLLM instances serve the models; a FastAPI service turns documents into markdown through the OCR model.

## Models

| Role | Model | Params | Weights | Context | Notes |
|------|-------|--------|---------|---------|-------|
| **LLM** | [Qwen 3.6 35B NVFP4](https://huggingface.co/nvidia/Qwen3.6-35B-A3B-NVFP4) | 35B MoE (3B active) | ~23GB (NVFP4) | 262K | NVIDIA ModelOpt pre-quantized. Open access. |
| **OCR** | [dots.mocr FP8](https://huggingface.co/binedge/dots.mocr-FP8) | ~3B (1.2B vision + 1.5B LM) | ~5GB (FP8) | 131K | Document-parsing specialist by rednote-hilab. Open access. |

**Why a dedicated OCR model?** dots.mocr is state of the art for document parsing at any open-source size: 83.9 on olmOCR-bench (vs ~65–70 for general VLMs like GPT-4o and Qwen2.5-VL) and it beats even Qwen3-VL-235B on OmniDocBench text edit distance (0.031 vs 0.069). The FP8 quant keeps the entire vision tower in BF16 — only the small language decoder is quantized. If you prefer the unquantized original, set `MOCR_MODEL_ID=rednote-hilab/dots.mocr` (~6GB, only ~1.3GB more).

The Qwen NVFP4 checkpoint also keeps its vision tower unquantized, and NVIDIA's published evals show essentially no accuracy loss vs BF16 (MMLU Pro 85.6 → 85.0, GPQA Diamond 84.9 → 84.8, MMMU Pro 74.1 → 74.5).

vLLM is pinned to **0.25.1** (`vllm/vllm-openai:vllm-arm64-cu13-0.25.1-7a33ba9` — the v0.25.1 release branch built for ARM64 + CUDA 13; the upstream image, not the NGC container, is what both vLLM's DGX Spark guide and NVIDIA's model card recommend). The LLM instance follows NVIDIA's recommended Spark configuration: FlashInfer attention, Marlin NVFP4 MoE kernels, FP8 KV cache, chunked prefill, async scheduling, fastsafetensors loading, and **MTP speculative decoding** (the model's multi-token-prediction head drafts 3 tokens per step; the base model verifies every draft, so the output distribution matches non-speculative decoding — measured ~76.7 → ~108 tok/s on a Spark). Prefix caching is deliberately **disabled** on the LLM instance: combined with MTP it corrupts this hybrid-attention model's recurrent state (vLLM issue #43559, fix not yet in 0.25.1).

## Prerequisites

- NVIDIA DGX Spark (or any Grace-Blackwell system with CUDA 13)
- Docker Engine with [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/)

No HuggingFace token required — both checkpoints are open access.

## Quick Start

```bash
git clone https://github.com/ui-insight/dgx-stack.git
cd dgx-stack
./setup.sh
```

The setup script walks through configuration (ports, memory limits, OCR tuning) and optionally deploys immediately.

## Manual Setup

```bash
cp .env.example .env
# Edit .env if you want non-default ports or tuning
docker compose up -d
```

## Architecture

```
┌────────────────────────────────────────────────────────────────────┐
│  DGX Spark (128GB unified memory)                                  │
│                                                                    │
│  ┌──────────────────┐  ┌──────────────────┐  ┌──────────────────┐  │
│  │  vLLM (LLM)      │  │  vLLM (OCR)      │  │  OCR Service     │  │
│  │  :8000           │  │  :8001           │◄─│  :8010           │  │
│  │                  │  │                  │  │                  │  │
│  │  qwen3.6-35b     │  │  dots-mocr       │  │  /v1/ocr (JSON)  │  │
│  │  NVFP4, ~51GB    │  │  FP8, ~13GB      │  │  /v1/ocrmd (md)  │  │
│  │  MTP spec decode │  │  layout parsing  │  │                  │  │
│  └──────────────────┘  └──────────────────┘  └──────────────────┘  │
│        gpu-util 0.4         gpu-util 0.10      (~64GB left for OS) │
└────────────────────────────────────────────────────────────────────┘
```

### OCR Pipeline

1. **Convert** — PDF pages (via poppler, 200 DPI), images, or Office docs (via LibreOffice) are converted to PNG images
2. **Parse** — Each page is sent to dots.mocr individually (it is a single-page model), up to 4 pages in parallel; the model returns layout JSON: every element's bounding box, category, and text (tables as HTML, formulas as LaTeX, prose as markdown), in reading order
3. **Render** — The layout JSON is rendered to markdown the same way the upstream dots.mocr pipeline does: page headers/footers dropped, formulas wrapped in `$$` blocks, tables kept as HTML
4. **Retry** — Pages whose layout JSON fails to parse are retried, then fall back to plain-text extraction
5. **Join** — Page markdown is concatenated in order (pages are disjoint, so no overlap stitching is needed)

## API Reference

### LLM — OpenAI-compatible (port 8000)

Standard OpenAI chat completions API. Works with any OpenAI-compatible client.

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-35b",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 256
  }'
```

### OCR — JSON response (port 8010)

`POST /v1/ocr` — Returns a JSON object with the extracted content and metadata.

```bash
curl -X POST http://localhost:8010/v1/ocr \
  -F file=@document.pdf \
  -F dpi=200
```

Response:

```json
{
  "id": "ocr-a1b2c3d4e5f6a1b2c3d4e5f6",
  "object": "ocr.result",
  "created": 1712600000,
  "model": "dots-mocr",
  "content": "# Document Title\n\nExtracted markdown...",
  "format": "markdown",
  "pages": 12,
  "chunks_processed": 12,
  "usage": {
    "prompt_tokens": 45000,
    "completion_tokens": 8000,
    "total_tokens": 53000
  }
}
```

### OCR — Raw markdown (port 8010)

`POST /v1/ocrmd` — Returns the extracted markdown directly as `text/markdown`.

```bash
curl -X POST http://localhost:8010/v1/ocrmd -F file=@document.pdf
```

### OCR Parameters

| Parameter    | Type | Default | Description                     |
|-------------|------|---------|---------------------------------|
| `file`       | file | required | PDF, image, or Office document |
| `model`      | str  | ignored | Accepted for compatibility; the service always uses its configured backend model |
| `dpi`        | int  | 200     | PDF/Office rendering resolution (clamped to 40–400) |
| `chunk_size` | str  | ignored | Deprecated (dots.mocr is single-page) |
| `overlap`    | str  | ignored | Deprecated (pages are disjoint) |

### Supported File Types

- **PDF** — `.pdf`
- **Images** — `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`, `.tiff`, `.bmp` (multi-frame supported)
- **Office** — `.docx`, `.xlsx`, `.pptx`, `.doc`, `.xls`, `.ppt`

## Tests

Two layers of testing ship with the stack:

**Unit tests** (no GPU or running stack needed) cover the dots.mocr layout-JSON → markdown formatter:

```bash
python3 -m unittest discover -s ocr/tests -v
```

**End-to-end smoke tests** run automatically after deploy (or any time via `./setup.sh` → Test). Six checks: both vLLM instances' `/v1/models`, an LLM chat completion, a direct dots.mocr page-OCR through the exact service code path, the `/v1/ocr` JSON endpoint with **table-fidelity assertions** (all 6 column headers and key cell values of the test table must survive — this catches the known merged-table-column failure mode), and the `/v1/ocrmd` sentinel check — followed by a unified-memory usage report.

A small 3-page test PDF lives at [`examples/test-doc.pdf`](examples/test-doc.pdf) so you can also verify endpoints manually right after `docker compose up -d`:

### 1. Discover the served model names

```bash
curl -s http://localhost:8000/v1/models | python3 -m json.tool   # LLM → qwen3.6-35b
curl -s http://localhost:8001/v1/models | python3 -m json.tool   # OCR → dots-mocr
```

Use the LLM name as the `"model"` field in chat requests; the OCR service talks to dots.mocr on its own.

### 2. Chat endpoint

Replace `qwen3.6-35b` below with whatever `/v1/models` returned:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.6-35b",
    "messages": [
      {"role": "system", "content": "You are a concise assistant."},
      {"role": "user",   "content": "In one sentence, what is an NVIDIA DGX Spark?"}
    ],
    "max_tokens": 128,
    "temperature": 0.2
  }' | python3 -m json.tool
```

### 3. OCR endpoint — raw markdown

```bash
curl -s -X POST http://localhost:8010/v1/ocrmd \
  -F file=@examples/test-doc.pdf
```

A healthy run prints three pages of markdown and ends with the literal string `END-OF-TEST-DOCUMENT`. Grep for it to confirm the full document was processed:

```bash
curl -s -X POST http://localhost:8010/v1/ocrmd \
  -F file=@examples/test-doc.pdf | tee /tmp/ocr-out.md | grep END-OF-TEST-DOCUMENT
```

### 4. OCR endpoint — JSON response

```bash
curl -s -X POST http://localhost:8010/v1/ocr \
  -F file=@examples/test-doc.pdf \
  -F dpi=200 | python3 -m json.tool
```

Check that `"pages": 3` appears in the response, along with a `content` field containing the extracted markdown (including the benchmark table from page 2 with all six columns intact).

## Configuration

All settings live in `.env` (generated by `setup.sh`). Key options:

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_IMAGE` | `vllm/vllm-openai:vllm-arm64-cu13-0.25.1-7a33ba9` | Pinned vLLM 0.25.1 (ARM64 + CUDA 13), used by both instances |
| `HF_MODEL_ID` | `nvidia/Qwen3.6-35B-A3B-NVFP4` | LLM checkpoint |
| `SERVED_MODEL_NAME` | `qwen3.6-35b` | LLM name exposed in the API |
| `VLLM_EXTRA_FLAGS` | see `.env.example` | LLM performance flags (FlashInfer, Marlin MoE, …; prefix caching intentionally off) |
| `VLLM_SPECULATIVE_TOKENS` | 3 | MTP speculative decode draft length (0 = off) |
| `VLLM_ENABLE_THINKING_DEFAULT` | true | Serve-time default for the Qwen thinking toggle |
| `MOCR_MODEL_ID` | `binedge/dots.mocr-FP8` | OCR checkpoint (`rednote-hilab/dots.mocr` for BF16) |
| `MOCR_SERVED_MODEL_NAME` | `dots-mocr` | OCR model name exposed in the API |
| `MOCR_PORT` | 8001 | OCR model (vLLM) port |
| `MOCR_GPU_MEMORY_UTIL` | 0.10 | Fraction of unified memory for the OCR instance (~13GB) |
| `MOCR_MAX_MODEL_LEN` | 32768 | OCR model context (covers max page image + output) |
| `MOCR_KV_CACHE_DTYPE` | auto | OCR KV cache precision (BF16; cache is tiny) |
| `HF_TOKEN` | — | HuggingFace API token (optional — both models open access) |
| `VLLM_PORT` | 8000 | LLM API port |
| `OCR_PORT` | 8010 | OCR service port |
| `GPU_MEMORY_UTIL` | 0.4 | Fraction of unified memory for the LLM instance (~51GB) |
| `MAX_MODEL_LEN` | 262144 | LLM max context length in tokens |
| `MAX_NUM_SEQS` | 4 | Max concurrent sequences, LLM instance (OCR instance: `MOCR_MAX_NUM_SEQS`, default 4) |
| `KV_CACHE_DTYPE` | fp8 | LLM KV cache precision — `fp8` or `auto` (BF16 fallback) |
| `HF_CACHE` | ~/.cache/huggingface | Model weight cache directory (shared) |
| `OCR_DPI` | 200 | PDF rendering DPI (dots.mocr's recommendation) |
| `OCR_MAX_TOKENS` | 16384 | Max output tokens per page |
| `OCR_TEMPERATURE` | 0.1 | OCR sampling temperature |
| `OCR_TOP_P` | 0.9 | OCR nucleus sampling (dots.mocr reference value) |
| `OCR_MAX_CONCURRENT_PAGES` | 4 | Pages OCR'd in parallel |
| `OCR_MAX_RETRIES` | 2 | Layout-parse retries per page before plain-text fallback |
| `OCR_MAX_PAGES` | 200 | Max pages per document |
| `OCR_MAX_FILE_SIZE_MB` | 100 | Max upload size |

## Changing Configuration

Re-run setup to reconfigure:

```bash
./setup.sh
```

Or edit `.env` directly, then:

```bash
docker compose down
docker compose up -d
```

## Operations

```bash
# View logs
docker compose logs -f
docker compose logs -f vllm    # LLM instance
docker compose logs -f mocr    # OCR model instance
docker compose logs -f ocr     # OCR service

# Restart
docker compose restart

# Stop
docker compose down

# Update
git pull
docker compose build ocr
docker compose pull vllm
docker compose up -d
```

## Networking

The stack pins its Compose network explicitly to **`10.10.99.0/24`** by
default, so it never lands in the default `172.16.0.0/12` pool. All
three containers live on a bridge network named `dgx-net`.

If `10.10.99.0/24` collides with another Docker network or a host route
on your DGX, change it in `.env`:

```
DGX_NET_SUBNET=10.10.42.0/24
DGX_NET_GATEWAY=10.10.42.1
```

…then `./setup.sh` → Re-Install. Setup.sh also prompts for these values
during Fresh Install and Repair/Reconfigure.

If you want every Docker network on the host (not just this stack) to
allocate from `10.10.0.0/16`, a template daemon config ships in
[`docker/daemon.json`](docker/daemon.json). Install it via
`./setup.sh` → **Configure Networks**, which will:

1. Back up any existing `/etc/docker/daemon.json`
2. Merge the `default-address-pools` setting into the config
3. Restart `docker.service` (briefly stops all containers on the host)

After the restart, every new Docker network — including this stack's —
allocates from `10.10.0.0/16` in `/24` slices. Nothing lands on `172.x.x.x`.

## Important Notes

- **NVFP4 quantization (LLM)** — Uses NVIDIA's official pre-quantized checkpoint ([nvidia/Qwen3.6-35B-A3B-NVFP4](https://huggingface.co/nvidia/Qwen3.6-35B-A3B-NVFP4), ModelOpt). Only the MoE expert linears are FP4; attention layers stay FP8 and the vision tower is unquantized. Published evals show ≤0.8-point deltas vs BF16 across MMLU Pro, GPQA, SciCode, AIME, and MMMU Pro.
- **Speculative decoding** — MTP drafts are verified by the base model every step, so the output distribution matches non-speculative decoding; it only changes speed (~76.7 → ~108 tok/s measured on a Spark). Set `VLLM_SPECULATIVE_TOKENS=0` to disable it when debugging.
- **Prefix caching is off on the LLM — do not re-enable it with MTP.** On this hybrid linear-attention model, prefix-cache hits corrupt the recurrent state under speculative decoding (vLLM issue #43559; the fix is not in 0.25.1), degrading accuracy substantially. If you want prefix caching, set `VLLM_SPECULATIVE_TOKENS=0` first.
- **dots.mocr FP8 quant** — [binedge/dots.mocr-FP8](https://huggingface.co/binedge/dots.mocr-FP8) quantizes only the 1.5B language decoder (vision tower stays BF16), but publishes no accuracy validation. The smoke tests assert table fidelity to catch quality problems; if OCR output looks degraded, switch to the unquantized original with `MOCR_MODEL_ID=rednote-hilab/dots.mocr`.
- **Table extraction spot-check** — There is an open upstream report (dots.ocr issue #268) of table columns being merged on newer vLLM versions. Smoke test 5 checks all six columns of the test table survive; spot-check your own complex tables after deploy.
- **OCR repetition failure mode** — dots-family models can loop endlessly on runs of ellipses/underscores or unrecognizable content. `OCR_MAX_TOKENS` caps the damage and the service retries, but if a page reliably loops, try a higher `dpi` (the model struggles at high character-to-pixel ratios).
- **FP8 KV cache issues (LLM)** — If you see CUDA stream capture errors or FlashInfer kernel crashes, switch to BF16 KV cache by setting `KV_CACHE_DTYPE=auto` in `.env` and restarting.
- **GPU memory** — The DGX Spark uses unified memory shared by both instances. Defaults: Qwen 0.4 (~51GB, NVIDIA's Spark recommendation); the dots.mocr instance sizes its KV cache with an explicit `--kv-cache-memory-bytes 4GB` (weights ~5GB + KV 4GB ≈ 9GB) because on unified memory a fractional `gpu-memory-utilization` budget counts *all* system usage — including the other vLLM instance — and would be exhausted before allocation. Net: ~68GB left for the OS and OCR service.
- **First startup is slow** — Models must be downloaded on first run (~23GB + ~5GB). Subsequent starts use the cached weights; `--load-format fastsafetensors` speeds up the Qwen load from cache.
- **Warmup** — The first request to each instance after startup takes up to ~60s due to torch.compile/CUDA graph warmup. Subsequent requests are fast.
- **fastsafetensors** — If the LLM fails at startup with a load-format error (e.g. a custom image without the `fastsafetensors` package), remove `--load-format fastsafetensors` from `VLLM_EXTRA_FLAGS`.

## NSF Acknowledgement

<img src="https://github.com/user-attachments/assets/d2b43c22-84f6-4912-91dc-8b081d9e2c6f" alt="NSF Logo" width="157">

This project was developed with support from the National Science Foundation (NSF Award #2427549).
