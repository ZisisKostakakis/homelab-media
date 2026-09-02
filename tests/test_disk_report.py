"""Run scripts/disk-report.sh with a fake df so thresholds can be tested."""

import json
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "disk-report.sh"


@pytest.fixture
def env(tmp_path):
    """Two real directories as mounts; fake df reports 50% for one, 95% for the other."""
    low, high = tmp_path / "low", tmp_path / "high"
    low.mkdir()
    high.mkdir()
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    df = bin_dir / "df"
    df.write_text(
        "#!/bin/sh\n"
        "for last; do :; done\n"
        'case "$last" in *high) pct=95 ;; *) pct=50 ;; esac\n'
        'echo "Filesystem Size Used Avail Use% Mounted"\n'
        'echo "/dev/x 100G ${pct}G 1G ${pct}% $last"\n'
    )
    df.chmod(0o755)
    return {
        "PATH": f"{bin_dir}:/usr/bin:/bin",
        "HOMELAB_DISK_MOUNTS": f"{low} {high} {tmp_path / 'missing'}",
    }


def run(env, *args):
    return subprocess.run(["bash", str(SCRIPT), *args], capture_output=True, text=True, env=env)


def test_fails_when_a_mount_is_over_default_threshold(env):
    r = run(env)
    assert r.returncode == 1
    assert "FAIL: 1 mount(s) at or above 90%" in r.stdout


def test_passes_with_higher_threshold(env):
    r = run(env, "--threshold", "96")
    assert r.returncode == 0
    assert "OK: all mounts under 96%" in r.stdout


def test_missing_mounts_are_skipped(env):
    r = run(env, "--threshold", "96")
    assert "(does not exist)" in r.stdout


def test_json_lines_flag_mounts_over_threshold(env):
    r = run(env, "--json")
    rows = [json.loads(line) for line in r.stdout.splitlines()]
    assert [(Path(row["mount"]).name, row["over"]) for row in rows] == [
        ("low", False),
        ("high", True),
    ]


@pytest.mark.parametrize("bad", ["0", "101", "abc"])
def test_rejects_invalid_threshold(env, bad):
    r = run(env, "--threshold", bad)
    assert r.returncode == 2
