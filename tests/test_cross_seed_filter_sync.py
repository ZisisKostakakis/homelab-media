import importlib.util
from pathlib import Path

import pytest

_PATH = Path(__file__).resolve().parent.parent / "scripts" / "cross-seed-filter-sync.py"
_spec = importlib.util.spec_from_file_location("cross_seed_filter_sync", _PATH)
csf = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(csf)

CONFIG = """module.exports = {
    delay: 30,
    blockList: [],
    action: "inject",
};
"""


def _torrent(name, category="radarr"):
    return {"name": name, "category": category, "state": "uploading", "ratio": 1.0}


def test_blocks_torrents_not_managed_by_arrs():
    torrents = {"aaa": _torrent("Kept"), "bbb": _torrent("Orphan")}
    assert csf.calculate_blocklist(torrents, {"aaa"}) == ["infoHash:bbb"]


def test_never_blocks_cross_seed_injected_torrents():
    torrents = {"ccc": _torrent("Injected", category="cross-seed-link")}
    assert csf.calculate_blocklist(torrents, set()) == []


def test_everything_managed_means_empty_blocklist():
    torrents = {"aaa": _torrent("A"), "bbb": _torrent("B")}
    assert csf.calculate_blocklist(torrents, {"aaa", "bbb"}) == []


def test_render_replaces_empty_blocklist():
    out = csf.render_blocklist(CONFIG, ["infoHash:bbb"])
    assert '"infoHash:bbb"' in out
    assert "delay: 30" in out and 'action: "inject"' in out


def test_render_replaces_existing_entries():
    once = csf.render_blocklist(CONFIG, ["infoHash:old"])
    twice = csf.render_blocklist(once, ["infoHash:new"])
    assert "infoHash:old" not in twice
    assert '"infoHash:new"' in twice


def test_render_empty_list_writes_empty_array():
    filled = csf.render_blocklist(CONFIG, ["infoHash:x"])
    assert "blockList: []" in csf.render_blocklist(filled, [])


def test_render_returns_none_without_blocklist_key():
    assert csf.render_blocklist("module.exports = {};", ["infoHash:x"]) is None


@pytest.fixture
def config_file(tmp_path, monkeypatch):
    path = tmp_path / "config.js"
    path.write_text(CONFIG)
    monkeypatch.setattr(csf, "CROSS_SEED_CONFIG_PATH", str(path))
    return path


def test_update_writes_new_blocklist(config_file):
    assert csf.update_config_js(["infoHash:bbb"]) == "updated"
    assert '"infoHash:bbb"' in config_file.read_text()


def test_update_reports_unchanged_without_rewriting(config_file):
    csf.update_config_js(["infoHash:bbb"])
    mtime = config_file.stat().st_mtime_ns
    assert csf.update_config_js(["infoHash:bbb"]) == "unchanged"
    assert config_file.stat().st_mtime_ns == mtime


def test_update_fails_when_blocklist_key_missing(config_file):
    config_file.write_text("module.exports = {};")
    assert csf.update_config_js(["infoHash:bbb"]) == "failed"


def test_update_fails_when_config_missing(tmp_path, monkeypatch):
    monkeypatch.setattr(csf, "CROSS_SEED_CONFIG_PATH", str(tmp_path / "nope.js"))
    assert csf.update_config_js([]) == "failed"
