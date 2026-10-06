"""Container entrypoint: restart must not re-run init on an existing data dir."""

from __future__ import annotations

import os
import stat
import subprocess
from pathlib import Path

import pytest

posix_only = pytest.mark.skipif(os.name != "posix", reason="entrypoint is bash")

ROOT = Path(__file__).resolve().parents[3]
ENTRYPOINT = ROOT / "docker" / "docker-entrypoint.sh"

_STUB = """#!/bin/bash
printf '%s\\n' "$*" >> "$OCTOP_STUB_LOG"
if [[ "${1:-}" == "init" && -n "${OCTOP_STUB_FAIL_FILE:-}" && -f "$OCTOP_STUB_FAIL_FILE" ]]; then
  cat "$OCTOP_STUB_FAIL_FILE" >&2
  rm -f "$OCTOP_STUB_FAIL_FILE"
  exit 1
fi
exit 0
"""


def _run(
    tmp_path: Path,
    *,
    fail_message: str | None = None,
    extra_env: dict[str, str] | None = None,
) -> tuple[subprocess.CompletedProcess[str], str]:
    home = tmp_path / "data"
    home.mkdir(exist_ok=True)
    bindir = tmp_path / "bin"
    bindir.mkdir()
    stub = bindir / "octop"
    stub.write_text(_STUB, encoding="utf-8")
    stub.chmod(stub.stat().st_mode | stat.S_IEXEC)

    log = tmp_path / "octop-calls.log"
    env = os.environ.copy()
    env["HOME"] = str(home)
    env.pop("OCTOP_HOME", None)
    env["PATH"] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
    env["OCTOP_STUB_LOG"] = str(log)
    env.pop("OCTOP_DEFAULT_PASSWORD", None)
    env.pop("OCTOP_ADMIN_USERNAME", None)
    env.pop("OCTOP_ADMIN_DISPLAY_NAME", None)
    if fail_message is not None:
        fail_file = tmp_path / "fail.txt"
        fail_file.write_text(fail_message, encoding="utf-8")
        env["OCTOP_STUB_FAIL_FILE"] = str(fail_file)
    if extra_env:
        env.update(extra_env)

    result = subprocess.run(
        ["bash", str(ENTRYPOINT)],
        cwd=tmp_path,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )
    stub_log = log.read_text(encoding="utf-8") if log.is_file() else ""
    return result, stub_log


@posix_only
def test_restart_skips_init_when_data_dir_is_not_empty(tmp_path: Path) -> None:
    data = tmp_path / "data" / ".octop"
    data.mkdir(parents=True)
    (data / "config.json").write_text("{}", encoding="utf-8")

    result, stub_log = _run(tmp_path)
    output = result.stdout + result.stderr

    assert result.returncode == 0, output
    assert "跳过初始化" in output
    assert "首次启动" not in output
    assert "密码" not in output
    assert "init " not in stub_log
    assert "run --host 0.0.0.0 --port 8088" in stub_log
    assert not (data / "credential.txt").exists()


@posix_only
def test_empty_data_dir_still_runs_init(tmp_path: Path) -> None:
    result, stub_log = _run(tmp_path)
    output = result.stdout + result.stderr
    calls = stub_log.splitlines()

    assert result.returncode == 0, output
    assert "首次启动" in output
    assert calls[0].startswith("init --yes ")
    assert "--force" not in calls[0]
    assert calls[1] == "run --host 0.0.0.0 --port 8088"
    assert (tmp_path / "data" / ".octop" / "credential.txt").is_file()


@posix_only
def test_existing_directory_without_sqlite_file_is_not_first_boot(tmp_path: Path) -> None:
    """PostgreSQL installs never create octop.db; restart must still skip init."""
    data = tmp_path / "data" / ".octop"
    data.mkdir(parents=True)
    (data / "credential.txt").write_text("kept\n", encoding="utf-8")

    result, stub_log = _run(tmp_path)
    output = result.stdout + result.stderr

    assert result.returncode == 0, output
    assert "init " not in stub_log
    assert (data / "credential.txt").read_text(encoding="utf-8") == "kept\n"


@posix_only
def test_password_rejection_retries_with_force(tmp_path: Path) -> None:
    result, stub_log = _run(
        tmp_path,
        fail_message="error: password is too common\n",
        extra_env={"OCTOP_DEFAULT_PASSWORD": "octop123"},
    )
    output = result.stdout + result.stderr
    calls = stub_log.splitlines()

    assert result.returncode == 0, output
    assert "改用随机密码重试" in output
    assert "octop123" in calls[0]
    assert "--force" not in calls[0]
    assert "--force" in calls[1]
    assert "octop123" not in calls[1]
    assert calls[2] == "run --host 0.0.0.0 --port 8088"
    credential = (tmp_path / "data" / ".octop" / "credential.txt").read_text(encoding="utf-8")
    assert "octop123" not in credential


@posix_only
def test_non_password_init_failure_is_not_retried(tmp_path: Path) -> None:
    result, stub_log = _run(
        tmp_path,
        fail_message="error: /data/.octop already exists and is not empty. Use --force to reset.\n",
    )
    output = result.stdout + result.stderr
    calls = stub_log.splitlines()

    assert result.returncode != 0
    assert "already exists" in output
    assert "改用随机密码重试" not in output
    assert len(calls) == 1
    assert calls[0].startswith("init ")
    assert "--force" not in calls[0]
