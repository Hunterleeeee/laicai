from __future__ import annotations

from pathlib import Path
import os
import re
import sys
import tomllib

from pydantic import BaseModel, Field, field_validator


DEFAULT_CONFIG = Path(".harness.toml")
APP_NAME = "Laicai"
APP_SUPPORT_ENV_VAR = "LAICAI_HOME"
APP_SUPPORT_FALLBACK_DIRNAME = ".laicai"
APP_SUPPORT_TMP_DIR = Path("/tmp") / APP_NAME
DEFAULT_BROWSER_CDP_URL = "http://127.0.0.1:9222"
_APP_SUPPORT_CACHE_KEY: tuple[str, str] | None = None
_APP_SUPPORT_CACHE_DIR: Path | None = None
_APP_SUPPORT_CACHE_REASON: str | None = None
_LEGACY_OPTIONAL_TOML_KEYS = {
    "request_timeout_seconds",
    "max_output_tokens",
    "ollama_num_ctx",
    "web_text_chars",
    "vault_context_chars",
    "vault_context_limit",
}


def _load_toml_compat(path: Path) -> dict[str, object]:
    try:
        with path.open("rb") as fh:
            return tomllib.load(fh)
    except tomllib.TOMLDecodeError:
        text = path.read_text(encoding="utf-8")
        cleaned_lines: list[str] = []
        for line in text.splitlines():
            match = re.match(r"^(\s*)([A-Za-z0-9_]+)(\s*=\s*)None\.?\s*$", line)
            if match and match.group(2) in _LEGACY_OPTIONAL_TOML_KEYS:
                continue
            cleaned_lines.append(line)
        return tomllib.loads("\n".join(cleaned_lines))


def _desktop_default_vault_candidates() -> list[Path]:
    return [
        Path.home() / "Documents" / "Laicai Vault",
        Path.home() / "Documents" / "Obsidian",
        Path.home() / "Obsidian",
    ]


class RuntimeConfig(BaseModel):
    profile: str = "balanced-lite"
    workspace_root: Path = Field(default_factory=lambda: Path.cwd())
    request_timeout_seconds: int | None = None
    max_output_tokens: int | None = None
    ollama_num_ctx: int | None = None
    web_text_chars: int | None = None
    vault_context_chars: int | None = None
    vault_context_limit: int | None = None

    def resolved_request_timeout_seconds(self) -> int:
        if self.request_timeout_seconds is not None:
            return self.request_timeout_seconds
        if self.profile == "quiet":
            return 25
        if self.profile == "balanced-lite":
            return 40
        return 60

    def resolved_max_output_tokens(self) -> int:
        if self.max_output_tokens is not None:
            return self.max_output_tokens
        if self.profile == "quiet":
            return 96
        if self.profile == "balanced-lite":
            return 160
        return 220

    def resolved_ollama_num_ctx(self) -> int:
        if self.ollama_num_ctx is not None:
            return self.ollama_num_ctx
        if self.profile == "quiet":
            return 1024
        if self.profile == "balanced-lite":
            return 1536
        return 2048

    def resolved_web_text_chars(self) -> int:
        if self.web_text_chars is not None:
            return self.web_text_chars
        if self.profile == "quiet":
            return 1200
        if self.profile == "balanced-lite":
            return 1600
        return 2500

    def resolved_vault_context_chars(self) -> int:
        if self.vault_context_chars is not None:
            return self.vault_context_chars
        if self.profile == "quiet":
            return 900
        if self.profile == "balanced-lite":
            return 1200
        return 1800

    def resolved_vault_context_limit(self) -> int:
        if self.vault_context_limit is not None:
            return self.vault_context_limit
        if self.profile == "quiet":
            return 3
        if self.profile == "balanced-lite":
            return 3
        return 5


class VaultConfig(BaseModel):
    path: Path
    inbox_dir: str = "00 Inbox"
    sources_dir: str = "01 Sources"
    notes_dir: str = "02 Notes"
    memory_dir: str = "06 Memory"


