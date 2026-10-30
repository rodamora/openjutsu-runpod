# syntax=docker/dockerfile:1
# Openjutsu (https://github.com/D3voz/openjutsu) as a Runpod Pod: ComfyUI + the character-swap
# custom nodes + comfy-api-proxy + the Next.js app. Weights are NOT baked in: scripts/start.sh
# downloads models.lock.json (~51 GB, sha256-checked) into /workspace on first boot.
#
# Only the app port (3000) is meant to be exposed. ComfyUI (8188) and the proxy (8189) stay on
# loopback because neither has authentication.

ARG OPENJUTSU_REF=7fe118bb5a61fcfac0148e1bfea3dd29884dbf26

# ---------- app build (Next.js) ----------
FROM node:22-bookworm-slim@sha256:4b150b48b4116e2a22f2c39cc27025fbf4f153e2078fd3b14d159fdb5c7279da AS app
ARG OPENJUTSU_REF
RUN apt-get update && apt-get install -y --no-install-recommends git ca-certificates && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/openjutsu
RUN git init -q . \
  && git remote add origin https://github.com/D3voz/openjutsu \
  && git fetch -q --depth 1 origin "$OPENJUTSU_REF" \
  && git checkout -q FETCH_HEAD \
  && rm -rf .git
ENV NEXT_TELEMETRY_DISABLED=1
# The upstream suite (131 unit tests + tsc) runs here, so a broken pin fails the build.
RUN npm ci --no-audit --no-fund && npm test && npm run build

# ---------- runtime ----------
FROM ubuntu:24.04@sha256:fe81560990fae86dc4743202b2cb4d3df98d0bcf949173cecef15ce1127ef852

ARG COMFYUI_REF=v0.42.1
ARG TORCH_INDEX=https://download.pytorch.org/whl/cu130
# Custom-node packs pinned by commit (default branch heads on 2026-10-30).
ARG CONTEXT_LOOP_REF=43afeffcc570beb5f7382593e79e4b211c7e02f6
ARG PROMPTBUILDER_REF=22e719fe89336c628383363182a4da3cb58d4f9b
ARG KJNODES_REF=ab72eda7ffad6280422d71ab7d54d3fb87c0ba18
ARG VHS_REF=4d907bee61e92c2e65af3bd6383a4e4d356126d1
ARG ONECLICK_SWAP_REF=e44a56e92920000e675d14be484aea0d7498d63e
ARG WS_FIX_REF=12b5fdf38e8bdbf8a560b9196561244bf65621f4
ARG SPECTRUM_REF=806fe498d574a726fecb8818917f00a4b993fd77
ARG TORCH_VERSION=2.14.1
ARG COMFY_API_PROXY_VERSION=0.1.6

ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    NVIDIA_VISIBLE_DEVICES=all \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility,video \
    NEXT_TELEMETRY_DISABLED=1 \
    UV_LINK_MODE=copy \
    UV_NO_CACHE=1

# gcc + Python headers: Triton JIT-compiles kernels at first use on some GPUs and dies without a C compiler.
RUN apt-get update && apt-get install -y --no-install-recommends \
      python3.12 python3.12-venv python3.12-dev gcc g++ git ffmpeg curl ca-certificates tini \
      openssh-server libgl1 libglib2.0-0 \
  && rm -rf /var/lib/apt/lists/* \
  && mkdir -p /run/sshd

COPY --from=ghcr.io/astral-sh/uv:0.13.6@sha256:af22a52f5eafef3d78e551599d405c02df61919d18028f0cea8eda93bc9986d0 /uv /usr/local/bin/uv
COPY --from=app /usr/local/bin/node /usr/local/bin/node

# ComfyUI and its Python (torch first, so the heavy layer is reused when ComfyUI moves).
RUN uv venv --python /usr/bin/python3.12 /opt/venv \
  && uv pip install --python /opt/venv/bin/python --index-url "$TORCH_INDEX" \
       "torch==$TORCH_VERSION" torchvision torchaudio
RUN git clone -q --depth 1 --branch "$COMFYUI_REF" https://github.com/Comfy-Org/ComfyUI /opt/ComfyUI \
  && uv pip install --python /opt/venv/bin/python -r /opt/ComfyUI/requirements.txt \
  && rm -rf /opt/ComfyUI/.git /opt/ComfyUI/models

COPY scripts/install_node.sh /usr/local/bin/install_node
RUN install_node https://github.com/ethanfel/ComfyUI-MiniMaxH3-Context-Loop "$CONTEXT_LOOP_REF" \
  && install_node https://github.com/Adudeguyman/ComfyUI-Fantastic-MiniMaxH3-PromptBuilder "$PROMPTBUILDER_REF" \
  && install_node https://github.com/kijai/ComfyUI-KJNodes "$KJNODES_REF" \
  && install_node https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite "$VHS_REF" \
  && install_node https://github.com/D3voz/comfyui-h3-oneclick-swap "$ONECLICK_SWAP_REF" \
  && install_node https://github.com/D3voz/comfyui-websocket-reconnect-fix "$WS_FIX_REF" \
  && install_node https://github.com/xmarre/ComfyUI-Spectrum-MiniMax-H3 "$SPECTRUM_REF"

# comfy-api-proxy in its own venv, with openjutsu's live-progress patch applied.
COPY --from=app /opt/openjutsu /opt/openjutsu
RUN uv venv --python /usr/bin/python3.12 /opt/proxy-venv \
  && uv pip install --python /opt/proxy-venv/bin/python "comfy-api-proxy==$COMFY_API_PROXY_VERSION" \
  && /opt/proxy-venv/bin/python /opt/openjutsu/patch_proxy.py

COPY models.lock.json /opt/openjutsu-runpod/models.lock.json
COPY scripts/start.sh scripts/front.mjs scripts/fetch_models.py scripts/check_nodes.py scripts/smoke.sh /opt/openjutsu-runpod/

EXPOSE 3000 22
ENTRYPOINT ["/usr/bin/tini", "-g", "--"]
CMD ["/opt/openjutsu-runpod/start.sh"]
