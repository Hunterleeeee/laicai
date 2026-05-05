from __future__ import annotations

from collections.abc import Callable, Iterator
from contextlib import contextmanager
from dataclasses import dataclass, field
from html import unescape
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlencode, urlparse
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
import os
import re
import shlex
import shutil
import sys

from harness.config import WebConfig, application_support_dir, load_config

try:
    from playwright.sync_api import Error as PlaywrightError
    from playwright.sync_api import TimeoutError as PlaywrightTimeoutError
    from playwright.sync_api import sync_playwright
except ImportError:  # pragma: no cover - exercised only when dependency is absent
    PlaywrightError = RuntimeError
    PlaywrightTimeoutError = TimeoutError
    sync_playwright = None


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []
        self._skip_depth = 0

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if tag in {"script", "style", "noscript"}:
            self._skip_depth += 1

    def handle_endtag(self, tag: str) -> None:
        if tag in {"script", "style", "noscript"} and self._skip_depth:
            self._skip_depth -= 1

    def handle_data(self, data: str) -> None:
        if self._skip_depth == 0:
            text = data.strip()
            if text:
                self.parts.append(text)

    def text(self) -> str:
        collapsed = " ".join(self.parts)
        return re.sub(r"\s+", " ", collapsed).strip()


@dataclass
class BrowserAction:
    kind: str
    target: str = ""
    value: str = ""
    timeout_ms: int | None = None


@dataclass
class BrowserActionResult:
    kind: str
    target: str = ""
    ok: bool = True
    detail: str = ""


@dataclass
class FetchedPage:
    url: str
    title: str
    text: str
    html: str = ""
    mode: str = "http"
    connection: str | None = None
    actions: list[BrowserActionResult] = field(default_factory=list)


@dataclass
class WebSearchResult:
    title: str
    url: str
    snippet: str = ""


@dataclass
class BrowserRunResult:
    page: FetchedPage
    connection: str = "launch"
    screenshot_path: str | None = None


@dataclass(frozen=True)
class _BrowserLaunchPlan:
    label: str
    channel: str | None = None
    executable_path: Path | None = None


@dataclass
class BrowserDoctorCandidate:
    label: str
    kind: str
    available: bool
    detail: str = ""
    channel: str | None = None
    executable_path: str | None = None


@dataclass
class BrowserDoctorReport:
    browser_enabled: bool
    browser_headless: bool
    configured_channel: str | None
    configured_executable_path: str | None
    configured_cdp_url: str | None
    configured_storage_dir: str | None
    runtime_root: str
    home_dir: str
    tmp_dir: str
    cache_dir: str
    config_dir: str
    state_dir: str
    browsers_dir: str
    profile_dir: str
    playwright_installed: bool
    bundled_browser_files: list[str]
    browser_cache_entries: list[str]
    browser_cache_link_files: list[str]
    browser_cache_issue: str | None
    candidates: list[BrowserDoctorCandidate]
    install_command: str


@dataclass
class BrowserSmokeReport:
    ok: bool
    requested_url: str
    final_url: str
    title: str
    mode: str
    connection: str
    runtime_root: str
    browsers_dir: str
    screenshot_path: str | None = None
    actions: list[BrowserActionResult] = field(default_factory=list)
    text_excerpt: str = ""


def create_configured_web_fetcher(workspace_root: Path | None = None) -> "WebFetcher":
    try:
        config = load_config()
        return WebFetcher(config.web, workspace_root=workspace_root or config.runtime.workspace_root)
    except Exception:
        return WebFetcher(WebConfig(), workspace_root=workspace_root or Path.cwd())