class MinerUConfig(BaseModel):
    app_path: Path = Path("/Applications/MinerU.app/Contents/MacOS/MinerU")
    enabled: bool = True
    cli_path: Path | None = None
    command_template: str | None = None

    @field_validator("cli_path", "command_template", mode="before")
    @classmethod
    def _empty_to_none(cls, value: object) -> object:
        if value == "":
            return None
        return value


class WebConfig(BaseModel):
    user_agent: str = "Laicai/0.1 (+local-agent)"
    timeout_seconds: int = 20
    browser_enabled: bool = True
    browser_channel: str | None = None
    browser_executable_path: Path | None = None
    browser_cdp_url: str | None = DEFAULT_BROWSER_CDP_URL
    browser_headless: bool = True
    browser_storage_dir: Path | None = None

    @field_validator("browser_channel", "browser_cdp_url", mode="before")
    @classmethod
    def _empty_browser_strings_to_none(cls, value: object) -> object:
        if value == "":
            return None
        return value

    @field_validator("browser_executable_path", "browser_storage_dir", mode="before")
    @classmethod
    def _empty_paths_to_none(cls, value: object) -> object:
        if value == "":
            return None
        return value


class StorageConfig(BaseModel):
    sqlite_path: Path = Field(default_factory=lambda: state_store_db_path())


class SkillsConfig(BaseModel):
    dirs: list[Path] = Field(default_factory=lambda: [Path("skills")])


class ImageGenerationConfig(BaseModel):
    enabled: bool = False
    provider: str = "comfyui"
    endpoint: str = "http://127.0.0.1:8000"
    timeout_seconds: int = 600
    output_dir: Path = Path("~/Documents/ComfyUI/output")
    filename_prefix: str = "laicai_qwen_image"
    width: int = 512
    height: int = 512
    steps: int = 8
    cfg: float = 1.0
    sampler: str = "euler"
    scheduler: str = "simple"
    shift: float = 3.1
    batch_size: int = 1
    unet: str = "qwen-image-Q3_K_M.gguf"
    text_encoder: str = "qwen_2.5_vl_7b_fp8_scaled.safetensors"
    vae: str = "qwen_image_vae.safetensors"
    lora: str = "Qwen-Image-Lightning-8steps-V2.0-bf16.safetensors"
    lora_strength: float = 1.0


class ModelConfig(BaseModel):
    provider: str = "local-openai-compatible"
    endpoint: str = "http://127.0.0.1:11434/v1"
    model: str = "qwen3.5:9b"
    api_key: str = "ollama"
    api_key_env: str | None = None


class HarnessConfig(BaseModel):
    runtime: RuntimeConfig = Field(default_factory=RuntimeConfig)
    vault: VaultConfig
    mineru: MinerUConfig = Field(default_factory=MinerUConfig)
    web: WebConfig = Field(default_factory=WebConfig)
    storage: StorageConfig = Field(default_factory=StorageConfig)
    skills: SkillsConfig = Field(default_factory=SkillsConfig)
    image_generation: ImageGenerationConfig = Field(default_factory=ImageGenerationConfig)
    model: ModelConfig = Field(default_factory=ModelConfig)

    def resolve_paths(self, base_dir: Path) -> "HarnessConfig":
        self.runtime.workspace_root = (base_dir / self.runtime.workspace_root).resolve() if not self.runtime.workspace_root.is_absolute() else self.runtime.workspace_root.resolve()
        self.vault.path = self.vault.path.expanduser().resolve()
        self.mineru.app_path = self.mineru.app_path.expanduser()
        if self.mineru.cli_path is not None:
            self.mineru.cli_path = self.mineru.cli_path.expanduser()
        if self.web.browser_executable_path is not None:
            self.web.browser_executable_path = (
                (base_dir / self.web.browser_executable_path).resolve()
                if not self.web.browser_executable_path.is_absolute()
                else self.web.browser_executable_path.expanduser().resolve()
            )
        if self.web.browser_storage_dir is not None:
            self.web.browser_storage_dir = (
                (base_dir / self.web.browser_storage_dir).resolve()
                if not self.web.browser_storage_dir.is_absolute()
                else self.web.browser_storage_dir.expanduser().resolve()
            )
        self.storage.sqlite_path = (base_dir / self.storage.sqlite_path).resolve() if not self.storage.sqlite_path.is_absolute() else self.storage.sqlite_path.resolve()
        self.skills.dirs = [
            (base_dir / skill_dir).resolve() if not skill_dir.is_absolute() else skill_dir.resolve()
            for skill_dir in self.skills.dirs
        ]
        self.image_generation.output_dir = self.image_generation.output_dir.expanduser()
        return self


