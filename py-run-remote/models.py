"""Pydantic schema for the two places this toolchain crosses a
serialization boundary: a profile's YAML on load, and the job.json handed
from run_remote.py (local) to worker.py (remote). Not a general dataclass
replacement -- commands/*.py's plain typed functions stay as they are.

worker.py imports this module on the remote host, outside of any job venv --
the remote's system python3 needs `pydantic` installed for that import to
succeed, the same way it already needs `pyyaml` for profile.py's own YAML
shim.
"""
from __future__ import annotations

from typing import Literal

from pydantic import BaseModel, Field, model_validator

VenvSpecType = Literal["python", "package", "requirements", "script", "package-script", "envvar"]

VALID_SYNC_LABELS = ("default", "site-package", "push-only")


class VenvSpecEntry(BaseModel):
    """One {TYPE: CONTENT} entry from a profile's `venv` list, e.g.
    {"envvar": "KEY=VAL"} or {"python": "3.12"}. Parses YAML's raw
    single-key-dict shape (rather than {"type": ..., "content": ...}) so
    profile YAML doesn't need to change -- but validates there's exactly one
    key, which is exactly the shape of bug that broke minicpm-o-demo.yaml
    (an inverted key/value orientation collapsed two `package` keys into
    one, silently, since plain YAML has no such check)."""

    type: VenvSpecType
    content: str

    @model_validator(mode="before")
    @classmethod
    def _from_single_key_dict(cls, data: object) -> object:
        if isinstance(data, dict) and "type" not in data and "content" not in data:
            if len(data) != 1:
                raise ValueError(
                    f"venv spec entries must each be a single-key {{TYPE: CONTENT}} object, got {data!r}"
                )
            (type_, content), = data.items()
            return {"type": type_, "content": content}
        return data


class Profile(BaseModel):
    """The full profile schema, mirroring profile.py's VALID_KEYS. Validated
    once, immediately after `profile.load_profile()` -- catching a malformed
    profile here means the error surfaces before sync/ssh ever starts,
    instead of after a remote round-trip."""

    venv: list[VenvSpecEntry] = Field(default_factory=list)
    env: dict[str, str] = Field(default_factory=dict)
    host: str | None = None
    home: str | None = None
    local_home: str | None = Field(default=None, alias="local-home")
    initializer: str | None = None
    command: list[str] = Field(default_factory=list)
    sync: dict[str, Literal["default", "site-package", "push-only"]] = Field(default_factory=dict)
    dependencies: dict[str, dict[str, str]] = Field(default_factory=dict)

    model_config = {"populate_by_name": True}

    @model_validator(mode="after")
    def _envvar_entries_come_first(self) -> "Profile":
        seen_other = False
        for entry in self.venv:
            if entry.type == "envvar":
                if seen_other:
                    raise ValueError(
                        '"envvar" entries must all appear before any other venv entry (including "python")'
                    )
            else:
                seen_other = True
        return self


class JobSpec(BaseModel):
    """What run_remote.py sends worker.py as job.json -- the subset of a
    Profile actually needed once a job is ready to launch: venv spec
    already resolved to its list form, env already merged with secrets,
    concrete (already `$HOME`-expanded) remote paths."""

    profile_name: str
    venv: list[VenvSpecEntry]
    env: dict[str, str]
    project_root: str
    initializer: str | None
    command: list[str]
    venvs_root: str  # "$HOME/.venvs" on the remote, already expanded
    log_file: str
    exit_file: str
