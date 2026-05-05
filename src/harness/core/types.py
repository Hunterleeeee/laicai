"""Immutable value objects shared across the entire framework.

No external dependencies beyond the stdlib + pydantic.
"""

from __future__ import annotations

from datetime import datetime, timezone
from enum import Enum
from typing import Any, Literal, Union

from pydantic import BaseModel, Field


# ── Roles & Turns ──────────────────────────────────────────────

class Role(str, Enum):
    USER = "user"
    ASSISTANT = "assistant"
    SYSTEM = "system"
    TOOL = "tool"


class Turn(BaseModel):
    role: Role
    content: str
    name: str | None = None          # tool name when role == TOOL
    tool_call_id: str | None = None  # correlation id for tool responses
    timestamp: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))


class Session(BaseModel):
    id: str
    turns: list[Turn] = Field(default_factory=list)
    created_at: datetime = Field(default_factory=lambda: datetime.now(timezone.utc))
    metadata: dict[str, Any] = Field(default_factory=dict)


# ── Tool definitions (OpenAI function-calling compatible) ──────

class ToolParam(BaseModel):
    name: str
    type: str = "string"
    description: str = ""
    required: bool = True
    enum: list[str] | None = None


class ToolDef(BaseModel):
    """Declarative tool definition, serialisable to OpenAI function schema."""
    name: str
    description: str
    parameters: list[ToolParam] = Field(default_factory=list)

    def to_openai_schema(self) -> dict:
        props: dict[str, Any] = {}
        req: list[str] = []
        for p in self.parameters:
            prop: dict[str, Any] = {"type": p.type, "description": p.description}
            if p.enum:
                prop["enum"] = p.enum
            props[p.name] = prop
            if p.required:
                req.append(p.name)
        return {
            "type": "function",
            "function": {
                "name": self.name,
                "description": self.description,
                "parameters": {
                    "type": "object",
                    "properties": props,
                    "required": req,
                },
            },
        }


class ToolResult(BaseModel):
    tool_call_id: str
    name: str
    content: str
    success: bool = True


# ── Chunks / Retrieval ─────────────────────────────────────────

class Chunk(BaseModel):
    source: str          # file path or URL
    content: str
    score: float = 0.0
    meta: dict[str, Any] = Field(default_factory=dict)


# ── Streaming events (agent → UI) ─────────────────────────────

class ThoughtEvent(BaseModel):
    kind: Literal["thought"] = "thought"
    text: str


class TokenEvent(BaseModel):
    kind: Literal["token"] = "token"
    text: str
    done: bool = False


class ToolCallEvent(BaseModel):
    kind: Literal["tool_call"] = "tool_call"
    tool_call_id: str
    name: str
    arguments: dict[str, Any] = Field(default_factory=dict)


class NoteEvent(BaseModel):
    kind: Literal["note_saved"] = "note_saved"
    path: str


class UsageEvent(BaseModel):
    kind: Literal["usage"] = "usage"
    input_tokens: int = 0
    output_tokens: int = 0


class ErrorEvent(BaseModel):
    kind: Literal["error"] = "error"
    text: str


Event = Union[ThoughtEvent, TokenEvent, ToolCallEvent, NoteEvent, UsageEvent, ErrorEvent]
