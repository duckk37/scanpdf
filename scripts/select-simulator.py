#!/usr/bin/env python3
"""Print the UDID of a usable iPhone simulator without hard-coding an iOS version."""
import json
import re
import subprocess
import sys


def select_simulator(devices):
    candidates = []
    for runtime, entries in devices.items():
        if ".iOS-" not in runtime:
            continue
        version = tuple(int(part) for part in re.findall(r"\d+", runtime.split(".iOS-", 1)[1]))
        if version < (17,):
            continue
        for device in entries:
            if device.get("isAvailable", False) and device.get("name", "").startswith("iPhone"):
                candidates.append((version, device.get("state") == "Booted", device["name"], device["udid"]))
    if not candidates:
        raise RuntimeError("No available iPhone simulator with iOS 17 or newer. Install an iOS runtime in Xcode.")
    return max(candidates)[-1]


if __name__ == "__main__":
    try:
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True, text=True, check=True,
        )
        print(select_simulator(json.loads(result.stdout)["devices"]))
    except (subprocess.CalledProcessError, KeyError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
