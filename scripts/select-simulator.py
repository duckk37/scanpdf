#!/usr/bin/env python3
"""Select an installed iPhone simulator compatible with the active Xcode SDK."""
import json
import re
import subprocess
import sys


def version_components(value):
    parts = tuple(int(part) for part in re.findall(r"\d+", value))
    if not parts:
        raise ValueError("The active iPhone simulator SDK version is invalid.")
    return parts + (0,) * max(0, 2 - len(parts))


def select_simulator(devices, sdk_version):
    # Runtimes can be installed by other Xcode versions on the same runner.
    # Match the selected SDK's major/minor first; newer runtimes are unsuitable
    # even when simctl considers them available globally. Patch releases sharing
    # the SDK's major/minor remain eligible.
    sdk_major_minor = version_components(sdk_version)[:2]
    candidates = []
    for runtime, entries in devices.items():
        if ".iOS-" not in runtime:
            continue
        version = version_components(runtime.split(".iOS-", 1)[1])
        if version[:2] < (17, 0) or version[:2] > sdk_major_minor:
            continue
        for device in entries:
            if device.get("isAvailable", False) and device.get("name", "").startswith("iPhone"):
                model_match = re.match(r"iPhone (\d+)", device["name"])
                model = int(model_match.group(1)) if model_match else 0
                candidates.append((version[:2] == sdk_major_minor, version,
                                   device.get("state") == "Booted", model,
                                   device["name"], device["udid"]))
    if not candidates:
        raise RuntimeError(
            f"No available iPhone simulator with iOS 17 or newer compatible with "
            f"the active iOS {sdk_version.strip()} SDK. Install a matching runtime "
            f"in Xcode or select an Xcode version that supports the installed runtime."
        )
    return max(candidates)[-1]


if __name__ == "__main__":
    try:
        sdk = subprocess.run(
            ["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"],
            capture_output=True, text=True, check=True,
        ).stdout.strip()
        result = subprocess.run(
            ["xcrun", "simctl", "list", "devices", "available", "--json"],
            capture_output=True, text=True, check=True,
        )
        print(select_simulator(json.loads(result.stdout)["devices"], sdk))
    except (subprocess.CalledProcessError, KeyError, ValueError, RuntimeError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
