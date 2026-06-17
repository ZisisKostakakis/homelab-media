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
