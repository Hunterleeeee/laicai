"""Tests for sandboxed Python code execution."""

import pytest
from harness.agent.code_runner import _is_safe, run_python


# ── AST safety tests ──

def test_safe_code_passes():
    ok, reason = _is_safe("x = 1 + 2\nprint(x)")
    assert ok, reason


def test_banned_import_blocked():
    ok, reason = _is_safe("import os\nos.system('ls')")
    assert not ok
    assert "os" in reason


def test_banned_import_from_blocked():
    ok, reason = _is_safe("from subprocess import run\nrun(['ls'])")
    assert not ok
    assert "subprocess" in reason


def test_banned_builtin_blocked():
    ok, reason = _is_safe("eval('1+1')")
    assert not ok
    assert "eval" in reason


def test_syntax_error_reported():
    ok, reason = _is_safe("def foo(\n")
    assert not ok
    assert "Syntax error" in reason


# ── Execution tests ──

@pytest.mark.asyncio
async def test_run_simple_print():
    result = await run_python("print('hello world')", timeout=5)
    assert result["ok"] is True
    assert "hello world" in result["stdout"]
    assert result["stderr"] == ""


@pytest.mark.asyncio
async def test_run_calculation():
    result = await run_python("print(sum(range(100)))", timeout=5)
    assert result["ok"] is True
    assert "4950" in result["stdout"]


@pytest.mark.asyncio
async def test_run_syntax_error_in_subprocess():
    # AST allows it, but subprocess will fail
    result = await run_python("print(", timeout=5)
    assert result["ok"] is False
    assert "SyntaxError" in result["stderr"] or result["error"]


@pytest.mark.asyncio
async def test_run_timeout():
    result = await run_python("import time\ntime.sleep(60)", timeout=1)
    assert result["ok"] is False
    assert "timed out" in result["error"]


@pytest.mark.asyncio
async def test_run_no_output():
    result = await run_python("x = 42", timeout=5)
    assert result["ok"] is True
    assert result["stdout"] == ""
    assert result["stderr"] == ""


@pytest.mark.asyncio
async def test_run_banned_import_blocked_before_exec():
    result = await run_python("import os\nprint(os.getcwd())", timeout=5)
    assert result["ok"] is False
    assert "blocked" in result["error"].lower()
