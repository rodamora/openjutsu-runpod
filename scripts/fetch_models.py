#!/usr/bin/env python3
"""Download the weights in models.lock.json into MODELS_DIR, resuming partial files.

A file counts as present only after its sha256 matched; the match is recorded in <file>.sha256 so
restarts skip re-hashing. Downloads go to <file>.part and are renamed into place after the check,
so ComfyUI never lists a half-written model. Exit code 1 if any file fails.
"""
import concurrent.futures
import hashlib
import json
import os
import subprocess
import sys
import threading
import time

LOCK = os.environ.get("MODELS_LOCK", "/opt/openjutsu-runpod/models.lock.json")
MODELS_DIR = os.environ.get("MODELS_DIR", "/workspace/openjutsu/models")
WORKERS = int(os.environ.get("MODEL_DOWNLOAD_WORKERS", "4"))


def log(**event):
    print(json.dumps({"component": "fetch_models", **event}), flush=True)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        while chunk := f.read(16 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def fetch(model):
    dest = os.path.join(MODELS_DIR, model["path"])
    marker = dest + ".sha256"
    if os.path.exists(dest) and os.path.exists(marker) and open(marker).read().strip() == model["sha256"]:
        return "present"
    os.makedirs(os.path.dirname(dest), exist_ok=True)
    if os.path.exists(dest) and os.path.getsize(dest) == model["size"] and sha256(dest) == model["sha256"]:
        open(marker, "w").write(model["sha256"])
        return "verified"
    part = dest + ".part"
    if os.path.exists(part) and os.path.getsize(part) > model["size"]:
        os.remove(part)
    cmd = ["curl", "-sS", "-L", "--fail", "--retry", "8", "--retry-all-errors", "--retry-delay", "5",
           "-C", "-", "-o", part, model["url"]]
    if os.environ.get("HF_TOKEN"):
        cmd[1:1] = ["-H", "Authorization: Bearer " + os.environ["HF_TOKEN"]]
    for attempt in range(3):
        if subprocess.run(cmd).returncode == 0 and os.path.getsize(part) == model["size"]:
            break
        time.sleep(10)
    else:
        raise RuntimeError(f"download incomplete: {model['path']}")
    if sha256(part) != model["sha256"]:
        os.remove(part)
        raise RuntimeError(f"sha256 mismatch: {model['path']}")
    os.replace(part, dest)
    open(marker, "w").write(model["sha256"])
    return "downloaded"


def progress(models, done):
    total = sum(m["size"] for m in models)
    while not done.wait(30):
        have = 0
        for m in models:
            dest = os.path.join(MODELS_DIR, m["path"])
            for p in (dest, dest + ".part"):
                if os.path.exists(p):
                    have += os.path.getsize(p)
                    break
        log(event="progress", gb=round(have / 1e9, 1), total_gb=round(total / 1e9, 1))


def main():
    models = json.load(open(LOCK))["models"]
    done = threading.Event()
    threading.Thread(target=progress, args=(models, done), daemon=True).start()
    failed = 0
    with concurrent.futures.ThreadPoolExecutor(WORKERS) as pool:
        futures = {pool.submit(fetch, m): m for m in models}
        for future in concurrent.futures.as_completed(futures):
            path = futures[future]["path"]
            try:
                log(event=future.result(), path=path)
            except Exception as error:  # noqa: BLE001 - report every file, then fail
                failed += 1
                log(event="failed", path=path, error=str(error))
    done.set()
    if failed:
        sys.exit(1)
    log(event="ready", models=len(models))


if __name__ == "__main__":
    main()