def resource_root() -> Path:
    bundled_root = getattr(sys, "_MEIPASS", None)
    if bundled_root:
        return Path(bundled_root)
    return Path(__file__).resolve().parents[3]


def _default_application_support_dir() -> Path:
    return (Path.home() / "Library" / "Application Support" / APP_NAME).resolve()


def _fallback_application_support_dir() -> Path:
    return (Path.home() / APP_SUPPORT_FALLBACK_DIRNAME).resolve()


def _documents_application_support_dir() -> Path:
    return (Path.home() / "Documents" / APP_NAME).resolve()


def _tmp_application_support_dir() -> Path:
    return APP_SUPPORT_TMP_DIR


def _ensure_directory_writable(path: Path) -> None:
    path.mkdir(parents=True, exist_ok=True)
    probe = path / ".write-test"
    probe.write_text("ok", encoding="utf-8")
    probe.unlink(missing_ok=True)


def application_support_status() -> tuple[Path, str]:
    override = os.getenv(APP_SUPPORT_ENV_VAR, "").strip()
    cache_key = (str(Path.home()), override)
    global _APP_SUPPORT_CACHE_KEY, _APP_SUPPORT_CACHE_DIR, _APP_SUPPORT_CACHE_REASON
    if _APP_SUPPORT_CACHE_KEY == cache_key and _APP_SUPPORT_CACHE_DIR is not None and _APP_SUPPORT_CACHE_REASON is not None:
        return _APP_SUPPORT_CACHE_DIR, _APP_SUPPORT_CACHE_REASON

    if override:
        resolved = Path(override).expanduser().resolve()
        _ensure_directory_writable(resolved)
        reason = f"env:{APP_SUPPORT_ENV_VAR}"
        _APP_SUPPORT_CACHE_KEY = cache_key
        _APP_SUPPORT_CACHE_DIR = resolved
        _APP_SUPPORT_CACHE_REASON = reason
        return resolved, reason

    primary = _default_application_support_dir()
    try:
        _ensure_directory_writable(primary)
        reason = "default"
        _APP_SUPPORT_CACHE_KEY = cache_key
        _APP_SUPPORT_CACHE_DIR = primary
        _APP_SUPPORT_CACHE_REASON = reason
        return primary, reason
    except OSError:
        fallback = _fallback_application_support_dir()
        try:
            _ensure_directory_writable(fallback)
            reason = "fallback-home"
            _APP_SUPPORT_CACHE_KEY = cache_key
            _APP_SUPPORT_CACHE_DIR = fallback
            _APP_SUPPORT_CACHE_REASON = reason
            return fallback, reason
        except OSError:
            last_resort = _documents_application_support_dir()
            try:
                _ensure_directory_writable(last_resort)
                reason = "fallback-documents"
                _APP_SUPPORT_CACHE_KEY = cache_key
                _APP_SUPPORT_CACHE_DIR = last_resort
                _APP_SUPPORT_CACHE_REASON = reason
                return last_resort, reason
            except OSError:
                tmp_dir = _tmp_application_support_dir()
                _ensure_directory_writable(tmp_dir)
                reason = "fallback-tmp"
                _APP_SUPPORT_CACHE_KEY = cache_key
                _APP_SUPPORT_CACHE_DIR = tmp_dir
                _APP_SUPPORT_CACHE_REASON = reason
                return tmp_dir, reason


def application_support_dir() -> Path:
    path, _ = application_support_status()
    return path


def desktop_config_path() -> Path:
    return application_support_dir() / ".harness.toml"


def state_store_db_path() -> Path:
    return application_support_dir() / "data" / "memory" / "harness.db"


def session_store_db_path() -> Path:
    return application_support_dir() / "data" / "memory" / "sessions.db"


