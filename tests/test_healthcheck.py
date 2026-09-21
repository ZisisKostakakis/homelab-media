"""Run scripts/healthcheck.sh against fixture compose files and a fake docker CLI."""

import json
import shutil
import subprocess
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "healthcheck.sh"

COMPOSE = """services:
  sonarr:
    image: lscr.io/linuxserver/sonarr
    container_name: sonarr
  qbit:
    image: lscr.io/linuxserver/qbittorrent
    container_name: qbittorrent
  plextraktsync:
    image: ghcr.io/taxel/plextraktsync
    profiles: ["manual"]
#  cross-seed:
#    image: ghcr.io/cross-seed/cross-seed

volumes:
  data:
"""


@pytest.fixture
def repo(tmp_path):
    (tmp_path / "scripts").mkdir()
    shutil.copy(SCRIPT, tmp_path / "scripts" / "healthcheck.sh")
    (tmp_path / "docker-compose-torrent.yml").write_text(COMPOSE)
    (tmp_path / "bin").mkdir()
    return tmp_path


def run(repo, running, *args, unhealthy=()):
    fake = repo / "bin" / "docker"
    names = "\\n".join(running)
    sick = "\\n".join(unhealthy)
    fake.write_text(
        "#!/bin/sh\n"
        '[ "$1" = info ] && exit 0\n'
        f'case "$*" in *health=unhealthy*) printf "{sick}\\n" ;; *) printf "{names}\\n" ;; esac\n'
    )
    fake.chmod(0o755)
    return subprocess.run(
        ["bash", str(repo / "scripts" / "healthcheck.sh"), *args],
        capture_output=True,
        text=True,
        env={"PATH": f"{repo / 'bin'}:/usr/bin:/bin"},
    )


def test_all_running_passes(repo):
    r = run(repo, ["sonarr", "qbittorrent"])
    assert r.returncode == 0
    assert "OK: all 2 expected services are running and healthy" in r.stdout


def test_matches_on_container_name_not_service_key(repo):
    # Service key is "qbit" but the container is "qbittorrent".
    r = run(repo, ["sonarr", "qbit"])
    assert r.returncode == 1
    assert "torrent/qbit" in r.stdout


def test_profiled_and_commented_services_are_not_expected(repo):
    r = run(repo, ["sonarr", "qbittorrent"], "--json")
    status = json.loads(r.stdout)
    assert status["expected"] == 2


def test_json_reports_missing_services(repo):
    r = run(repo, ["qbittorrent"], "--json")
    assert r.returncode == 1
    assert json.loads(r.stdout) == {
        "expected": 2,
        "missing": 1,
        "missing_services": "torrent/sonarr",
        "unhealthy": 0,
        "unhealthy_services": "",
        "ok": False,
    }


def test_quiet_prints_nothing_on_success(repo):
    r = run(repo, ["sonarr", "qbittorrent"], "--quiet")
    assert r.returncode == 0
    assert r.stdout == ""


def test_unhealthy_container_fails(repo):
    r = run(repo, ["sonarr", "qbittorrent"], unhealthy=["sonarr"])
    assert r.returncode == 1
    assert "1/2 services unhealthy" in r.stdout
    assert "torrent/sonarr" in r.stdout


def test_json_reports_unhealthy_services(repo):
    r = run(repo, ["sonarr", "qbittorrent"], "--json", unhealthy=["qbittorrent"])
    status = json.loads(r.stdout)
    assert status["unhealthy"] == 1
    assert status["unhealthy_services"] == "torrent/qbit"
    assert status["missing"] == 0
    assert status["ok"] is False


def test_missing_container_is_not_also_counted_unhealthy(repo):
    # A stopped container can't be unhealthy; report it once, as missing.
    r = run(repo, ["qbittorrent"], "--json", unhealthy=["sonarr"])
    status = json.loads(r.stdout)
    assert (status["missing"], status["unhealthy"]) == (1, 0)
