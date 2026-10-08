"""Run on any platform with: python3 -m unittest discover -s scripts/tests"""
import importlib.util
from pathlib import Path
import unittest

MODULE_PATH = Path(__file__).resolve().parents[1] / "select-simulator.py"
SPEC = importlib.util.spec_from_file_location("select_simulator", MODULE_PATH)
SIMULATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SIMULATOR)


def device(uid, name="iPhone 16", available=True, state="Shutdown"):
    return {"udid": uid, "name": name, "isAvailable": available, "state": state}


def runtime(version):
    return "com.apple.CoreSimulator.SimRuntime.iOS-" + version.replace(".", "-")


class SelectSimulatorTests(unittest.TestCase):
    def test_exact_sdk_runtime_wins_over_other_xcodes_newer_runtime(self):
        devices = {
            runtime("26.2"): [device("too-new", state="Booted")],
            runtime("18.5"): [device("matching")],
            runtime("18.4"): [device("older", state="Booted")],
        }
        self.assertEqual(SIMULATOR.select_simulator(devices, "18.5"), "matching")

    def test_nearest_older_runtime_when_exact_sdk_not_installed(self):
        devices = {
            runtime("26.2"): [device("too-new")],
            runtime("18.4"): [device("nearest")],
            runtime("17.5"): [device("older", state="Booted")],
        }
        self.assertEqual(SIMULATOR.select_simulator(devices, "18.5"), "nearest")

    def test_matching_major_minor_allows_runtime_patch_releases(self):
        devices = {
            runtime("18.5.1"): [device("patch")],
            runtime("18.5"): [device("base")],
        }
        self.assertEqual(SIMULATOR.select_simulator(devices, "18.5"), "patch")

    def test_only_newer_runtimes_raise_actionable_error(self):
        with self.assertRaisesRegex(RuntimeError, "active iOS 18.5 SDK"):
            SIMULATOR.select_simulator({runtime("26.2"): [device("too-new")]}, "18.5")

    def test_unsupported_unavailable_non_ios_and_ipad_are_ignored(self):
        devices = {
            runtime("16.4"): [device("below-deployment-target")],
            runtime("18.5"): [device("offline", available=False), device("ipad", name="iPad Pro")],
            "com.apple.CoreSimulator.SimRuntime.tvOS-18-5": [device("other-platform")],
        }
        with self.assertRaises(RuntimeError):
            SIMULATOR.select_simulator(devices, "18.5")

    def test_available_older_fallback_when_exact_runtime_has_no_iphone(self):
        devices = {
            runtime("18.5"): [device("ipad", name="iPad Pro")],
            runtime("18.4"): [device("iphone")],
        }
        self.assertEqual(SIMULATOR.select_simulator(devices, "18.5"), "iphone")

    def test_booted_iphone_preferred_within_same_runtime(self):
        devices = {runtime("18.5"): [device("newer-model", name="iPhone 16"),
                                   device("booted", name="iPhone 15", state="Booted")]}
        self.assertEqual(SIMULATOR.select_simulator(devices, "18.5"), "booted")

    def test_modern_iphone_preferred_over_se_with_equal_boot_state(self):
        devices = {runtime("18.5"): [device("se", name="iPhone SE (3rd generation)"),
                                   device("modern", name="iPhone 16")]}
        self.assertEqual(SIMULATOR.select_simulator(devices, "18.5"), "modern")

    def test_invalid_sdk_version_is_rejected(self):
        with self.assertRaises(ValueError):
            SIMULATOR.select_simulator({}, "")


if __name__ == "__main__":
    unittest.main()
