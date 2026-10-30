#!/usr/bin/env bash
# Pod entrypoint: models -> ComfyUI (127.0.0.1:8188) -> node check -> comfy-api-proxy (127.0.0.1:8189)
# -> Openjutsu app (0.0.0.0:$APP_PORT). If any of the three services exits, the others are stopped
# and the container exits non-zero, so a failure is visible instead of a half-working Pod.
set -euo pipefail

DATA_DIR="${DATA_DIR:-/workspace/openjutsu}"
APP_PORT="${APP_PORT:-3000}"
export MODELS_DIR="$DATA_DIR/models"

log() { printf '{"component":"start","event":"%s"%s}\n' "$1" "${2:+,$2}"; }

# Runpod injects the account's SSH keys as PUBLIC_KEY; sshd is only started when they are present.
if [ -n "${PUBLIC_KEY:-}" ]; then
  mkdir -p /root/.ssh && chmod 700 /root/.ssh
  printf '%s\n' "$PUBLIC_KEY" > /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys
  ssh-keygen -A >/dev/null
  /usr/sbin/sshd -o PasswordAuthentication=no -o PermitRootLogin=prohibit-password
  log sshd
fi

# The app refuses to listen on 0.0.0.0 without a password, and rejects one shorter than 12 characters.
if [ -z "${OPENJUTSU_PASSWORD:-}" ] || [ "${#OPENJUTSU_PASSWORD}" -lt 12 ]; then
  log config_error '"error":"set OPENJUTSU_PASSWORD (12+ characters) in the Pod environment"'
  exit 1
fi

mkdir -p "$MODELS_DIR"/{diffusion_models,loras,text_encoders,vae,checkpoints} \
  "$DATA_DIR"/{input,output,user}
ln -sfn "$MODELS_DIR" /opt/ComfyUI/models

if [ "${SKIP_MODEL_DOWNLOAD:-0}" != "1" ]; then
  /opt/venv/bin/python /opt/openjutsu-runpod/fetch_models.py
fi

pids=()
stop() { kill "${pids[@]}" 2>/dev/null || true; wait 2>/dev/null || true; }
trap 'stop; exit 143' TERM INT

# shellcheck disable=SC2086 # COMFYUI_ARGS is a deliberate word list (e.g. "--cpu" or "--lowvram")
/opt/venv/bin/python /opt/ComfyUI/main.py --listen 127.0.0.1 --port 8188 \
  --input-directory "$DATA_DIR/input" --output-directory "$DATA_DIR/output" \
  --user-directory "$DATA_DIR/user" ${COMFYUI_ARGS:-} &
pids+=($!)

for _ in $(seq 1 300); do
  curl -sf -o /dev/null http://127.0.0.1:8188/queue && break
  kill -0 "${pids[0]}" 2>/dev/null || { log comfyui_exited; exit 1; }
  sleep 2
done
curl -sf -o /dev/null http://127.0.0.1:8188/queue || { log comfyui_timeout; stop; exit 1; }
log comfyui_ready

/opt/venv/bin/python /opt/openjutsu-runpod/check_nodes.py http://127.0.0.1:8188 || { stop; exit 1; }

/opt/proxy-venv/bin/comfy-api-proxy run --comfyui http://127.0.0.1:8188 --max-upload-mb 500 &
pids+=($!)

cd /opt/openjutsu
COMFY_BASE_URL=http://127.0.0.1:8189 COMFYUI_URL=http://127.0.0.1:8188 \
  node node_modules/next/dist/bin/next start --hostname 0.0.0.0 --port "$APP_PORT" &
pids+=($!)
log app_started "\"port\":$APP_PORT"

set +e
wait -n "${pids[@]}"
status=$?
log service_exited "\"status\":$status"
stop
exit 1
