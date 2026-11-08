#!/usr/bin/env python3
"""Run the built native app in iOS Simulator; never start live audio.

Screenshots are CI review evidence, not an assertion of device measurement
performance. Visible app content must appear before a bounded deadline. The
first idle launch is captured before DEMO or hosted tests can warm up the app.
"""
from __future__ import annotations

import json
import math
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
DIAGNOSTIC_OUTPUT_LIMIT = 8_192
# A source tab/button alone is not evidence of the displayed acquisition mode.
# Require the source caption and a view-specific caption for each DEMO image.
SCENARIOS = [
    ("01-idle", [], ["RHEA", "LIVE LISTEN", "Listen", "Tone experiment", "MIC OFF", "START LISTENING"]),
    ("02-demo-field", ["--observatory-demo"],
     ["RHEA", "DEMO SYNTHETIC", "SYNTHETIC FIELD", "Synthetic samples received", "STOP"]),
    ("03-demo-waterfall", ["--observatory-demo", "--observatory-waterfall"],
     ["RHEA", "DEMO SYNTHETIC", "SAMPLE SPECTRUM", "Synthetic samples received", "STOP"]),
    ("04-demo-diagnostics", ["--observatory-demo", "--observatory-waterfall", "--observatory-diagnostics"],
     ["Pipeline diagnostics", "Mode state", "demo running", "Synthetic samples received"]),
]


def run(*args: str, timeout: float = 90, check: bool = True) -> str:
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f"{' '.join(args)}: {result.stdout}\n{result.stderr}")
    return result.stdout


def failure_details(error: Exception) -> dict:
    """Retain bounded timeout output; it may include a PID printed before a hang."""
    details = {"type": type(error).__name__, "message": str(error)[-DIAGNOSTIC_OUTPUT_LIMIT:]}
    if isinstance(error, subprocess.TimeoutExpired):
        details["timeout_seconds"] = error.timeout
        details["output_tail_limit_characters"] = DIAGNOSTIC_OUTPUT_LIMIT
        for stream in ("stdout", "stderr"):
            value = getattr(error, stream)
            details[stream + "_truncated"] = value is not None and len(value) > DIAGNOSTIC_OUTPUT_LIMIT
            # TimeoutExpired can contain bytes even with subprocess text=True.
            # Slice before decoding, then cap the retained text to 8,192 code
            # points per stream; never decode an unbounded captured buffer here.
            if isinstance(value, bytes):
                value = value[-DIAGNOSTIC_OUTPUT_LIMIT:].decode("utf-8", errors="replace")
            details[stream + "_tail"] = value[-DIAGNOSTIC_OUTPUT_LIMIT:] if value is not None else None
    return details


def write_manifest(manifest: dict) -> None:
    temporary = OUTPUT / "manifest.json.tmp"
    temporary.write_text(json.dumps(manifest, indent=2) + "\n")
    temporary.replace(OUTPUT / "manifest.json")


def normalize_text(value: str) -> str:
    # Vision can vary case, spaces, and punctuation within a recognized label.
    # This does not correct/substitute letters or invent a missing caption.
    return "".join(character for character in unicodedata.normalize("NFKC", value).casefold()
                   if character.isalnum())


def observation_bounds(line: dict) -> tuple[float, float, float, float] | None:
    """Validate Vision's normalized lower-left-origin observation rectangle."""
    bounds = line.get("boundingBox")
    if not isinstance(bounds, dict):
        return None
    values = tuple(bounds.get(key) for key in ("x", "y", "width", "height"))
    if any(type(value) not in (int, float) or not 0 <= value <= 1 or not math.isfinite(value)
           for value in values):
        return None
    x, y, width, height = values
    if x < 0 or y < 0 or width <= 0 or height <= 0 or x + width > 1 or y + height > 1:
        return None
    return x, y, width, height


def in_primary_dock(bounds: tuple[float, float, float, float]) -> bool:
    # Portrait native capture: the complete label must be in the lower 20% of
    # the image and middle half of its width, centered in the middle fifth.
    # Coordinates come from the actual screenshot, not the expected app state.
    x, y, width, height = bounds
    return 0.25 <= x and x + width <= 0.75 and y + height <= 0.20 and 0.40 <= x + width / 2 <= 0.60


