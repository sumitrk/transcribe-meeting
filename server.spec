# -*- mode: python ; coding: utf-8 -*-
#
# PyInstaller spec for TranscribeMeeting server.
#
# Build with:
#   uv run pyinstaller server.spec
#
# Output: dist/transcribe_server/  (a folder containing the binary + all libs)
#

from PyInstaller.utils.hooks import collect_all, collect_submodules

# Packages that need full recursive collection (native extensions, data files, etc.)
COLLECT_ALL = [
    "mlx",
    "mlx_audio",
    "anthropic",
    "fastapi",
    "uvicorn",
    "starlette",
    "anyio",
    "httpx",
]

import os, sys

datas = []
binaries = []
hiddenimports = []

for pkg in COLLECT_ALL:
    d, b, h = collect_all(pkg)
    datas     += d
    binaries  += b
    hiddenimports += h

# collect_all('mlx') misses the compiled Metal shader library.
# We still bundle it into mlx/lib/ so the package layout is complete, then the
# app packaging step adds a signed symlink at _internal/mlx.metallib before the
# final app signature is applied.
import mlx.core as _mlx_core
_mlx_dir = os.path.dirname(os.path.dirname(_mlx_core.__file__))  # mlx/core.so -> mlx/
_metallib = os.path.join(_mlx_dir, "lib", "mlx.metallib")
if os.path.exists(_metallib):
    datas.append((_metallib, "mlx/lib"))

# uvicorn dynamically imports its loop/protocol backends
hiddenimports += [
    "uvicorn.loops.asyncio",
    "uvicorn.loops.uvloop",
    "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.http.httptools_impl",
    "uvicorn.protocols.websockets.websockets_impl",
    "uvicorn.protocols.websockets.wsproto_impl",
    "uvicorn.lifespan.on",
    "uvicorn.lifespan.off",
    # fastapi / starlette
    "email.mime.text",
    "email.mime.multipart",
]

a = Analysis(
    ["server/server.py"],
    pathex=["server"],          # so `from transcriber import ...` resolves
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    excludes=[
        "tkinter", "matplotlib", "PIL", "cv2",
        "IPython", "jupyter", "notebook",
    ],
    noarchive=False,
)

pyz = PYZ(a.pure)

exe = EXE(
    pyz,
    a.scripts,
    [],
    exclude_binaries=True,      # onedir: keep libs separate for faster startup
    name="transcribe_server",
    debug=False,
    strip=False,
    upx=False,                  # UPX breaks code-signing on macOS
    console=True,
    argv_emulation=False,
    target_arch=None,           # native arch (arm64 on Apple Silicon)
)

coll = COLLECT(
    exe,
    a.binaries,
    a.zipfiles,
    a.datas,
    strip=False,
    upx=False,
    name="transcribe_server",   # output folder: dist/transcribe_server/
)
