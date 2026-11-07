#!/usr/bin/env python3
"""Run the built native app in iOS Simulator; never start live audio.

Screenshots are CI review evidence, not an assertion of device measurement
performance. Runtime absence is a failure rather than a fabricated preview.
"""
from __future__ import annotations

import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/screenshots"
BUNDLE = "org.timelabs.RheaRFSpanner"


def run(*args: str, timeout: int = 90, check: bool = True) -> str:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(args)}: {result.stdout}\n{result.stderr}")
    return result.stdout


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    devices = json.loads(run("xcrun", "simctl", "list", "devices", "available", "--json"))
    candidates = [device for runtime, items in devices["devices"].items()
                  if "iOS" in runtime for device in items
                  if device.get("isAvailable") and device["name"].startswith("iPhone")]
    if not candidates:
        raise RuntimeError("No available iPhone Simulator runtime; native visual capture is blocked.")
    preferred = next((d for d in candidates if d["name"] == "iPhone 17 Pro"), candidates[0])
    udid = preferred["udid"]
    print(f"Simulator: {preferred['name']} ({udid})", flush=True)
    run("xcrun", "simctl", "boot", udid, check=False)
    run("xcrun", "simctl", "bootstatus", udid, "-b", timeout=480)
    run("xcrun", "simctl", "ui", udid, "appearance", "dark")
    run("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41",
        "--dataNetwork", "wifi", "--wifiMode", "active", "--wifiBars", "3",
        "--batteryState", "charged", "--batteryLevel", "100")
    app = ROOT / "build/DerivedData-simulator/Build/Products/Debug-iphonesimulator/RheaRFSpanner.app"
    if not app.is_dir():
        raise RuntimeError(f"Simulator build missing: {app}")
    run("xcrun", "simctl", "install", udid, str(app))
    scenarios = [
        ("01-idle", []),
        ("02-demo-field", ["--observatory-demo"]),
        ("03-demo-waterfall", ["--observatory-demo", "--observatory-waterfall"]),
    ]
    manifest = {"bundle": BUNDLE, "simulator": preferred["name"], "screenshots": []}
    for name, args in scenarios:
        run("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
        result = run("xcrun", "simctl", "launch", udid, BUNDLE, *args)
        print(result.strip(), flush=True)
        time.sleep(8 if args else 3)
        path = OUTPUT / f"{name}.png"
        run("xcrun", "simctl", "io", udid, "screenshot", str(path))
        if path.stat().st_size < 1_024:
            raise RuntimeError(f"Screenshot is unexpectedly small: {path}")
        manifest["screenshots"].append({"name": path.name, "launch_arguments": args})
        print(f"Captured {name}: {path.stat().st_size} bytes", flush=True)
    run("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    (OUTPUT / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    test_output = ROOT / "build/test-results"
    test_output.mkdir(parents=True, exist_ok=True)
    command = [
        "xcodebuild", "-project", "RheaRFSpanner.xcodeproj", "-scheme", "RheaRFSpanner",
        "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={udid}",
        "-derivedDataPath", "build/DerivedData-simulator",
        "-resultBundlePath", "build/test-results/ObservatorySession.xcresult",
        "-only-testing:RheaRFSpannerTests", "CODE_SIGNING_ALLOWED=NO", "test",
    ]
    print("Running simulator-hosted session integration tests", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=600)
    (ROOT / "build/logs/xcode-session-tests.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Session tests failed. See xcode-session-tests.log.\n" + (result.stdout + result.stderr)[-5_000:])
    print("Simulator-hosted session integration tests passed", flush=True)


if __name__ == "__main__":
    main()
