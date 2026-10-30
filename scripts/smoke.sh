#!/usr/bin/env bash
# CPU smoke (no GPU, no models): boots the real start.sh with ComfyUI --cpu, which runs check_nodes.py
# against every character-swap workflow, then checks the app's login gate and the app -> proxy path.
# Run: docker run --rm <image> /opt/openjutsu-runpod/smoke.sh
set -euo pipefail
export OPENJUTSU_PASSWORD="smoke-test-password" SKIP_MODEL_DOWNLOAD=1 COMFYUI_ARGS="--cpu" \
  DATA_DIR="$(mktemp -d)" APP_PORT=3000
/opt/openjutsu-runpod/start.sh &
pid=$!
trap 'rc=$?; kill $pid 2>/dev/null; wait $pid 2>/dev/null; exit $rc' EXIT

for _ in $(seq 1 180); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:3000/ || true)
  [ "$code" != "000" ] && break
  kill -0 $pid 2>/dev/null || { echo "smoke: start.sh exited"; exit 1; }
  sleep 2
done
[ "$code" = "401" ] || { echo "smoke: expected 401 without login, got $code"; exit 1; }

auth="openjutsu:$OPENJUTSU_PASSWORD"
code=$(curl -s -o /dev/null -w '%{http_code}' -u "$auth" http://127.0.0.1:3000/)
[ "$code" = "200" ] || { echo "smoke: expected 200 with login, got $code"; exit 1; }

# The models route reads ComfyUI's model lists, so it proves app -> ComfyUI wiring end to end.
models=$(curl -sf -u "$auth" -H 'Sec-Fetch-Site: same-origin' http://127.0.0.1:3000/api/models)
echo "smoke: /api/models -> ${models:0:200}"
# The proxy must answer the v2 API the app's SDK talks to.
curl -sf -o /dev/null http://127.0.0.1:8189/api/v2/jobs || { echo "smoke: comfy-api-proxy not answering"; exit 1; }
echo "smoke: ok"
