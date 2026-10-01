#!/usr/bin/env python3
"""Start a local Laya decision server backed by the on-disk checkpoints.

Laya's own ``laya-serve`` builds its Router from ``LAYA_MODELS``, which is a list of
*checkpoint names* resolved against the Hugging Face hub. This machine already has the
checkpoints on disk, and the hub cache is not writable, so this launcher builds the
Router from explicit local paths instead and serves the same
``POST /v1/systemone`` protocol over uvicorn.

Environment:
  LAYA_MODELS_ROOT  directory holding ``laya``, ``laya-multilingual`` and
                    ``laya-typed-decisions``             (required)
  LAYA_HOST         bind address                         (default 127.0.0.1)
  LAYA_PORT         bind port                            (default 8000)
  LAYA_DEVICE       torch device: cpu / mps / cuda       (default: auto)
  LAYA_PRELOAD_MODELS  comma list of checkpoints to build at startup
                    (default "english"; empty string preloads all three)
  LAYA_API_KEY      require ``Authorization: Bearer`` when set
  LAYA_THREADS      cap torch intra-op threads
"""
import os
import sys
from pathlib import Path

CHECKPOINTS = {
    "english": "laya",
    "multilingual": "laya-multilingual",
    "typed-decisions": "laya-typed-decisions",
}


def _models_from_root(root: str):
    base = Path(root).expanduser()
    return {name: str(base / sub) for name, sub in CHECKPOINTS.items()}


def main() -> int:
    root = os.environ.get("LAYA_MODELS_ROOT", "").strip()
    if not root:
        print("error: LAYA_MODELS_ROOT is not set (directory holding the Laya checkpoints)", file=sys.stderr)
        return 2

    host = os.environ.get("LAYA_HOST", "127.0.0.1").strip() or "127.0.0.1"
    port = int(os.environ.get("LAYA_PORT", "8000"))
    device = (os.environ.get("LAYA_DEVICE") or "").strip() or None

    preload_raw = os.environ.get("LAYA_PRELOAD_MODELS", "english")
    preload = [m.strip() for m in preload_raw.split(",") if m.strip()]

    threads = (os.environ.get("LAYA_THREADS") or "").strip()
    if threads.isdigit():
        try:
            import torch  # noqa: PLC0415  (heavy import, only when asked)

            torch.set_num_threads(int(threads))
        except Exception as exc:  # pragma: no cover - best effort
            print(f"warning: could not set torch threads: {exc}", file=sys.stderr)

    import uvicorn  # noqa: PLC0415
    from laya.router import Router  # noqa: PLC0415
    from laya.serve import create_app  # noqa: PLC0415

    models = _models_from_root(root)
    missing = [p for p in models.values() if not Path(p).exists()]
    if missing:
        print("error: checkpoint directories not found:\n  " + "\n  ".join(missing), file=sys.stderr)
        return 2

    print(f"laya: models root {root}", file=sys.stderr)
    for name, path in models.items():
        print(f"laya:   {name} -> {path}", file=sys.stderr)
    print(f"laya: device={device or 'auto'} preload={preload or 'all'}", file=sys.stderr)

    router = Router(models=models, device=device, preload=False, max_loaded=3)
    if preload:
        router.preload(preload)

    app = create_app(router)
    uvicorn.run(
        app,
        host=host,
        port=port,
        log_level=os.environ.get("LAYA_LOG_LEVEL", "info"),
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
