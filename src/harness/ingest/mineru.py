from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import shlex
import shutil
import subprocess

from harness.config import MinerUConfig


@dataclass
class MinerUResult:
    ok: bool
    mode: str
    output_path: Path | None
    message: str


class MinerUAdapter:
    def __init__(self, config: MinerUConfig) -> None:
        self.config = config

    def status(self) -> str:
        if self.config.cli_path and self.config.cli_path.exists():
            return f"cli:{self.config.cli_path}"
        discovered = shutil.which("mineru")
        if discovered:
            return f"cli:{discovered}"
        if self.config.app_path.exists():
            return f"app:{self.config.app_path}"
        return "missing"

    def extract(self, source: Path, output_dir: Path) -> MinerUResult:
        output_dir.mkdir(parents=True, exist_ok=True)
        output_path = output_dir / f"{source.stem}.md"

        cli = self._discover_cli()
        if cli:
            args = [cli, str(source), str(output_path)]
            completed = subprocess.run(args, capture_output=True, text=True)
            ok = completed.returncode == 0 and output_path.exists()
            message = (completed.stdout or completed.stderr).strip() or "mineru cli finished"
            return MinerUResult(ok=ok, mode="cli", output_path=output_path if ok else None, message=message)

        if self.config.command_template:
            command = self.config.command_template.format(
                input=shlex.quote(str(source)),
                output=shlex.quote(str(output_path)),
                output_dir=shlex.quote(str(output_dir)),
            )
            completed = subprocess.run(command, shell=True, capture_output=True, text=True)
            ok = completed.returncode == 0 and output_path.exists()
            message = (completed.stdout or completed.stderr).strip() or "custom MinerU command finished"
            return MinerUResult(ok=ok, mode="template", output_path=output_path if ok else None, message=message)

        return MinerUResult(
            ok=False,
            mode="manual",
            output_path=None,
            message=(
                "No callable MinerU CLI was found. Configure `mineru.cli_path` or "
                "`mineru.command_template` in .harness.toml, or use the GUI app manually."
            ),
        )

    def _discover_cli(self) -> str | None:
        if self.config.cli_path and self.config.cli_path.exists():
            return str(self.config.cli_path)
        discovered = shutil.which("mineru")
        return discovered
