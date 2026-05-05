from __future__ import annotations

import json
import time
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from harness.config import ImageGenerationConfig


class ComfyUIImageGenerator:
    def __init__(self, config: ImageGenerationConfig) -> None:
        self.config = config
        self.endpoint = config.endpoint.rstrip("/")

    def generate(
        self,
        prompt: str,
        *,
        negative_prompt: str = "",
        width: int | None = None,
        height: int | None = None,
        steps: int | None = None,
        seed: int | None = None,
    ) -> Path:
        prompt_id = self._queue_prompt(
            prompt=prompt,
            negative_prompt=negative_prompt,
            width=width or self.config.width,
            height=height or self.config.height,
            steps=steps or self.config.steps,
            seed=seed or int(time.time()),
        )
        filename = self._wait_for_image(prompt_id)
        image_path = self.config.output_dir.expanduser() / filename
        return image_path

    def _queue_prompt(
        self,
        *,
        prompt: str,
        negative_prompt: str,
        width: int,
        height: int,
        steps: int,
        seed: int,
    ) -> str:
        payload = {
            "prompt": {
                "1": {"class_type": "UnetLoaderGGUF", "inputs": {"unet_name": self.config.unet}},
                "2": {
                    "class_type": "CLIPLoader",
                    "inputs": {
                        "clip_name": self.config.text_encoder,
                        "type": "qwen_image",
                        "device": "default",
                    },
                },
                "3": {"class_type": "VAELoader", "inputs": {"vae_name": self.config.vae}},
                "4": {
                    "class_type": "LoraLoaderModelOnly",
                    "inputs": {
                        "model": ["1", 0],
                        "lora_name": self.config.lora,
                        "strength_model": self.config.lora_strength,
                    },
                },
                "5": {
                    "class_type": "ModelSamplingAuraFlow",
                    "inputs": {"model": ["4", 0], "shift": self.config.shift},
                },
                "6": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["2", 0], "text": prompt}},
                "7": {"class_type": "CLIPTextEncode", "inputs": {"clip": ["2", 0], "text": negative_prompt}},
                "8": {
                    "class_type": "EmptySD3LatentImage",
                    "inputs": {"width": width, "height": height, "batch_size": self.config.batch_size},
                },
                "9": {
                    "class_type": "KSampler",
                    "inputs": {
                        "model": ["5", 0],
                        "positive": ["6", 0],
                        "negative": ["7", 0],
                        "latent_image": ["8", 0],
                        "seed": seed,
                        "steps": steps,
                        "cfg": self.config.cfg,
                        "sampler_name": self.config.sampler,
                        "scheduler": self.config.scheduler,
                        "denoise": 1.0,
                    },
                },
                "10": {"class_type": "VAEDecode", "inputs": {"samples": ["9", 0], "vae": ["3", 0]}},
                "11": {
                    "class_type": "SaveImage",
                    "inputs": {"images": ["10", 0], "filename_prefix": self.config.filename_prefix},
                },
            }
        }
        request = Request(
            f"{self.endpoint}/prompt",
            data=json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urlopen(request, timeout=10) as response:
                data = json.loads(response.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"Failed to queue ComfyUI prompt: {exc}") from exc
        prompt_id = str(data.get("prompt_id", "")).strip()
        if not prompt_id:
            raise RuntimeError(f"ComfyUI did not return a prompt_id: {data}")
        return prompt_id

    def _wait_for_image(self, prompt_id: str) -> str:
        deadline = time.monotonic() + self.config.timeout_seconds
        while time.monotonic() < deadline:
            history = self._get_json(f"{self.endpoint}/history/{prompt_id}", timeout=10)
            run = history.get(prompt_id) if isinstance(history, dict) else None
            if isinstance(run, dict):
                status = run.get("status", {})
                if isinstance(status, dict) and status.get("status_str") == "error":
                    raise RuntimeError(self._format_history_error(status))
                filename = self._extract_image_filename(run)
                if filename:
                    return filename
            time.sleep(2)
        raise RuntimeError(f"Timed out waiting for ComfyUI image after {self.config.timeout_seconds}s")

    def _get_json(self, url: str, *, timeout: int) -> dict:
        try:
            with urlopen(url, timeout=timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except (HTTPError, URLError, TimeoutError, json.JSONDecodeError) as exc:
            raise RuntimeError(f"ComfyUI request failed: {exc}") from exc

    def _extract_image_filename(self, run: dict) -> str:
        outputs = run.get("outputs", {})
        if not isinstance(outputs, dict):
            return ""
        for output in outputs.values():
            if not isinstance(output, dict):
                continue
            images = output.get("images", [])
            if not isinstance(images, list):
                continue
            for image in images:
                if isinstance(image, dict) and image.get("type") == "output":
                    filename = str(image.get("filename", "") or "")
                    subfolder = str(image.get("subfolder", "") or "")
                    if filename:
                        return str(Path(subfolder) / filename) if subfolder else filename
        return ""

    def _format_history_error(self, status: dict) -> str:
        messages = status.get("messages", [])
        for message in reversed(messages if isinstance(messages, list) else []):
            if (
                isinstance(message, list)
                and len(message) >= 2
                and message[0] == "execution_error"
                and isinstance(message[1], dict)
            ):
                detail = message[1].get("exception_message") or message[1].get("exception_type")
                if detail:
                    return f"ComfyUI generation failed: {detail}"
        return "ComfyUI generation failed."


def view_url(endpoint: str, path: Path) -> str:
    query = urlencode({"filename": path.name, "type": "output", "subfolder": ""})
    return f"{endpoint.rstrip('/')}/view?{query}"
