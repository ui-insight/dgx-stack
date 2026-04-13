# DGX Stack

<img width="1714" height="624" alt="Gemini_Generated_Image_y4377ry4377ry437" src="https://github.com/user-attachments/assets/6d127295-b5b4-4201-a8f3-d5efd41d24ae" />
  
&nbsp;

Ultra-convenient two-container stack for running a multimodal LLM on an **NVIDIA DGX Spark** (ARM Grace CPU + Blackwell GPU, 128GB unified memory). One container serves the model via vLLM, the other provides document OCR using the same model's vision capabilities.

## Supported Models

| Model | Total Params | Active | Weights | Context | Notes |
|-------|-------------|--------|---------|---------|-------|
| **Gemma 4 26B** | 26B MoE | 4B | ~52GB (BF16) | 128K | Stronger general LLM. Requires HF token + license. |
| **Qwen 3.5 35B FP8** | 35B MoE | 3B | ~35GB (FP8) | 262K | Excellent OCR/tables. Pre-quantized FP8. Open access. |

Both models are multimodal (vision) and serve as both the LLM and OCR backend.

## Prerequisites

- NVIDIA DGX Spark (or any Grace-Blackwell system with CUDA 13)
- Docker Engine with [NVIDIA Container Toolkit](https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/)
- For Gemma 4: a [HuggingFace token](https://huggingface.co/settings/tokens) with access to [google/gemma-4-26B-A4B-it](https://huggingface.co/google/gemma-4-26B-A4B-it)

## Quick Start

```bash
git clone https://github.com/ui-insight/dgx-stack.git
cd dgx-stack
./setup.sh
```

The setup script asks you to choose a model, then walks through configuration (ports, memory limits, HuggingFace token) and optionally deploys immediately.

## Manual Setup

```bash
cp .env.example .env
# Edit .env — uncomment the model you want
docker compose up -d
```

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  DGX Spark (128GB unified memory)                       │
│                                                         │
│  ┌──────────────────┐      ┌───────────────────────┐    │
│  │  vLLM            │      │  OCR Service          │    │
│  │  :8000           │◄─────│  :8001                │    │
│  │                  │      │                       │    │
│  │  gemma-4-26b     │      │  /v1/ocr   (JSON)     │    │
│  │    — or —        │      │  /v1/ocrmd (markdown) │    │
│  │  qwen3.5-35b     │      │                       │    │
│  │  FP8 KV cache    │      │                       │    │
│  └──────────────────┘      └───────────────────────┘    │
└─────────────────────────────────────────────────────────┘
```

### OCR Pipeline

1. **Convert** — PDF pages (via poppler), images, or Office docs (via LibreOffice) are converted to PNG images
2. **Chunk** — Pages are grouped into overlapping windows (default: 6 pages/chunk, 2-page overlap)
3. **Infer** — Each chunk is sent to the model's vision capabilities for markdown extraction (parallel, up to 4 concurrent)
4. **Retry** — Chunks with suspiciously short output are automatically retried with a stronger prompt
5. **Merge** — Overlapping chunk outputs are stitched together using `difflib` sequence matching to eliminate duplicated content

## API Reference

### LLM — OpenAI-compatible (port 8000)

Standard OpenAI chat completions API. Works with any OpenAI-compatible client.

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemma-4-26b",
    "messages": [{"role": "user", "content": "Hello"}],
    "max_tokens": 256
  }'
```

Replace `gemma-4-26b` with `qwen3.5-35b` if using Qwen.

### OCR — JSON response (port 8001)

`POST /v1/ocr` — Returns a JSON object with the extracted content and metadata.

```bash
curl -X POST http://localhost:8001/v1/ocr \
  -F file=@document.pdf \
  -F chunk_size=6 \
  -F overlap=2 \
  -F dpi=200
```

Response:

```json
{
  "id": "ocr-a1b2c3d4e5f6a1b2c3d4e5f6",
  "object": "ocr.result",
  "created": 1712600000,
  "model": "gemma-4-26b",
  "content": "# Document Title\n\nExtracted markdown...",
  "format": "markdown",
  "pages": 12,
  "chunks_processed": 3,
  "usage": {
    "prompt_tokens": 45000,
    "completion_tokens": 8000,
    "total_tokens": 53000
  }
}
```

### OCR — Raw markdown (port 8001)

`POST /v1/ocrmd` — Returns the extracted markdown directly as `text/markdown`.

```bash
curl -X POST http://localhost:8001/v1/ocrmd -F file=@document.pdf
```

### OCR Parameters

| Parameter    | Type | Default | Description                     |
|-------------|------|---------|---------------------------------|
| `file`       | file | required | PDF, image, or Office document |
| `model`      | str  | from env | Override the vision model      |
| `chunk_size` | int  | 6       | Pages per chunk                 |
| `overlap`    | int  | 2       | Overlapping pages between chunks |
| `dpi`        | int  | 200     | PDF/Office rendering resolution |

### Supported File Types

- **PDF** — `.pdf`
- **Images** — `.png`, `.jpg`, `.jpeg`, `.webp`, `.gif`, `.tiff`, `.bmp` (multi-frame supported)
- **Office** — `.docx`, `.xlsx`, `.pptx`, `.doc`, `.xls`, `.ppt`

## Smoke Tests

A small 3-page test PDF lives at [`examples/test-doc.pdf`](examples/test-doc.pdf) so you can verify both endpoints end-to-end immediately after `docker compose up -d`.

### 1. Discover the served model name

The model ID that chat completions expects is whatever `SERVED_MODEL_NAME` is in your `.env`. You can confirm it by asking vLLM directly:

```bash
curl -s http://localhost:8000/v1/models | python3 -m json.tool
```

For the two supported configurations that will return one of:

- **`gemma-4-26b`** — when running Gemma 4 26B
- **`qwen3.5-35b`** — when running Qwen 3.5 35B

Use that exact string as the `"model"` field in every chat/OCR request.

### 2. Chat endpoint

Replace `qwen3.5-35b` below with whatever `/v1/models` returned:

```bash
curl -s http://localhost:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "qwen3.5-35b",
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
curl -s -X POST http://localhost:8001/v1/ocrmd \
  -F file=@examples/test-doc.pdf
```

A healthy run prints three pages of markdown and ends with the literal string `END-OF-TEST-DOCUMENT`. Grep for it to confirm the full document was processed:

```bash
curl -s -X POST http://localhost:8001/v1/ocrmd \
  -F file=@examples/test-doc.pdf | tee /tmp/ocr-out.md | grep END-OF-TEST-DOCUMENT
```

### 4. OCR endpoint — JSON response

```bash
curl -s -X POST http://localhost:8001/v1/ocr \
  -F file=@examples/test-doc.pdf \
  -F chunk_size=6 \
  -F overlap=2 \
  -F dpi=200 | python3 -m json.tool
```

Check that `"pages": 3` and `"chunks_processed": 1` appear in the response, along with a `content` field containing the extracted markdown.

## Configuration

All settings live in `.env` (generated by `setup.sh`). Key options:

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_IMAGE` | varies by model | Docker image for vLLM |
| `HF_MODEL_ID` | varies by model | HuggingFace model path |
| `SERVED_MODEL_NAME` | varies by model | Name exposed in the API |
| `VLLM_TEST_FORCE_FP8_MARLIN` | 0 | Set to 1 for Qwen FP8 on DGX Spark (SM12.1) |
| `VLLM_USE_DEEP_GEMM` | 1 | Set to 0 for Qwen FP8 to avoid KV cache accuracy issues |
| `HF_TOKEN` | — | HuggingFace API token (required for Gemma 4) |
| `VLLM_PORT` | 8000 | vLLM API port |
| `OCR_PORT` | 8001 | OCR service port |
| `GPU_MEMORY_UTIL` | 0.75 | Fraction of 128GB unified memory for vLLM (~96GB) |
| `MAX_MODEL_LEN` | 131072 | Max context length in tokens |
| `MAX_NUM_SEQS` | 4 | Max concurrent inference sequences |
| `KV_CACHE_DTYPE` | fp8 | KV cache precision — `fp8` or `auto` (BF16 fallback) |
| `HF_CACHE` | ~/.cache/huggingface | Model weight cache directory |
| `OCR_CHUNK_SIZE` | 6 | Pages per OCR chunk |
| `OCR_OVERLAP` | 2 | Overlap pages between chunks |
| `OCR_DPI` | 200 | PDF rendering DPI |
| `OCR_MAX_TOKENS` | 16384 | Max LLM output tokens per chunk |
| `OCR_MAX_CONCURRENT_CHUNKS` | 4 | Parallel chunk processing limit |
| `OCR_MAX_PAGES` | 200 | Max pages per document |
| `OCR_MAX_FILE_SIZE_MB` | 100 | Max upload size |

## Switching Models

Re-run setup to switch:

```bash
./setup.sh
```

Or edit `.env` directly — swap the `VLLM_IMAGE`, `HF_MODEL_ID`, `SERVED_MODEL_NAME`, and `VLLM_EXTRA_FLAGS` lines, then:

```bash
docker compose down
docker compose up -d
```

## Operations

```bash
# View logs
docker compose logs -f
docker compose logs -f vllm
docker compose logs -f ocr

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
default, so it never lands in the default `172.16.0.0/12` pool. Both
containers live on a bridge network named `dgx-net`.

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

- **No FP8 weight quantization** — Dynamic FP8 (`--quantization fp8`) produces gibberish on Gemma 4 (vllm-project/vllm#39049). This stack uses BF16 weights with FP8 KV cache, which works correctly.
- **FP8 KV cache issues** — If you see CUDA stream capture errors or FlashInfer kernel crashes, switch to BF16 KV cache by setting `KV_CACHE_DTYPE=auto` in `.env` and restarting. This uses more memory but avoids FlashInfer FP8 kernel issues on SM12.1.
- **GPU memory** — The DGX Spark uses unified memory. Setting `GPU_MEMORY_UTIL` too high (>0.85) can starve the OS and OCR container. Default 0.75 leaves ~32GB headroom.
- **Qwen 3.5 FP8** — Uses the official pre-quantized checkpoint (`Qwen/Qwen3.5-35B-A3B-FP8`) at ~35GB, not dynamic quantization. Requires `VLLM_TEST_FORCE_FP8_MARLIN=1` on DGX Spark to select the correct FP8 backend for SM12.1. `VLLM_USE_DEEP_GEMM=0` prevents FP8 KV cache accuracy degradation on Blackwell (vllm-project/vllm#37618).
- **First startup is slow** — The model must be downloaded on first run (~52GB for Gemma 4, ~35GB for Qwen 3.5 FP8). Subsequent starts use the cached weights.
- **Gemma 4 access** — You must accept the Gemma 4 license on HuggingFace before the download will work.
- **Qwen 3.5 warmup** — The first request after startup takes ~60s due to torch.compile/CUDA graph warmup. Subsequent requests are fast.