class WebFetcher:
    def __init__(self, config: WebConfig, workspace_root: Path | None = None) -> None:
        self.config = config
        self.workspace_root = (workspace_root or Path.cwd()).expanduser().resolve()

    def fetch(
        self,
        url: str,
        *,
        use_browser: bool | None = None,
        wait_for: str | None = None,
        text_limit: int | None = None,
    ) -> FetchedPage:
        should_use_browser = self.config.browser_enabled if use_browser is None else use_browser
        if should_use_browser:
            try:
                actions = [BrowserAction(kind="wait", target=wait_for)] if wait_for else []
                return self.browse(url, actions=actions, text_limit=text_limit).page
            except RuntimeError:
                if use_browser:
                    raise
        return self._fetch_via_http(url=url, text_limit=text_limit)

    def search(self, query: str, *, max_results: int = 5) -> list[WebSearchResult]:
        normalized_query = query.strip()
        if not normalized_query or max_results < 1:
            return []

        request = Request(
            "https://html.duckduckgo.com/html/",
            data=urlencode({"q": normalized_query}).encode("utf-8"),
            headers={"User-Agent": self.config.user_agent},
        )
        try:
            with urlopen(request, timeout=self.config.timeout_seconds) as response:
                html = response.read().decode("utf-8", errors="ignore")
        except (URLError, HTTPError) as exc:
            raise RuntimeError(f"Search failed for {query}: {exc}") from exc

        results: list[WebSearchResult] = []
        seen_urls: set[str] = set()
        for href, raw_title in re.findall(
            r'<a rel="nofollow" class="result__a" href="([^"]+)">(.+?)</a>',
            html,
        ):
            url = self._normalize_search_result_url(href)
            if not url or url in seen_urls:
                continue
            seen_urls.add(url)
            title = re.sub(r"<[^>]+>", "", raw_title)
            title = unescape(title).strip() or url
            results.append(WebSearchResult(title=title, url=url, snippet=title))
            if len(results) >= max_results:
                break
        return results

    def research(
        self,
        query: str,
        *,
        max_results: int = 3,
        text_limit: int = 300,
        use_browser: bool | None = None,
    ) -> list[WebSearchResult]:
        results = self.search(query, max_results=max_results)
        enriched: list[WebSearchResult] = []
        for result in results:
            title = result.title
            snippet = result.snippet or result.title
            try:
                page = self.fetch(result.url, use_browser=use_browser, text_limit=text_limit)
                title = page.title.strip() or title
                snippet = page.text[:text_limit].strip() or snippet
            except RuntimeError:
                pass
            enriched.append(WebSearchResult(title=title, url=result.url, snippet=snippet))
        return enriched

    def browse(
        self,
        start_url: str,
        *,
        actions: list[BrowserAction] | None = None,
        text_limit: int | None = None,
        screenshot_path: str | Path | None = None,
    ) -> BrowserRunResult:
        if sync_playwright is None:
            raise RuntimeError(
                "Playwright is not installed. Run `python -m pip install playwright` in the project venv first."
            )

        normalized_actions = list(actions or [])
        screenshot_file = self._resolve_screenshot_path(screenshot_path)
        if screenshot_file is not None:
            normalized_actions.append(BrowserAction(kind="screenshot", value=str(screenshot_file)))

        page = None
        try:
            with self._browser_launch_environment():
                with sync_playwright() as playwright:
                    context, close, launch_label, connection = self._open_browser_context(playwright)
                    try:
                        page = context.new_page()
                        timeout_ms = max(1000, int(self.config.timeout_seconds * 1000))
                        page.set_default_timeout(timeout_ms)
                        page.set_default_navigation_timeout(timeout_ms)

                        action_results: list[BrowserActionResult] = [
                            BrowserActionResult(kind="browser", detail=launch_label)
                        ]
                        page.goto(start_url, wait_until="domcontentloaded")
                        action_results.append(BrowserActionResult(kind="goto", target=start_url, detail="domcontentloaded"))
                        self._wait_for_page_ready(page, timeout_ms)

                        for action in normalized_actions:
                            action_results.append(self._run_browser_action(page, action, timeout_ms))

                        html = page.content()
                        title = page.title().strip() or page.url
                        text = self._extract_visible_text(page, html)
                        if text_limit is not None:
                            text = text[:text_limit]
                        current_url = page.url
                    finally:
                        if page is not None:
                            try:
                                page.close()
                            except (PlaywrightError, PlaywrightTimeoutError):
                                pass
                        close()
        except (PlaywrightTimeoutError, PlaywrightError) as exc:
            raise RuntimeError(f"Browser automation failed for {start_url}: {exc}") from exc

        return BrowserRunResult(
            page=FetchedPage(
                url=current_url,
                title=title,
                text=text,
                html=html,
                mode="browser",
                connection=connection,
                actions=action_results,
            ),
            connection=connection,
            screenshot_path=str(screenshot_file) if screenshot_file is not None else None,
        )

    def doctor(self) -> BrowserDoctorReport:
        paths = self._browser_runtime_paths()
        browser_cache_entries = self._browser_cache_entries(paths["browsers_dir"])
        browser_cache_link_files = self._browser_cache_link_files(paths["browsers_dir"])
        bundled_browser_files = [str(path) for path in self._discover_playwright_browser_files(paths["browsers_dir"])]
        browser_cache_issue = self._browser_cache_issue(
            browser_cache_entries=browser_cache_entries,
            browser_cache_link_files=browser_cache_link_files,
            bundled_browser_files=bundled_browser_files,
        )
        candidates = [self._doctor_candidate_status(plan, bundled_browser_files) for plan in self._browser_launch_plans()]
        return BrowserDoctorReport(
            browser_enabled=self.config.browser_enabled,
            browser_headless=self.config.browser_headless,
            configured_channel=self.config.browser_channel,
            configured_executable_path=(str(self.config.browser_executable_path) if self.config.browser_executable_path is not None else None),
            configured_cdp_url=self.config.browser_cdp_url,
            configured_storage_dir=(str(self.config.browser_storage_dir) if self.config.browser_storage_dir is not None else None),
            runtime_root=str(paths["runtime_root"]),
            home_dir=str(paths["home_dir"]),
            tmp_dir=str(paths["tmp_dir"]),
            cache_dir=str(paths["cache_dir"]),
            config_dir=str(paths["config_dir"]),
            state_dir=str(paths["state_dir"]),
            browsers_dir=str(paths["browsers_dir"]),
            profile_dir=str(paths["profile_dir"]),
            playwright_installed=sync_playwright is not None,
            bundled_browser_files=bundled_browser_files,
            browser_cache_entries=browser_cache_entries,
            browser_cache_link_files=browser_cache_link_files,
            browser_cache_issue=browser_cache_issue,
            candidates=candidates,
            install_command=self.install_command(),
        )

    def install_command(self) -> str:
        paths = self._browser_runtime_paths()
        command_parts = [
            f"PLAYWRIGHT_BROWSERS_PATH={shlex.quote(str(paths['browsers_dir']))}",
            f"HOME={shlex.quote(str(paths['home_dir']))}",
            f"TMPDIR={shlex.quote(str(paths['tmp_dir']))}",
            f"XDG_CACHE_HOME={shlex.quote(str(paths['cache_dir']))}",
            f"XDG_CONFIG_HOME={shlex.quote(str(paths['config_dir']))}",
            f"XDG_STATE_HOME={shlex.quote(str(paths['state_dir']))}",
            shlex.quote(sys.executable),
            "-m",
            "playwright",
            "install",
            "chromium",
        ]
        return " ".join(command_parts)

    def install_browser_from(self, source_path: str | Path, *, clear_existing: bool = False) -> BrowserDoctorReport:
        source = Path(source_path).expanduser().resolve()
        if not source.exists():
            raise RuntimeError(f"Browser runtime source does not exist: {source}")
        if not source.is_dir():
            raise RuntimeError(f"Browser runtime source must be a directory: {source}")

        paths = self._browser_runtime_paths()
        browsers_dir = paths["browsers_dir"]
        browsers_dir.mkdir(parents=True, exist_ok=True)

        if source == browsers_dir:
            return self.doctor()

        if self._is_playwright_cache_entry(source):
            entries = [source]
        else:
            entries = [child for child in source.iterdir() if self._is_playwright_cache_entry(child)]
            if not entries:
                raise RuntimeError(
                    f"Browser runtime source does not look like a Playwright cache: {source}. "
                    "Point `--from` at a directory like `ms-playwright/` or `chromium-*/`."
                )

        try:
            if clear_existing and browsers_dir.exists():
                for child in browsers_dir.iterdir():
                    self._delete_path(child)
            for entry in entries:
                self._copy_playwright_entry(entry, browsers_dir / entry.name)
        except OSError as exc:
            raise RuntimeError(f"Failed to import browser runtime from {source}: {exc}") from exc

        report = self.doctor()
        if not report.bundled_browser_files:
            raise RuntimeError(
                "Browser runtime import finished, but no executable Playwright browser was detected. "
                "Run `web doctor` to inspect the imported cache."
            )
        return report

    def smoke(
        self,
        url: str,
        *,
        wait_for: str | None = "body",
        steps: list[BrowserAction] | None = None,
        screenshot_path: str | Path | None = None,
        text_limit: int = 600,
    ) -> BrowserSmokeReport:
        actions = list(steps or [])
        if wait_for:
            actions.insert(0, BrowserAction(kind="wait", target=wait_for))
        result = self.browse(url, actions=actions, screenshot_path=screenshot_path, text_limit=text_limit)
        doctor = self.doctor()
        return BrowserSmokeReport(
            ok=True,
            requested_url=url,
            final_url=result.page.url,
            title=result.page.title,
            mode=result.page.mode,
            connection=result.connection,
            runtime_root=doctor.runtime_root,
            browsers_dir=doctor.browsers_dir,
            screenshot_path=result.screenshot_path,
            actions=result.page.actions,
            text_excerpt=result.page.text[:text_limit],
        )

    def _fetch_via_http(self, url: str, text_limit: int | None = None) -> FetchedPage:
        request = Request(url, headers={"User-Agent": self.config.user_agent})
        try:
            with urlopen(request, timeout=self.config.timeout_seconds) as response:
                html = response.read().decode("utf-8", errors="ignore")
        except (URLError, HTTPError) as exc:
            raise RuntimeError(f"Failed to fetch {url}: {exc}") from exc

        title_match = re.search(r"<title>(.*?)</title>", html, flags=re.IGNORECASE | re.DOTALL)
        title = re.sub(r"\s+", " ", title_match.group(1)).strip() if title_match else url
        text = self._extract_text_from_html(html)
        if text_limit is not None:
            text = text[:text_limit]
        return FetchedPage(url=url, title=title, text=text, html=html, mode="http", connection="http")

    def _open_browser_context(self, playwright) -> tuple[object, Callable[[], None], str, str]:
        if self.config.browser_cdp_url:
            return self._connect_browser_context(playwright, self.config.browser_cdp_url)

        errors: list[str] = []
        for plan in self._browser_launch_plans():
            try:
                context, close = self._launch_browser_context(playwright, plan)
                session_mode = "persistent" if self.config.browser_storage_dir is not None else "ephemeral"
                return context, close, f"{plan.label} [{session_mode}]", "launch"
            except (PlaywrightError, PlaywrightTimeoutError, OSError) as exc:
                errors.append(f"{plan.label}: {self._single_line_error(exc)}")

        if not errors:
            raise RuntimeError("No browser launch candidates are available.")
        raise RuntimeError("Unable to launch a usable browser. Tried: " + " | ".join(errors))

    def _connect_browser_context(self, playwright, endpoint_url: str) -> tuple[object, Callable[[], None], str, str]:
        browser = playwright.chromium.connect_over_cdp(
            endpoint_url,
            timeout=max(1000, int(self.config.timeout_seconds * 1000)),
        )
        created_context = False
        if browser.contexts:
            context = browser.contexts[0]
        else:
            created_context = True
            context = browser.new_context(
                user_agent=self.config.user_agent,
                viewport={"width": 1440, "height": 960},
                ignore_https_errors=True,
            )

        def _close() -> None:
            try:
                if created_context:
                    context.close()
            except Exception:
                pass
            try:
                browser._impl_obj._connection.stop_sync()
            except Exception:
                pass

        return context, _close, f"connected over CDP {endpoint_url}", "cdp"

    def _launch_browser_context(self, playwright, plan: _BrowserLaunchPlan) -> tuple[object, Callable[[], None]]:
        launch_kwargs = self._browser_launch_kwargs(plan)

        if self.config.browser_storage_dir is not None:
            storage_dir = self._browser_storage_dir()
            storage_dir.mkdir(parents=True, exist_ok=True)
            context = playwright.chromium.launch_persistent_context(
                user_data_dir=str(storage_dir),
                user_agent=self.config.user_agent,
                viewport={"width": 1440, "height": 960},
                ignore_https_errors=True,
                **launch_kwargs,
            )
            return context, context.close

        browser = playwright.chromium.launch(**launch_kwargs)
        context = browser.new_context(
            user_agent=self.config.user_agent,
            viewport={"width": 1440, "height": 960},
            ignore_https_errors=True,
        )

        def _close() -> None:
            context.close()
            browser.close()

        return context, _close

    def _browser_launch_plans(self) -> list[_BrowserLaunchPlan]:
        plans: list[_BrowserLaunchPlan] = []
        seen: set[tuple[str, str]] = set()

        def _add(label: str, *, channel: str | None = None, executable_path: Path | None = None) -> None:
            resolved_path = ""
            if executable_path is not None:
                resolved_path = str(executable_path.expanduser().resolve())
            key = (channel or "", resolved_path)
            if key in seen:
                return
            seen.add(key)
            plans.append(
                _BrowserLaunchPlan(
                    label=label,
                    channel=channel,
                    executable_path=Path(resolved_path) if resolved_path else None,
                )
            )

        if self.config.browser_executable_path is not None:
            configured_path = self.config.browser_executable_path.expanduser().resolve()
            _add(f"configured executable {configured_path}", executable_path=configured_path)
        if self.config.browser_channel:
            _add(f"configured channel {self.config.browser_channel}", channel=self.config.browser_channel)

        bundled_paths = self._discover_playwright_browser_files(self._browser_runtime_paths()["browsers_dir"])
        if bundled_paths:
            for bundled_path in bundled_paths:
                _add(f"playwright bundled {bundled_path.name}", executable_path=bundled_path)
        else:
            _add("playwright bundled chromium")

        for label, channel, executable_path in self._detected_browser_targets():
            _add(label, channel=channel, executable_path=executable_path)

        return plans

    def _detected_browser_targets(self) -> list[tuple[str, str | None, Path | None]]:
        candidates = [
            (
                "local Chromium executable",
                None,
                Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
            ),
            (
                "local Google Chrome executable",
                None,
                Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            ),
            (
                "local Google Chrome channel",
                "chrome",
                None,
            ),
            (
                "local Microsoft Edge executable",
                None,
                Path("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
            ),
            (
                "local Microsoft Edge channel",
                "msedge",
                None,
            ),
        ]

        detected: list[tuple[str, str | None, Path | None]] = []
        for label, channel, executable_path in candidates:
            if executable_path is None or executable_path.exists():
                detected.append((label, channel, executable_path))
        return detected

    def _browser_launch_kwargs(self, plan: _BrowserLaunchPlan) -> dict[str, object]:
        launch_kwargs: dict[str, object] = {
            "headless": self.config.browser_headless,
            "args": self._browser_launch_args(),
        }
        if plan.channel:
            launch_kwargs["channel"] = plan.channel
        if plan.executable_path is not None:
            launch_kwargs["executable_path"] = str(plan.executable_path)
            launch_kwargs["chromium_sandbox"] = False
        return launch_kwargs

    def _browser_launch_args(self) -> list[str]:
        return [
            "--no-default-browser-check",
            "--no-first-run",
            "--use-mock-keychain",
            "--disable-breakpad",
            "--disable-crash-reporter",
        ]

    def _browser_runtime_root(self) -> Path:
        candidates = [
            (self.workspace_root / ".laicai-browser").resolve(),
            (application_support_dir() / "browser-runtime").resolve(),
        ]
        for candidate in candidates:
            try:
                candidate.mkdir(parents=True, exist_ok=True)
                return candidate
            except OSError:
                continue
        raise RuntimeError("Unable to create a writable browser runtime directory.")

    def _browser_runtime_paths(self) -> dict[str, Path]:
        runtime_root = self._browser_runtime_root()
        return {
            "runtime_root": runtime_root,
            "home_dir": runtime_root / "home",
            "tmp_dir": runtime_root / "tmp",
            "cache_dir": runtime_root / "cache",
            "config_dir": runtime_root / "config",
            "state_dir": runtime_root / "state",
            "browsers_dir": runtime_root / "ms-playwright",
            "profile_dir": (
                self.config.browser_storage_dir.expanduser().resolve()
                if self.config.browser_storage_dir is not None
                else (runtime_root / "profile").resolve()
            ),
        }

    def _browser_storage_dir(self) -> Path:
        return self._browser_runtime_paths()["profile_dir"]

    @contextmanager
    def _browser_launch_environment(self) -> Iterator[None]:
        paths = self._browser_runtime_paths()
        for path in [
            paths["home_dir"],
            paths["tmp_dir"],
            paths["cache_dir"],
            paths["config_dir"],
            paths["state_dir"],
            paths["browsers_dir"],
            paths["home_dir"] / "Library" / "Application Support",
            paths["home_dir"] / "Library" / "Caches",
            paths["home_dir"] / "Library" / "Logs",
            paths["home_dir"] / "Downloads",
        ]:
            path.mkdir(parents=True, exist_ok=True)

        overrides = {
            "HOME": str(paths["home_dir"]),
            "USERPROFILE": str(paths["home_dir"]),
            "TMPDIR": str(paths["tmp_dir"]),
            "TMP": str(paths["tmp_dir"]),
            "TEMP": str(paths["tmp_dir"]),
            "XDG_CACHE_HOME": str(paths["cache_dir"]),
            "XDG_CONFIG_HOME": str(paths["config_dir"]),
            "XDG_STATE_HOME": str(paths["state_dir"]),
            "PLAYWRIGHT_BROWSERS_PATH": str(paths["browsers_dir"]),
        }
        previous = {key: os.environ.get(key) for key in overrides}

        try:
            for key, value in overrides.items():
                os.environ[key] = value
            yield
        finally:
            for key, old_value in previous.items():
                if old_value is None:
                    os.environ.pop(key, None)
                else:
                    os.environ[key] = old_value

    def _resolve_screenshot_path(self, screenshot_path: str | Path | None) -> Path | None:
        if screenshot_path is None:
            return None
        path = Path(screenshot_path).expanduser()
        if not path.is_absolute():
            path = (self.workspace_root / path).resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        return path

    def _run_browser_action(self, page, action: BrowserAction, default_timeout_ms: int) -> BrowserActionResult:
        timeout_ms = action.timeout_ms or default_timeout_ms
        kind = action.kind.strip().lower()
        target = action.target.strip()
        value = action.value

        if kind == "wait":
            if not target:
                self._wait_for_page_ready(page, timeout_ms)
                return BrowserActionResult(kind="wait", detail="networkidle")
            page.wait_for_selector(target, timeout=timeout_ms)
            return BrowserActionResult(kind="wait", target=target, detail="selector-ready")

        if kind == "click":
            if not target:
                raise RuntimeError("Browser action `click` requires a selector target.")
            page.locator(target).first.click(timeout=timeout_ms)
            self._wait_for_page_ready(page, timeout_ms)
            return BrowserActionResult(kind="click", target=target, detail="clicked")

        if kind == "fill":
            if not target:
                raise RuntimeError("Browser action `fill` requires a selector target.")
            page.locator(target).first.fill(value, timeout=timeout_ms)
            return BrowserActionResult(kind="fill", target=target, detail=f"chars={len(value)}")

        if kind == "press":
            if target:
                page.locator(target).first.press(value, timeout=timeout_ms)
            else:
                page.keyboard.press(value)
            self._wait_for_page_ready(page, timeout_ms)
            return BrowserActionResult(kind="press", target=target, detail=value)

        if kind == "goto":
            if not value:
                raise RuntimeError("Browser action `goto` requires a URL value.")
            page.goto(value, wait_until="domcontentloaded", timeout=timeout_ms)
            self._wait_for_page_ready(page, timeout_ms)
            return BrowserActionResult(kind="goto", target=value, detail="domcontentloaded")

        if kind == "screenshot":
            if not value:
                raise RuntimeError("Browser action `screenshot` requires a file path value.")
            output_path = self._resolve_screenshot_path(value)
            if output_path is None:
                raise RuntimeError("Failed to resolve screenshot path.")
            page.screenshot(path=str(output_path), full_page=True)
            return BrowserActionResult(kind="screenshot", target=str(output_path), detail="saved")

        raise RuntimeError(f"Unsupported browser action: {action.kind}")

    def _wait_for_page_ready(self, page, timeout_ms: int) -> None:
        try:
            page.wait_for_load_state("networkidle", timeout=timeout_ms)
        except PlaywrightTimeoutError:
            try:
                page.wait_for_load_state("load", timeout=timeout_ms)
            except PlaywrightTimeoutError:
                return

    def _extract_visible_text(self, page, html: str) -> str:
        try:
            body_text = page.locator("body").inner_text(timeout=max(1000, int(self.config.timeout_seconds * 1000 / 2)))
            body_text = re.sub(r"\s+", " ", body_text).strip()
            if body_text:
                return body_text
        except (PlaywrightTimeoutError, PlaywrightError):
            pass
        return self._extract_text_from_html(html)

    def _extract_text_from_html(self, html: str) -> str:
        parser = _TextExtractor()
        parser.feed(html)
        return parser.text()

    def _normalize_search_result_url(self, url: str) -> str:
        normalized = url.strip()
        if normalized.startswith("//"):
            normalized = f"https:{normalized}"
        elif normalized.startswith("/"):
            normalized = f"https://duckduckgo.com{normalized}"

        parsed = urlparse(normalized)
        if parsed.netloc.endswith("duckduckgo.com") and parsed.path.startswith("/l/"):
            redirected = parse_qs(parsed.query).get("uddg", [""])[0]
            if redirected:
                return unquote(redirected)
        return normalized

    def _channel_expected_executable(self, channel: str) -> Path | None:
        mapping = {
            "chrome": Path("/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"),
            "chromium": Path("/Applications/Chromium.app/Contents/MacOS/Chromium"),
            "msedge": Path("/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"),
        }
        return mapping.get(channel.strip().lower())

    def _discover_playwright_browser_files(self, browsers_dir: Path) -> list[Path]:
        if not browsers_dir.exists():
            return []
        interesting_names = {
            "Chromium",
            "chrome",
            "chrome-headless-shell",
            "Google Chrome",
            "Google Chrome for Testing",
            "Microsoft Edge",
        }
        discovered: list[Path] = []
        for path in sorted(browsers_dir.rglob("*")):
            if path.is_file() and path.name in interesting_names and os.access(path, os.X_OK):
                discovered.append(path)
        return discovered[:32]

    def _browser_cache_entries(self, browsers_dir: Path) -> list[str]:
        if not browsers_dir.exists():
            return []
        entries: list[str] = []
        for child in sorted(browsers_dir.iterdir()):
            if child.name.startswith("."):
                continue
            entries.append(child.name)
        return entries

    def _browser_cache_link_files(self, browsers_dir: Path) -> list[str]:
        links_dir = browsers_dir / ".links"
        if not links_dir.exists() or not links_dir.is_dir():
            return []
        return [str(path) for path in sorted(links_dir.iterdir()) if path.is_file()][:32]

    def _browser_cache_issue(
        self,
        *,
        browser_cache_entries: list[str],
        browser_cache_link_files: list[str],
        bundled_browser_files: list[str],
    ) -> str | None:
        if bundled_browser_files:
            return None
        if browser_cache_link_files and not browser_cache_entries:
            return "Playwright cache only contains .links metadata and no browser payload directories."
        if browser_cache_entries and not bundled_browser_files:
            return "Playwright cache has browser directories, but no executable browser binary was detected."
        if browser_cache_link_files:
            return "Playwright cache metadata exists, but no executable browser binary was detected."
        return "Playwright cache is empty."

    def _doctor_candidate_status(self, plan: _BrowserLaunchPlan, bundled_browser_files: list[str]) -> BrowserDoctorCandidate:
        executable_path = str(plan.executable_path) if plan.executable_path is not None else None
        if plan.executable_path is not None:
            return BrowserDoctorCandidate(
                label=plan.label,
                kind="executable",
                available=plan.executable_path.exists(),
                detail=executable_path or "",
                channel=plan.channel,
                executable_path=executable_path,
            )
        if plan.channel:
            expected = self._channel_expected_executable(plan.channel)
            detail = (
                f"expected at {expected}"
                if expected is not None
                else "expected executable path unknown on this platform"
            )
            return BrowserDoctorCandidate(
                label=plan.label,
                kind="channel",
                available=(expected.exists() if expected is not None else False),
                detail=detail,
                channel=plan.channel,
            )
        return BrowserDoctorCandidate(
            label=plan.label,
            kind="bundled",
            available=bool(bundled_browser_files),
            detail=f"{len(bundled_browser_files)} executable(s) discovered in local Playwright cache",
        )

    def _is_playwright_cache_entry(self, path: Path) -> bool:
        if not path.is_dir():
            return False
        name = path.name.lower()
        if name.startswith(("chromium-", "chromium_headless_shell-", "firefox-", "webkit-")):
            return True
        return bool(self._discover_playwright_browser_files(path))

    def _copy_playwright_entry(self, source: Path, destination: Path) -> None:
        if destination.exists():
            self._delete_path(destination)
        shutil.copytree(source, destination, symlinks=True)

    def _delete_path(self, path: Path) -> None:
        if path.is_symlink() or path.is_file():
            path.unlink()
            return
        shutil.rmtree(path)

    def _single_line_error(self, exc: BaseException) -> str:
        text = str(exc).strip() or exc.__class__.__name__
        if "Browser logs:" in text:
            text = text.split("Browser logs:", 1)[0].strip()
        if "Looks like Playwright was just installed or updated." in text:
            prefix = text.split("╔", 1)[0].strip()
            text = f"{prefix} Run `playwright install chromium` in the configured runtime cache."
        text = re.sub(r"\s+", " ", text).strip()
        return text[:400]


def parse_browser_action(raw: str) -> BrowserAction:
    text = raw.strip()
    if not text:
        raise ValueError("Empty browser step.")

    if "=" in text:
        kind, remainder = text.split("=", 1)
    else:
        kind, remainder = text, ""

    kind = kind.strip().lower()
    remainder = remainder.strip()

    if kind in {"wait", "click"}:
        target = remainder
        value = ""
    elif kind == "goto":
        target = ""
        value = remainder
        if not value:
            raise ValueError(f"Browser step `{raw}` requires a target URL.")
    elif kind in {"fill", "press"}:
        target, separator, value = remainder.partition("::")
        if kind == "press" and not separator:
            target = ""
            value = remainder
        if not value:
            raise ValueError(f"Browser step `{raw}` must use `selector::value` format.")
    elif kind == "screenshot":
        target = ""
        value = remainder
        if not value:
            raise ValueError(f"Browser step `{raw}` requires a file path.")
    else:
        raise ValueError(f"Unsupported browser step: {raw}")

    return BrowserAction(kind=kind, target=target.strip(), value=value.strip())
