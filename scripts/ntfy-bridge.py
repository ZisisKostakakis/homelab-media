#!/usr/bin/env python3
"""Runtime entrypoint. Imports the testable ntfy_bridge module and runs it."""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import ntfy_bridge  # noqa: E402

if __name__ == "__main__":
    ntfy_bridge.run()
