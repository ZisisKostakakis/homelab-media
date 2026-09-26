"""Run scripts/cron-jobs/verify-backup.sh against a fake rclone remote."""

import hashlib
import shutil
import sqlite3
import subprocess
import tarfile
from datetime import datetime, timedelta
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "cron-jobs" / "verify-backup.sh"


def make_archive(remote: Path, stamp: str, services=("sonarr", "radarr", "prowlarr")):
    """Build an archive shaped like backup-config.sh output inside the fake remote."""
    build = remote.parent / "build"
    root = build / "var" / "backups" / stamp  # absolute-ish path recorded in the manifest
    for svc in services:
        (root / svc).mkdir(parents=True)
        con = sqlite3.connect(root / svc / f"{svc}.db")
        con.execute("CREATE TABLE t (x)")
        con.execute("INSERT INTO t VALUES (1)")
        con.commit()
        con.close()
        (root / svc / "config.xml").write_text(f"<Config>{svc}</Config>")
    lines = [
        f"{hashlib.sha256(f.read_bytes()).hexdigest()}  /var/backups/{stamp}/{f.relative_to(root)}"
        for f in sorted(root.rglob("*"))
        if f.is_file()
    ]
    (root / "checksums.sha256").write_text("\n".join(lines) + "\n")
    remote.mkdir(exist_ok=True)
    with tarfile.open(remote / f"{stamp}.tar.gz", "w:gz") as tar:
        tar.add(root, arcname=stamp)
    return root


def stamp_days_ago(days):
    return (datetime.now() - timedelta(days=days)).strftime("%Y-%m-%d_%H-%M-%S")


@pytest.fixture
def env(tmp_path):
    remote = tmp_path / "remote"
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    rclone = bin_dir / "rclone"
    rclone.write_text(
        "#!/bin/sh\n"
        f'REMOTE="{remote}"\n'
        'case "$1" in\n'
        '  lsf) ls "$REMOTE" ;;\n'
        '  copy) cp "$REMOTE/${2##*/}" "$3" ;;\n'
        "esac\n"
    )
    rclone.chmod(0o755)
    # Keep real tar/sha256sum/sqlite3, but nothing that could reach the network.
    return {
        "remote": remote,
        "env": {
            "PATH": f"{bin_dir}:/usr/bin:/bin:/usr/sbin:/sbin",
            "TMPDIR": str(tmp_path),
            "RCLONE_REMOTE": "fake",
            "BACKUP_NTFY_TOPIC": "",
        },
    }


def run(env):
    return subprocess.run(["bash", str(SCRIPT)], capture_output=True, text=True, env=env["env"])


def test_recent_valid_backup_passes(env):
    make_archive(env["remote"], stamp_days_ago(1))
    r = run(env)
    assert r.returncode == 0, r.stderr
    assert "OK:" in r.stdout


def test_picks_newest_archive(env):
    make_archive(env["remote"], stamp_days_ago(30))
    shutil.rmtree(env["remote"].parent / "build")
    make_archive(env["remote"], stamp_days_ago(2))
    assert run(env).returncode == 0


def test_stale_backup_fails(env):
    make_archive(env["remote"], stamp_days_ago(20))
    r = run(env)
    assert r.returncode == 1
    assert "days old" in r.stderr


def test_no_archives_fails(env):
    env["remote"].mkdir()
    r = run(env)
    assert r.returncode == 1
    assert "no archives found" in r.stderr


def test_missing_core_service_fails(env):
    make_archive(env["remote"], stamp_days_ago(1), services=("sonarr", "radarr"))
    r = run(env)
    assert r.returncode == 1
    assert "no database for prowlarr" in r.stderr


def test_checksum_mismatch_fails(env):
    stamp = stamp_days_ago(1)
    root = make_archive(env["remote"], stamp)
    (root / "sonarr" / "config.xml").write_text("<Config>tampered</Config>")
    with tarfile.open(env["remote"] / f"{stamp}.tar.gz", "w:gz") as tar:
        tar.add(root, arcname=stamp)
    r = run(env)
    assert r.returncode == 1
    assert "fail checksum verification" in r.stderr


@pytest.mark.skipif(shutil.which("sqlite3") is None, reason="sqlite3 CLI not installed")
def test_corrupt_sqlite_fails(env):
    stamp = stamp_days_ago(1)
    root = make_archive(env["remote"], stamp)
    db = root / "radarr" / "radarr.db"
    data = bytearray(db.read_bytes())
    data[100:4096] = b"\xff" * (4096 - 100)  # trash the schema page, keep the header
    db.write_bytes(bytes(data))
    # Re-record checksums so only the SQLite check can catch it
    manifest = root / "checksums.sha256"
    lines = [
        f"{hashlib.sha256(f.read_bytes()).hexdigest()}  /var/backups/{stamp}/{f.relative_to(root)}"
        for f in sorted(root.rglob("*"))
        if f.is_file() and f != manifest
    ]
    manifest.write_text("\n".join(lines) + "\n")
    with tarfile.open(env["remote"] / f"{stamp}.tar.gz", "w:gz") as tar:
        tar.add(root, arcname=stamp)
    r = run(env)
    assert r.returncode == 1
    assert "SQLite check failed for radarr/radarr.db" in r.stderr