def desktop_user_skills_dir() -> Path:
    return application_support_dir() / "skills"


def bundled_skills_dir() -> Path:
    return resource_root() / "skills"


def desktop_default_vault_path() -> Path:
    env_path = os.getenv("LAICAI_VAULT_PATH", "").strip()
    if env_path:
        return Path(env_path).expanduser().resolve()
    candidates = _desktop_default_vault_candidates()
    for candidate in candidates:
        resolved = candidate.expanduser().resolve()
        if resolved.exists():
            return resolved
    return candidates[0].expanduser().resolve()


def default_desktop_config() -> HarnessConfig:
    app_home = application_support_dir()
    return HarnessConfig(
        runtime=RuntimeConfig(workspace_root=app_home),
        vault=VaultConfig(path=desktop_default_vault_path()),
        web=WebConfig(browser_cdp_url=DEFAULT_BROWSER_CDP_URL),
        storage=StorageConfig(sqlite_path=state_store_db_path()),
        skills=SkillsConfig(dirs=[desktop_user_skills_dir()]),
        image_generation=ImageGenerationConfig(),
        model=ModelConfig(
            provider="local-openai-compatible",
            endpoint="http://127.0.0.1:11434/v1",
            model="auto",
            api_key="ollama",
            api_key_env=None,
        ),
    ).resolve_paths(app_home)


def load_config(config_path: Path | None = None) -> HarnessConfig:
    path = (config_path or DEFAULT_CONFIG).expanduser()
    if not path.exists():
        return HarnessConfig(vault=VaultConfig(path=desktop_default_vault_path())).resolve_paths(Path.cwd())

    raw = _load_toml_compat(path)

    config = HarnessConfig.model_validate(raw)
    return config.resolve_paths(path.parent.resolve())


def load_desktop_config(config_path: Path | None = None) -> HarnessConfig:
    path = (config_path or desktop_config_path()).expanduser()
    app_home = application_support_dir()
    if not path.exists():
        config = default_desktop_config()
    else:
        raw = _load_toml_compat(path)
        config = HarnessConfig.model_validate(raw).resolve_paths(path.parent.resolve())

    user_skill_dir = desktop_user_skills_dir().resolve()
    bundled_skill_dir = bundled_skills_dir().resolve()
    normalized_skill_dirs: list[Path] = []
    for skill_dir in config.skills.dirs:
        resolved = skill_dir.expanduser().resolve()
        if resolved not in normalized_skill_dirs:
            normalized_skill_dirs.append(resolved)
    if user_skill_dir not in normalized_skill_dirs:
        normalized_skill_dirs.insert(0, user_skill_dir)
    if bundled_skill_dir.exists() and bundled_skill_dir not in normalized_skill_dirs:
        normalized_skill_dirs.append(bundled_skill_dir)
    config.skills.dirs = normalized_skill_dirs

    if not config.storage.sqlite_path.is_absolute():
        config.storage.sqlite_path = (app_home / config.storage.sqlite_path).resolve()
    return config


def desktop_user_config(config: HarnessConfig) -> HarnessConfig:
    clone = HarnessConfig.model_validate(config.model_dump())
    clone.runtime.workspace_root = Path(".")
    clone.storage.sqlite_path = Path("data/memory/harness.db")
    clone.skills.dirs = [Path("skills")]
    clone.image_generation.output_dir = Path("~/Documents/ComfyUI/output")
    return clone


