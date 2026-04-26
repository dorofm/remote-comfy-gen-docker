"""
sitecustomize.py — loaded by Python automatically before any other imports.
Patches runpod.serverless.start to wrap the handler with hf_download support.
"""
import subprocess as _sp, time as _time, os as _os


def _hf_download_handler(job):
    start_t = _time.time()
    inp = job.get("input") or {}
    downloads = inp.get("downloads", [])
    hf_token = inp.get("hf_token", "") or ""
    files = []
    for dl in downloads:
        url = dl["url"]
        dest = dl["dest"]
        filename = dl.get("filename") or url.split("/")[-1].split("?")[0]
        dest_dir = f"/runpod-volume/ComfyUI/models/{dest}"
        _os.makedirs(dest_dir, exist_ok=True)
        dest_path = f"{dest_dir}/{filename}"
        if _os.path.exists(dest_path):
            size_mb = round(_os.path.getsize(dest_path) / (1024 * 1024), 1)
            files.append({"filename": filename, "dest": dest, "path": dest_path, "size_mb": size_mb})
            continue
        headers = [f"--header=Authorization: Bearer {hf_token}"] if (hf_token and "huggingface.co" in url) else []
        cmd = ["aria2c", "-x16", "-s16", "-k1M", "--console-log-level=warn", "--continue=true"] + headers + ["-o", filename, "-d", dest_dir, url]
        r = _sp.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"aria2c hf_download failed (exit {r.returncode}): {r.stdout}\n{r.stderr}")
        size_mb = round(_os.path.getsize(dest_path) / (1024 * 1024), 1)
        files.append({"filename": filename, "dest": dest, "path": dest_path, "size_mb": size_mb})
    return {"ok": True, "files": files, "elapsed_seconds": round(_time.time() - start_t)}


try:
    import runpod.serverless as _rp_sl
    _original_start = _rp_sl.start

    def _patched_start(config):
        _original_handler = config.get("handler")
        if _original_handler is None:
            return _original_start(config)

        def _wrapped_handler(job):
            if (job.get("input") or {}).get("command") == "hf_download":
                return _hf_download_handler(job)
            return _original_handler(job)

        config["handler"] = _wrapped_handler
        return _original_start(config)

    _rp_sl.start = _patched_start
    print("[sitecustomize] runpod.serverless.start patched with hf_download support")
except Exception as _e:
    print(f"[sitecustomize] patch skipped: {_e}")
