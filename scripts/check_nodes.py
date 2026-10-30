#!/usr/bin/env python3
"""Fail unless ComfyUI registers every node the character-swap workflows use.

Same question openjutsu's setup check asks (/object_info/<type> per node, plus the
websocket-fix route), minus model files. Usage: check_nodes.py [comfyui-url]
"""
import json
import sys
import urllib.error
import urllib.parse
import urllib.request

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8188").rstrip("/")
WORKFLOWS = "/opt/openjutsu/workflows"
SWAP = ["simple", "advanced", "advanced_maxq", "montage", "mask", "people", "object"]
# Core nodes lib/*.ts can insert into a graph at request time.
INSERTED = {"ImageScale", "StringConcatenate"}


def get(path):
    with urllib.request.urlopen(BASE + path, timeout=60) as response:
        return json.load(response)


types = set(INSERTED)
for name in SWAP:
    graph = json.load(open(f"{WORKFLOWS}/{name}.api.json"))
    types |= {node["class_type"] for node in graph.values()}

missing = sorted(t for t in types if not get("/object_info/" + urllib.parse.quote(t, safe="")))
try:
    get("/websocket_reconnect_fix")
    ws_fix = True
except (urllib.error.URLError, json.JSONDecodeError):
    ws_fix = False

print(json.dumps({"component": "check_nodes", "nodes": len(types), "missing": missing, "websocket_fix": ws_fix}))
sys.exit(0 if not missing and ws_fix else 1)