def render_config_toml(config: HarnessConfig) -> str:
    def _toml_string(value: object) -> str:
        escaped = str(value).replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'

    def _toml_array(values: list[object]) -> str:
        return "[" + ", ".join(_toml_string(item) for item in values) + "]"

    def _toml_optional_int(key: str, value: int | None) -> str:
        return f"{key} = {value}\n" if value is not None else ""

    return (
        "[runtime]\n"
        f"profile = {_toml_string(config.runtime.profile)}\n"
        f"workspace_root = {_toml_string(config.runtime.workspace_root)}\n"
        f"{_toml_optional_int('request_timeout_seconds', config.runtime.request_timeout_seconds)}"
        f"{_toml_optional_int('max_output_tokens', config.runtime.max_output_tokens)}"
        f"{_toml_optional_int('ollama_num_ctx', config.runtime.ollama_num_ctx)}"
        f"{_toml_optional_int('web_text_chars', config.runtime.web_text_chars)}"
        f"{_toml_optional_int('vault_context_chars', config.runtime.vault_context_chars)}"
        f"{_toml_optional_int('vault_context_limit', config.runtime.vault_context_limit)}\n"
        "[vault]\n"
        f"path = {_toml_string(config.vault.path)}\n"
        f"inbox_dir = {_toml_string(config.vault.inbox_dir)}\n"
        f"sources_dir = {_toml_string(config.vault.sources_dir)}\n"
        f"notes_dir = {_toml_string(config.vault.notes_dir)}\n"
        f"memory_dir = {_toml_string(config.vault.memory_dir)}\n\n"
        "[mineru]\n"
        f"app_path = {_toml_string(config.mineru.app_path)}\n"
        f"enabled = {'true' if config.mineru.enabled else 'false'}\n"
        f"cli_path = {_toml_string(config.mineru.cli_path or '')}\n"
        f"command_template = {_toml_string(config.mineru.command_template or '')}\n\n"
        "[web]\n"
        f"user_agent = {_toml_string(config.web.user_agent)}\n"
        f"timeout_seconds = {config.web.timeout_seconds}\n"
        f"browser_enabled = {'true' if config.web.browser_enabled else 'false'}\n"
        f"browser_channel = {_toml_string(config.web.browser_channel or '')}\n"
        f"browser_executable_path = {_toml_string(config.web.browser_executable_path or '')}\n"
        f"browser_cdp_url = {_toml_string(config.web.browser_cdp_url or '')}\n"
        f"browser_headless = {'true' if config.web.browser_headless else 'false'}\n"
        f"browser_storage_dir = {_toml_string(config.web.browser_storage_dir or '')}\n\n"
        "[storage]\n"
        f"sqlite_path = {_toml_string(config.storage.sqlite_path)}\n\n"
        "[skills]\n"
        f"dirs = {_toml_array(config.skills.dirs)}\n\n"
        "[image_generation]\n"
        f"enabled = {'true' if config.image_generation.enabled else 'false'}\n"
        f"provider = {_toml_string(config.image_generation.provider)}\n"
        f"endpoint = {_toml_string(config.image_generation.endpoint)}\n"
        f"timeout_seconds = {config.image_generation.timeout_seconds}\n"
        f"output_dir = {_toml_string(config.image_generation.output_dir)}\n"
        f"filename_prefix = {_toml_string(config.image_generation.filename_prefix)}\n"
        f"width = {config.image_generation.width}\n"
        f"height = {config.image_generation.height}\n"
        f"steps = {config.image_generation.steps}\n"
        f"cfg = {config.image_generation.cfg}\n"
        f"sampler = {_toml_string(config.image_generation.sampler)}\n"
        f"scheduler = {_toml_string(config.image_generation.scheduler)}\n"
        f"shift = {config.image_generation.shift}\n"
        f"batch_size = {config.image_generation.batch_size}\n"
        f"unet = {_toml_string(config.image_generation.unet)}\n"
        f"text_encoder = {_toml_string(config.image_generation.text_encoder)}\n"
        f"vae = {_toml_string(config.image_generation.vae)}\n"
        f"lora = {_toml_string(config.image_generation.lora)}\n"
        f"lora_strength = {config.image_generation.lora_strength}\n\n"
        "[model]\n"
        f"provider = {_toml_string(config.model.provider)}\n"
        f"endpoint = {_toml_string(config.model.endpoint)}\n"
        f"model = {_toml_string(config.model.model)}\n"
        f"api_key = {_toml_string(config.model.api_key)}\n"
        f"api_key_env = {_toml_string(config.model.api_key_env or '')}\n"
    )


def save_config(config: HarnessConfig, path: Path) -> Path:
    path = path.expanduser().resolve()
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(render_config_toml(config), encoding="utf-8")
    return path


def save_desktop_config(config: HarnessConfig, path: Path | None = None) -> Path:
    return save_config(desktop_user_config(config), path or desktop_config_path())
