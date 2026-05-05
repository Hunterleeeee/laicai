from __future__ import annotations

from pathlib import Path
import shutil
import subprocess


def open_with_app(app_name: str, target: Path) -> subprocess.CompletedProcess[str]:
    opener = shutil.which("open")
    if opener is None:
        raise RuntimeError("macOS `open` command is unavailable.")
    return subprocess.run([opener, "-a", app_name, str(target)], capture_output=True, text=True)
