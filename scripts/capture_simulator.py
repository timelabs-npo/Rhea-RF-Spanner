#!/usr/bin/env python3
"""Run the built native app in iOS Simulator; never start live audio.

Screenshots are CI review evidence, not an assertion of device measurement
performance. Visible app content must appear before a bounded deadline. The
first idle launch is captured before DEMO or hosted tests can warm up the app.
"""
from __future__ import annotations

import json
import platform
import shutil
import subprocess
import time
import unicodedata
import uuid
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "build/screenshots"
BUNDLE = "org.timelabs.RheaRFSpanner"
READINESS_DEADLINE_SECONDS = 45.0
READINESS_POLL_SECONDS = 0.5
# A source tab/button alone is not evidence of the displayed acquisition mode.
# Require the source caption and a view-specific caption for each DEMO image.
SCENARIOS = [
    ("01-idle", [], ["RHEA", "LIVE LISTEN", "Listen", "Tone experiment", "MIC OFF"]),
    ("02-demo-field", ["--observatory-demo"],
     ["RHEA", "DEMO SYNTHETIC", "SYNTHETIC FIELD", "Synthetic samples received"]),
    ("03-demo-waterfall", ["--observatory-demo", "--observatory-waterfall"],
     ["RHEA", "DEMO SYNTHETIC", "SAMPLE SPECTRUM", "Synthetic samples received"]),
    ("04-demo-diagnostics", ["--observatory-demo", "--observatory-waterfall", "--observatory-diagnostics"],
     ["Pipeline diagnostics", "Mode state", "demo running", "Synthetic samples received"]),
]


def run(*args: str, timeout: float = 90, check: bool = True) -> str:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(args)}: {result.stdout}\n{result.stderr}")
    return result.stdout


def write_manifest(manifest: dict) -> None:
    temporary = OUTPUT / "manifest.json.tmp"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(OUTPUT / "manifest.json")


def normalize_text(value: str) -> str:
    # Vision can split labels or vary case, spaces, and punctuation. This does
    # not correct/substitute letters or invent a missing source/view caption.
    return "".join(character for character in unicodedata.normalize("NFKC", value).casefold()
                   if character.isalnum())


def missing_labels(lines: list[dict], required: list[str]) -> list[str]:
    observed = normalize_text(" ".join(line["text"] for line in lines))
    return [label for label in required if normalize_text(label) not in observed]


