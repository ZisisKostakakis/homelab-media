import json
from unittest import mock

import ntfy_bridge


def test_severity_to_priority_critical():
    assert ntfy_bridge.severity_to_priority("critical") == 5


def test_severity_to_priority_warning():
    assert ntfy_bridge.severity_to_priority("warning") == 3


def test_severity_to_priority_unknown_defaults_to_default():
    assert ntfy_bridge.severity_to_priority("bogus") == 3


def test_severity_to_priority_missing_defaults_to_default():
    assert ntfy_bridge.severity_to_priority(None) == 3


def _sample_alert(status="firing", severity="warning", container="sonarr"):
    return {
        "status": status,
        "alerts": [
            {
                "status": status,
                "labels": {
                    "alertname": "HighErrorRate",
                    "severity": severity,
                    "container_name": container,
                },
                "annotations": {
                    "summary": "High error rate",
                    "description": f"{container} is erroring",
                },
            }
        ],
    }


def test_format_messages_produces_one_message_per_alert():
    msgs = ntfy_bridge.format_messages(_sample_alert())
    assert len(msgs) == 1


def test_format_message_title_includes_container_and_alertname():
    msg = ntfy_bridge.format_messages(_sample_alert(container="radarr"))[0]
    assert "radarr" in msg["title"]
    assert "HighErrorRate" in msg["title"]


def test_format_message_priority_from_severity():
    msg = ntfy_bridge.format_messages(_sample_alert(severity="critical"))[0]
    assert msg["priority"] == 5


def test_format_message_body_includes_description():
    msg = ntfy_bridge.format_messages(_sample_alert(container="bazarr"))[0]
    assert "bazarr is erroring" in msg["body"]


def test_format_messages_empty_when_no_alerts():
    assert ntfy_bridge.format_messages({"alerts": []}) == []


def test_format_messages_handles_missing_alerts_key():
    assert ntfy_bridge.format_messages({}) == []


def test_send_to_ntfy_posts_to_topic_url():
    msg = {"title": "T", "body": "B", "priority": 4}
    with mock.patch.object(ntfy_bridge.urllib.request, "urlopen") as m:
        m.return_value.__enter__ = lambda s: s
        m.return_value.__exit__ = lambda *a: False
        ntfy_bridge.send_to_ntfy(msg, topic="mytopic", base_url="https://ntfy.sh")
    req = m.call_args[0][0]
    assert req.full_url == "https://ntfy.sh/mytopic"
    assert req.data == b"B"
    assert req.get_header("Title") == "T"
    assert req.get_header("Priority") == "4"


def test_send_to_ntfy_no_topic_is_noop():
    msg = {"title": "T", "body": "B", "priority": 3}
    with mock.patch.object(ntfy_bridge.urllib.request, "urlopen") as m:
        ntfy_bridge.send_to_ntfy(msg, topic="", base_url="https://ntfy.sh")
    m.assert_not_called()


def test_send_to_ntfy_swallows_network_errors():
    msg = {"title": "T", "body": "B", "priority": 3}
    with mock.patch.object(
        ntfy_bridge.urllib.request, "urlopen", side_effect=OSError("boom")
    ):
        # Must not raise
        ntfy_bridge.send_to_ntfy(msg, topic="t", base_url="https://ntfy.sh")


def test_handle_alert_body_valid_returns_200_and_sends():
    body = json.dumps(_sample_alert()).encode("utf-8")
    with mock.patch.object(ntfy_bridge, "send_to_ntfy") as send:
        status, _ = ntfy_bridge.handle_alert_body(body)
    assert status == 200
    assert send.call_count == 1


def test_handle_alert_body_malformed_json_returns_200_and_no_send():
    with mock.patch.object(ntfy_bridge, "send_to_ntfy") as send:
        status, _ = ntfy_bridge.handle_alert_body(b"not json")
    # Return 200 so Alertmanager does not wedge its queue
    assert status == 200
    send.assert_not_called()


def test_handle_alert_body_empty_returns_200():
    with mock.patch.object(ntfy_bridge, "send_to_ntfy") as send:
        status, _ = ntfy_bridge.handle_alert_body(b"")
    assert status == 200
    send.assert_not_called()
