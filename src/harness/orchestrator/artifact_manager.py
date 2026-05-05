from __future__ import annotations

from dataclasses import dataclass

from harness.session import SessionArtifact
from harness.storage import StateStore


@dataclass
class PersistedArtifacts:
    artifacts: list[SessionArtifact]
    count: int


class ArtifactManager:
    def __init__(self, store: StateStore) -> None:
        self.store = store

    def persist(
        self,
        *,
        session_id: int,
        turn_id: int | None,
        artifacts: list[SessionArtifact],
        output: str = "",
        metadata: dict[str, object] | None = None,
    ) -> PersistedArtifacts:
        if not artifacts:
            return PersistedArtifacts(artifacts=[], count=0)

        preview = output.strip()[:240]
        persisted: list[SessionArtifact] = []
        count = 0
        for artifact in artifacts:
            self.store.record_artifact(
                session_id=session_id,
                turn_id=turn_id,
                kind=artifact.kind,
                title=artifact.title,
                path=artifact.path,
                content_preview=preview,
                metadata=metadata,
            )
            persisted.append(artifact)
            count += 1
        return PersistedArtifacts(artifacts=persisted, count=count)