def remaining_timeout(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError(f"Visible app content did not pass within {READINESS_DEADLINE_SECONDS:g} seconds.")
    return remaining


def compile_text_reader() -> Path:
    helper = ROOT / "build/tools/capture-screen-text"
    helper.parent.mkdir(parents=True, exist_ok=True)
    # Compilation happens before the first app launch, not by running a warmup
    # app/test. The helper reads only the PNG supplied to it.
    run("xcrun", "--sdk", "macosx", "swiftc", "-parse-as-library", "-swift-version", "6", "-O",
        str(ROOT / "scripts/capture_screen_text.swift"), "-o", str(helper), timeout=120)
    return helper


def capture_when_visible(udid: str, helper: Path, name: str, args: list[str],
                         required: list[str], manifest: dict) -> None:
    path = OUTPUT / f"{name}.png"
    first_path = OUTPUT / f"{name}-first-attempt.png"
    # A repeated local capture must never accept an image from an older run.
    path.unlink(missing_ok=True)
    first_path.unlink(missing_ok=True)
    scenario = {
        "name": path.name, "launch_arguments": args, "required_visible_labels": required,
        "first_launch_in_capture_run": not manifest["screenshots"],
        "status": "launching", "attempts": [],
    }
    manifest["screenshots"].append(scenario)
    write_manifest(manifest)
    run("xcrun", "simctl", "terminate", udid, BUNDLE, check=False)
    started = time.monotonic()
    deadline = started + READINESS_DEADLINE_SECONDS
    try:
        result = run("xcrun", "simctl", "launch", udid, BUNDLE, *args,
                     timeout=remaining_timeout(deadline))
        scenario["launch_returned_seconds"] = round(time.monotonic() - started, 3)
        print(result.strip(), flush=True)
        while True:
            remaining_timeout(deadline)
            attempt = {"number": len(scenario["attempts"]) + 1,
                       "capture_started_seconds": round(time.monotonic() - started, 3),
                       "status": "capturing"}
            scenario["attempts"].append(attempt)
            write_manifest(manifest)
            run("xcrun", "simctl", "io", udid, "screenshot", str(path),
                timeout=remaining_timeout(deadline))
            attempt["captured_seconds"] = round(time.monotonic() - started, 3)
            attempt["image_bytes"] = path.stat().st_size  # Evidence only, never a readiness gate.
            scenario["last_screenshot"] = path.name
            if not first_path.exists():
                shutil.copyfile(path, first_path)
                scenario["first_screenshot"] = first_path.name
            attempt["status"] = "recognizing"
            write_manifest(manifest)
            recognized = json.loads(run(str(helper), str(path), timeout=remaining_timeout(deadline)))
            lines = recognized["lines"]
            if not isinstance(lines, list) or any(not isinstance(line.get("text"), str) for line in lines):
                raise RuntimeError("Screenshot text reader returned an invalid result.")
            attempt["recognizer"] = {key: recognized[key] for key in ("engine", "revision")}
            attempt["observed_lines"] = lines
            attempt["missing_labels"] = missing_labels(lines, required)
            attempt["checked_seconds"] = round(time.monotonic() - started, 3)
            attempt["status"] = "waiting" if attempt["missing_labels"] else "visible"
            write_manifest(manifest)
            # Recognition itself must complete within the same deadline. A late
            # result cannot silently turn a timed-out cold launch into a pass.
            remaining_timeout(deadline)
            if not attempt["missing_labels"]:
                scenario["status"] = "visible_content_ready"
                scenario["visible_content_ready_seconds"] = attempt["checked_seconds"]
                write_manifest(manifest)
                print(f"Visible {name} after {attempt['checked_seconds']:.3f}s "
                      f"({len(scenario['attempts'])} attempt(s)); captured {path.name}", flush=True)
                return
            print(f"Waiting for {name} at {attempt['checked_seconds']:.3f}s: "
                  + ", ".join(attempt["missing_labels"]), flush=True)
            time.sleep(min(READINESS_POLL_SECONDS, remaining_timeout(deadline)))
    except Exception as error:
        scenario["status"] = "failed"
        scenario["elapsed_seconds"] = round(time.monotonic() - started, 3)
        scenario["error"] = str(error)
        if scenario["attempts"] and scenario["attempts"][-1]["status"] in {"capturing", "recognizing"}:
            scenario["attempts"][-1]["status"] = "failed"
            scenario["attempts"][-1]["error"] = str(error)
        write_manifest(manifest)
        raise RuntimeError(f"{name} did not pass visible-content readiness. "
                           f"Inspect {OUTPUT / 'manifest.json'} and the retained screenshot(s).") from error


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
    manifest = {
        "bundle": BUNDLE, "simulator": preferred["name"], "screenshots": [],
        "capture_status": "preparing", "readiness_deadline_seconds": READINESS_DEADLINE_SECONDS,
        "readiness_meaning": "Visible app content only; not a measurement or hardware validation.",
        "launch_order": "Idle first, then DEMO scenarios, then hosted tests. No app warmup.",
    }
    write_manifest(manifest)
    try:
        helper = compile_text_reader()
        manifest["capture_status"] = "capturing"
        write_manifest(manifest)
        for name, args, required in SCENARIOS:
            capture_when_visible(udid, helper, name, args, required, manifest)
        manifest["capture_status"] = "complete"
        write_manifest(manifest)
    except Exception as error:
        manifest["capture_status"] = "failed"
        manifest["error"] = str(error)
        write_manifest(manifest)
        raise
    finally:
        run("xcrun", "simctl", "terminate", udid, BUNDLE, timeout=10, check=False)
    test_output = ROOT / "build/test-results"
    test_output.mkdir(parents=True, exist_ok=True)
    architecture = platform.machine()
    if architecture not in {"arm64", "x86_64"}:
        raise RuntimeError(f"Unsupported Simulator host architecture: {architecture}")
    # xcodebuild refuses an existing result bundle. Preserve earlier evidence
    # while allowing repeated captures in the same checkout.
    result_bundle = test_output / f"ObservatorySession-{uuid.uuid4().hex}.xcresult"
    command = [
        "xcodebuild", "-project", "RheaRFSpanner.xcodeproj", "-scheme", "RheaRFSpanner",
        "-configuration", "Debug", "-destination", f"platform=iOS Simulator,id={udid},arch={architecture}",
        "-derivedDataPath", "build/DerivedData-simulator",
        "-resultBundlePath", str(result_bundle),
        "-only-testing:RheaRFSpannerTests", "CODE_SIGNING_ALLOWED=NO", "test",
    ]
    print("Running simulator-hosted session integration tests", flush=True)
    print(f"Result bundle: {result_bundle.relative_to(ROOT)}", flush=True)
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True, timeout=600)
    (ROOT / "build/logs/xcode-session-tests.log").write_text(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError("Session tests failed. See xcode-session-tests.log.\n" + (result.stdout + result.stderr)[-5_000:])
    print("Simulator-hosted session integration tests passed", flush=True)


if __name__ == "__main__":
    main()
