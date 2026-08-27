import importlib.util
from pathlib import Path
from unittest import mock

import pytest

# The script name has hyphens (Tautulli calls it by path), so load it by file.
_PATH = Path(__file__).resolve().parent.parent / "scripts" / "plex-qbit-manager.py"
_spec = importlib.util.spec_from_file_location("plex_qbit_manager", _PATH)
pqm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(pqm)


def test_parse_count_empty_is_zero():
    assert pqm.parse_count("") == 0


def test_parse_count_strips_whitespace():
    assert pqm.parse_count(" 3\n") == 3


def test_parse_count_corrupt_is_zero():
    assert pqm.parse_count("garbage") == 0


def test_parse_count_negative_clamped():
    assert pqm.parse_count("-2") == 0


def test_first_stream_pauses():
    assert pqm.next_session_count(0, "pause") == (1, "pause")


def test_second_stream_does_nothing():
    assert pqm.next_session_count(1, "pause") == (2, None)


def test_last_stream_ending_resumes():
    assert pqm.next_session_count(1, "resume") == (0, "resume")


def test_stream_ending_with_others_active_does_nothing():
    assert pqm.next_session_count(3, "resume") == (2, None)


def test_resume_with_no_streams_stays_at_zero_and_resumes():
    # A stop event after a missed start must not go negative.
    assert pqm.next_session_count(0, "resume") == (0, "resume")


def _resp(ok, status=200):
    return mock.Mock(ok=ok, status_code=status)


def test_post_first_ok_uses_v4_endpoint_when_it_works():
    session = mock.Mock()
    session.post.return_value = _resp(True)
    assert pqm.post_first_ok(session, ("pause", "stop")) == "pause"
    assert session.post.call_count == 1


def test_post_first_ok_falls_back_to_v5_endpoint():
    session = mock.Mock()
    session.post.side_effect = [_resp(False, 404), _resp(True)]
    assert pqm.post_first_ok(session, ("pause", "stop")) == "stop"
    assert session.post.call_args.args[0].endswith("/api/v2/torrents/stop")


def test_post_first_ok_raises_when_all_rejected():
    session = mock.Mock()
    session.post.side_effect = [_resp(False, 403), _resp(False, 403)]
    with pytest.raises(RuntimeError, match="pause=403, stop=403"):
        pqm.post_first_ok(session, ("pause", "stop"))
