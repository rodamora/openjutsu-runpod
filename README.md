# Openjutsu on Runpod

A Runpod **Pod** image for [Openjutsu](https://github.com/D3voz/openjutsu): one-click character swap for video
(MiniMax H3 + SAM 3.1 + Qwen3-VL on ComfyUI). Drop a video and a character photo in the web app, press
**Generate**, download the swapped video.

```
ghcr.io/rodamora/openjutsu-runpod:latest        # public, linux/amd64
```

Every CI build also pushes `:<git sha>`; pin a digest from the Actions run summary for reproducible Pods.
The digest tested end to end on a Runpod A40 Pod is
`ghcr.io/rodamora/openjutsu-runpod@sha256:4132f60a19fe71a7a0150193ea18d7e9f9afa171264dc2f69f5455374fbdf394`.

## What runs inside

| Process | Address | Exposed |
| --- | --- | --- |
| Openjutsu app (Next.js) behind `front.mjs` | `0.0.0.0:3000` | yes, `3000/http` |
| comfy-api-proxy 0.1.6 (patched with `patch_proxy.py`) | `127.0.0.1:8189` | no |
| ComfyUI v0.42.1, torch 2.14.1 + CUDA 13.0 | `127.0.0.1:8188` | no |
| sshd (only when `PUBLIC_KEY` is set) | `:22` | optional, `22/tcp` |

ComfyUI and the proxy have no authentication, so they stay on loopback. `front.mjs` exists because Runpod's
HTTP proxy sends the pod-internal address as `Host` and the public name in `X-Forwarded-Host`; without
restoring it, Openjutsu's same-origin check refuses every API call from the browser.

Installed custom nodes (pinned commits in the `Dockerfile`): MiniMaxH3 Context Loop, Fantastic MiniMaxH3
PromptBuilder, KJNodes, VideoHelperSuite, h3-oneclick-swap, websocket-reconnect-fix, Spectrum MiniMax H3.
That covers **Simple** and **Advanced motion transfer**, **Montage**, **Check mask**, **Find people** and
**Object swap**. Not included: Fix faces, Fix colours and From picture (FLUX / SolarRenderer); their packs and
weights are not in this image.

## Create the Pod

| Setting | Value |
| --- | --- |
| Image | `ghcr.io/rodamora/openjutsu-runpod:latest` (no registry credential needed) |
| GPU | 1× 48 GB card (A40, RTX A6000, L40S, RTX 6000 Ada). 24 GB cards should work through ComfyUI's dynamic VRAM offload but are untested here |
| CUDA | host CUDA **13.0 or newer** (`minCudaVersion: "13.0"`); the torch build is cu130 |
| System RAM | 48 GB or more |
| Container disk | 30 GB |
| Volume | 100 GB at `/workspace` (pod volume or network volume) |
| Ports | `3000/http` (app), optionally `22/tcp` (SSH) |
| Env | `OPENJUTSU_PASSWORD`: 12+ characters, required. Best as a Runpod secret: `{{ RUNPOD_SECRET_openjutsu_password }}` |

Open `https://<pod-id>-3000.proxy.runpod.net` and sign in as **`openjutsu`** with that password.

### First boot

`start.sh` downloads the seven model files in `models.lock.json` (50.8 GB, pinned Hugging Face revisions,
sha256-checked) into `/workspace/openjutsu/models`, then starts everything. The container log shows JSON
progress lines (`fetch_models` / `start` / `check_nodes`). Later boots reuse the verified files and are
ready in about a minute.

| Folder | File | Source |
| --- | --- | --- |
| `diffusion_models` | `minimax_h3_ref2va_pruned_int8_convrot.safetensors` | Comfy-Org/MiniMax-H3 |
| `loras` | `minimax_h3_DMAD_4step_full_lora_avg_rank_39_bf16.safetensors` | Kijai/MiniMax-H3-experimental |
| `text_encoders` | `qwen3vl_32b_minimax_h3_int4_convrot.safetensors` (H3 encoder) | Merserk/MiniMax-H3-INT4-ConvRot |
| `text_encoders` | `qwen3vl_8b_int8_convrot.safetensors` (describer) | Comfy-Org/Qwen3-VL |
| `vae` | `minimax_h3_video_vae_int8_convrot.safetensors`, `minimax_h3_audio_vae_fp32.safetensors` | Comfy-Org/MiniMax-H3 |
| `checkpoints` | `sam3.1_multiplex_fp16.safetensors` | Comfy-Org/sam3.1 |

Other model files (extra LoRAs, other quantizations) can be dropped into the same folders; the app's
pickers read ComfyUI's lists.

### Data on `/workspace/openjutsu`

| Path | Contents |
| --- | --- |
| `models/` | weights (above) |
| `input/` | uploads ComfyUI received (not cleaned automatically) |
| `output/` | finished videos and H3 clip checkpoints (re-running the same inputs resumes from them) |
| `user/` | ComfyUI user settings |

### Environment variables

| Variable | Default | Meaning |
| --- | --- | --- |
| `OPENJUTSU_PASSWORD` | — | required; the app refuses to start without it |
| `DATA_DIR` | `/workspace/openjutsu` | models, input, output, user |
| `APP_PORT` | `3000` | public port of the app |
| `COMFYUI_ARGS` | empty | extra ComfyUI flags, e.g. `--lowvram` |
| `SKIP_MODEL_DOWNLOAD` | `0` | `1` skips `fetch_models.py` (weights provided another way) |
| `MODEL_DOWNLOAD_WORKERS` | `4` | parallel downloads |
| `HF_TOKEN` | empty | only if you add gated repos to `models.lock.json` |

If ComfyUI, the proxy, the app or the front exits, the container stops all of them and exits non-zero, so a
broken Pod shows up as a restart with the reason in the log instead of a half-working app.

## Build

GitHub Actions (`.github/workflows/image.yml`) builds on every push to `main`: the upstream app's own test
suite runs inside the build, then `scripts/smoke.sh` boots the image on CPU (no models) and checks that all 69
node types the swap workflows use are registered, the login gate, a same-origin API call shaped like Runpod's
proxy, a cross-origin refusal, and the proxy's v2 API. Only then is the image pushed to GHCR.

Bump versions through the `ARG`s at the top of the `Dockerfile` (`OPENJUTSU_REF`, `COMFYUI_REF`,
`TORCH_VERSION`, the `*_REF` node commits). Model changes go in `models.lock.json`
(`path`, `url` with a pinned revision, `sha256`, `size`).

Local build (needs Docker with an amd64 builder):

```sh
docker buildx build --platform linux/amd64 -t openjutsu-runpod .
docker run --rm openjutsu-runpod /opt/openjutsu-runpod/smoke.sh
```

## Licences

Openjutsu is MIT. Model licences are separate (MiniMax H3 community licence, SAM licence, Qwen licences);
check them before commercial use.
