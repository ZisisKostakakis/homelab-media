import ntfy_bridge


def test_severity_to_priority_critical():
    assert ntfy_bridge.severity_to_priority("critical") == 5


def test_severity_to_priority_warning():
    assert ntfy_bridge.severity_to_priority("warning") == 3


def test_severity_to_priority_unknown_defaults_to_default():
    assert ntfy_bridge.severity_to_priority("bogus") == 3


def test_severity_to_priority_missing_defaults_to_default():
    assert ntfy_bridge.severity_to_priority(None) == 3