def has_primary_action(lines: list[dict], action: str) -> bool:
    observations = [(normalize_text(line["text"]), observation_bounds(line)) for line in lines]
    dock_lines = [(text, bounds) for text, bounds in observations
                  if bounds is not None and in_primary_dock(bounds)]
    if any(text == action for text, _ in dock_lines):
        return True
    if action != "startlistening":
        return False  # STOP must be one exact visible label in the dock.

    # SwiftUI can wrap the centered action title into START / LISTENING. Accept
    # only that physical top-to-bottom order, with centers within 2.5% of image
    # width, similar glyph heights (ratio <= 1.5), nonoverlapping boxes, and a
    # gap <= one larger glyph height. Array order is irrelevant to image order.
    for first_text, first in dock_lines:
        if first_text != "start":
            continue
        for second_text, second in dock_lines:
            if second_text != "listening":
                continue
            x1, y1, width1, height1 = first
            x2, y2, width2, height2 = second
            gap = y1 - (y2 + height2)
            if (abs((x1 + width1 / 2) - (x2 + width2 / 2)) > 0.025
                    or max(height1, height2) > 1.5 * min(height1, height2)
                    or not 0 <= gap <= max(height1, height2)):
                continue
            # A third line in the gap makes these separate labels, not a
            # wrapped action. Unrelated controls outside this column are fine.
            left, right = min(x1, x2), max(x1 + width1, x2 + width2)
            interrupted = any(
                text and bounds is not None and bounds not in (first, second)
                and bounds[0] < right and bounds[0] + bounds[2] > left
                and bounds[1] < y1 and bounds[1] + bounds[3] > y2 + height2
                for text, bounds in observations
            )
            if not interrupted:
                return True
    return False


def missing_labels(lines: list[dict], required: list[str]) -> list[str]:
    normalized_lines = {normalize_text(line["text"]) for line in lines}
    # Primary actions need exact text and position evidence. Instructional text
    # containing "Tap Start listening" or "stopped" is not evidence of a button.
    primary_actions = {"startlistening", "stop"}
    # Never join unrelated lines: the source caption "DEMO SYNTHETIC" followed
    # by a FIELD selector is not the view-specific caption "SYNTHETIC FIELD".
    return [label for label in required
            if (not has_primary_action(lines, normalize_text(label))
                if normalize_text(label) in primary_actions
                else not any(normalize_text(label) in line for line in normalized_lines))]


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
        "status": "preparing", "phase": "prelaunch_termination", "attempts": [],
    }
    manifest["screenshots"].append(scenario)
    write_manifest(manifest)
    scenario_started = time.monotonic()
    started: float | None = None
    try:
        run("xcrun", "simctl", "terminate", udid, BUNDLE, timeout=10, check=False)
        scenario["prelaunch_termination_seconds"] = round(time.monotonic() - scenario_started, 3)
        scenario["status"] = "launching"
        scenario["phase"] = "launch"
        started = time.monotonic()
        deadline = started + READINESS_DEADLINE_SECONDS
        write_manifest(manifest)
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
            scenario["phase"] = "screenshot"
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
            scenario["phase"] = "text_recognition"
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
            scenario["phase"] = "visible_content_check"
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
        scenario["scenario_elapsed_seconds"] = round(time.monotonic() - scenario_started, 3)
        if started is not None:
            scenario["elapsed_seconds"] = round(time.monotonic() - started, 3)
        scenario["error_details"] = failure_details(error)
        scenario["error"] = scenario["error_details"]["message"]
        if scenario["attempts"] and scenario["attempts"][-1]["status"] in {"capturing", "recognizing"}:
            scenario["attempts"][-1]["status"] = "failed"
            scenario["attempts"][-1]["error"] = scenario["error"]
        write_manifest(manifest)
        raise RuntimeError(f"{name} failed during {scenario['phase']}. "
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
    capture_failed = False
    try:
        helper = compile_text_reader()
        manifest["capture_status"] = "capturing"
        write_manifest(manifest)
        for name, args, required in SCENARIOS:
            capture_when_visible(udid, helper, name, args, required, manifest)
        manifest["capture_status"] = "complete"
        write_manifest(manifest)
    except Exception as error:
        capture_failed = True
        manifest["capture_status"] = "failed"
        manifest["error_details"] = failure_details(error)
        manifest["error"] = manifest["error_details"]["message"]
        write_manifest(manifest)
        raise
    finally:
        try:
            run("xcrun", "simctl", "terminate", udid, BUNDLE, timeout=10, check=False)
        except Exception as error:
            manifest["cleanup_error"] = failure_details(error)
            write_manifest(manifest)
            print("Cleanup failed: " + manifest["cleanup_error"]["message"], flush=True)
            # A second timeout must not replace the original launch/readiness
            # exception. If capture succeeded, cleanup failure still fails CI.
            if not capture_failed:
                raise
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
