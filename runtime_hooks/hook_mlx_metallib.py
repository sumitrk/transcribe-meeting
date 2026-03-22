# PyInstaller runtime hook — runs before any user imports.
#
# mlx uses dladdr() on libmlx.dylib to find itself, then looks for
# mlx.metallib in that SAME directory (_internal/).
# But collect_all('mlx') places the metallib at _internal/mlx/lib/mlx.metallib.
# This hook symlinks (or copies) it to _internal/mlx.metallib so mlx finds it.

import os
import sys

_internal = getattr(sys, "_MEIPASS", None)
if _internal:
    src = os.path.join(_internal, "mlx", "lib", "mlx.metallib")
    dst = os.path.join(_internal, "mlx.metallib")
    if os.path.exists(src) and not os.path.exists(dst):
        try:
            os.symlink(src, dst)
        except Exception:
            try:
                import shutil
                shutil.copy2(src, dst)
            except Exception:
                pass
