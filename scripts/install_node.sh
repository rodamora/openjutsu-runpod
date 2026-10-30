#!/usr/bin/env bash
# install_node <git-url> <commit>: clone a ComfyUI custom-node pack at an exact commit into
# /opt/ComfyUI/custom_nodes and install its requirements.txt into ComfyUI's venv.
set -euo pipefail
url="$1" ref="$2"
dest="/opt/ComfyUI/custom_nodes/$(basename "$url")"
git init -q "$dest"
git -C "$dest" remote add origin "$url"
git -C "$dest" fetch -q --depth 1 origin "$ref"
git -C "$dest" checkout -q FETCH_HEAD
rm -rf "$dest/.git"
if [ -f "$dest/requirements.txt" ]; then
  uv pip install --python /opt/venv/bin/python -r "$dest/requirements.txt"
fi
