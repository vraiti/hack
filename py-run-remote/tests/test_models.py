"""Covers the manual verification run against models.py: valid parsing, the
envvar-ordering rule, and the exact malformed-entry shape that broke
minicpm-o-demo.yaml (an inverted key/value orientation collapsing a
duplicate key, which plain YAML has no way to catch on its own).
"""
from __future__ import annotations

import pytest
from pydantic import ValidationError

from models import JobSpec, Profile, VenvSpecEntry


def test_venv_spec_entry_parses_single_key_dict() -> None:
    entry = VenvSpecEntry.model_validate({"python": "3.12"})
    assert entry.type == "python"
    assert entry.content == "3.12"


def test_venv_spec_entry_rejects_multi_key_dict() -> None:
    # The actual shape that broke minicpm-o-demo.yaml: an inverted
    # key/value orientation left two "package"-ish keys in one entry.
    with pytest.raises(ValidationError, match="single-key"):
        VenvSpecEntry.model_validate({"3.12": "python", "vllm-omni": "package"})


def test_profile_accepts_valid_ordering() -> None:
    profile = Profile.model_validate(
        {
            "venv": [
                {"envvar": "MAX_JOBS=4"},
                {"python": "3.12"},
                {"package": "vllm==0.29.0"},
            ],
            "command": ["pytest.sh"],
            "sync": {"vllm-omni": "default"},
        }
    )
    assert [e.type for e in profile.venv] == ["envvar", "python", "package"]
    assert profile.sync == {"vllm-omni": "default"}


def test_profile_rejects_envvar_after_other_entries() -> None:
    with pytest.raises(ValidationError, match='"envvar" entries must all appear before'):
        Profile.model_validate({"venv": [{"python": "3.12"}, {"envvar": "X=1"}]})


def test_profile_local_home_alias() -> None:
    profile = Profile.model_validate({"local-home": "/some/dir"})
    assert profile.local_home == "/some/dir"


def test_jobspec_json_roundtrip() -> None:
    job = JobSpec(
        profile_name="x",
        venv=[VenvSpecEntry(type="python", content="3.12")],
        env={"A": "1"},
        project_root="/home/x",
        initializer=None,
        command=["pytest.sh"],
        venvs_root="/home/x/.venvs",
        log_file="/tmp/l",
        exit_file="/tmp/e",
    )
    assert JobSpec.model_validate_json(job.model_dump_json()) == job
