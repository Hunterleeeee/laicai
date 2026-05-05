"""Sandboxed Python code execution for the agent.

Uses AST analysis + subprocess isolation + timeout.
No external deps beyond stdlib.
"""

from __future__ import annotations

import ast
import asyncio
import logging
import os
import re
import shutil
import tempfile
from pathlib import Path

logger = logging.getLogger(__name__)

# ── Safety config ──────────────────────────────────────────────

_BANNED_IMPORTS = {
    "os", "subprocess", "sys", "socket", "urllib", "http",
    "ftplib", "pickle", "marshal", "ctypes", "multiprocessing",
}

_BANNED_BUILTINS = {"__import__", "eval", "exec", "compile", "open", "input"}

_MAX_OUTPUT = 12_000  # chars
_TIMEOUT = 30  # seconds


def _is_safe(code: str) -> tuple[bool, str]:
    """Quick AST check for obviously dangerous code."""
    try:
        tree = ast.parse(code)
    except SyntaxError as exc:
        return False, f"Syntax error: {exc}"

    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                mod = alias.name.split(".")[0]
                if mod in _BANNED_IMPORTS:
                    return False, f"Import '{mod}' is blocked for safety"
        elif isinstance(node, ast.ImportFrom):
            mod = (node.module or "").split(".")[0]
            if mod in _BANNED_IMPORTS:
                return False, f"Import '{mod}' is blocked for safety"
        elif isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name) and node.func.id in _BANNED_BUILTINS:
                return False, f"Call to '{node.func.id}' is blocked"
    return True, ""


async def run_python(
    code: str,
    *,
    timeout: float = _TIMEOUT,
    max_output: int = _MAX_OUTPUT,
) -> dict:
    """Run Python code in a temp-directory subprocess.

    Returns dict with keys: ok, stdout, stderr, error, elapsed.
    """
    safe, reason = _is_safe(code)
    if not safe:
        return {"ok": False, "stdout": "", "stderr": "", "error": reason}

    tmpdir = tempfile.mkdtemp(prefix="laicai_exec_")
    try:
        script_path = Path(tmpdir) / "script.py"
        script_path.write_text(code, encoding="utf-8")

        t0 = asyncio.get_event_loop().time()
        proc = await asyncio.create_subprocess_exec(
            shutil.which("python3") or "python",
            str(script_path),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=tmpdir,
            env={**os.environ, "PYTHONDONTWRITEBYTECODE": "1"},
        )
        try:
            stdout_b, stderr_b = await asyncio.wait_for(
                proc.communicate(), timeout=timeout
            )
        except asyncio.TimeoutError:
            proc.kill()
            await proc.wait()
            return {
                "ok": False,
                "stdout": "",
                "stderr": "",
                "error": f"Execution timed out after {timeout}s",
            }

        elapsed = asyncio.get_event_loop().time() - t0
        stdout = stdout_b.decode("utf-8", errors="replace")[:max_output]
        stderr = stderr_b.decode("utf-8", errors="replace")[:max_output]

        return {
            "ok": proc.returncode == 0,
            "stdout": stdout,
            "stderr": stderr,
            "error": "",
            "elapsed": round(elapsed, 2),
        }
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)
