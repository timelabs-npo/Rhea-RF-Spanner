#!/usr/bin/env python3
"""Manual-signing CI helper. Never print credentials or raw signing-tool output.

`preflight` is read-only and needs no credentials. `archive` and `upload` run on
an ephemeral GitHub-hosted Mac; both clean up in finally, with an additional
workflow `always()` cleanup step. The source checkout and trusted tooling are
separate. No Apple certificate, profile, API key, or account is created here.
"""
from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import json
import os
import plistlib
import re
import secrets
import shlex
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

SECRET_NAMES = (
    "APPLE_DISTRIBUTION_P12_BASE64", "APPLE_DISTRIBUTION_P12_PASSWORD",
    "APP_STORE_PROFILE_BASE64", "ASC_PRIVATE_KEY_P8_BASE64",
)
SHA_RE = re.compile(r"[0-9a-f]{40}\Z")
TEAM_RE = re.compile(r"[A-Z0-9]{10}\Z")
BUNDLE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9-]*(?:\.[A-Za-z0-9][A-Za-z0-9-]*)+\Z")
UUID_RE = re.compile(r"[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12}\Z")


class ReleaseError(Exception):
    """Only fixed, credential-free messages may be emitted to CI logs."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ReleaseError(message)


def required(name: str) -> str:
    value = os.environ.get(name, "")
    require(bool(value), f"Missing required protected environment setting: {name}.")
    return value


def child_environment() -> dict[str, str]:
    # Build phases never inherit credential payloads or their passwords.
    environment = dict(os.environ)
    for name in SECRET_NAMES + ("ASC_KEY_ID", "ASC_ISSUER_ID"):
        environment.pop(name, None)
    return environment


def capture(command: list[str], failure: str, cwd: Path | None = None,
            combine_output: bool = False) -> str:
    result = subprocess.run(command, cwd=cwd, env=child_environment(),
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    require(result.returncode == 0, failure)
    output = result.stdout + result.stderr if combine_output else result.stdout
    return output.decode("utf-8", errors="replace")


def write_private(path: Path, data: bytes) -> None:
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "wb") as handle:
        handle.write(data)


def decode_secret(name: str) -> bytes:
    try:
        value = base64.b64decode("".join(required(name).split()), validate=True)
    except (ValueError, binascii.Error):
        raise ReleaseError(f"{name} must contain standard base64 for the original file.") from None
    require(bool(value), f"{name} decoded to an empty file.")
    return value


def validate_inputs() -> tuple[str, str]:
    commit, build = required("SOURCE_COMMIT"), required("BUILD_NUMBER")
    require(bool(SHA_RE.fullmatch(commit)), "SOURCE_COMMIT must be a full lowercase 40-character commit SHA.")
    require(bool(re.fullmatch(r"[1-9][0-9]{0,3}", build)), "BUILD_NUMBER must be an explicit integer from 1 through 9999.")
    return commit, build


def preflight() -> tuple[str, str]:
    require(sys.platform == "darwin", "This command requires macOS with Xcode. Linux can validate syntax and generated files only.")
    version = capture(["xcodebuild", "-version"], "The selected Xcode is unavailable. Check DEVELOPER_DIR.")
    match = re.search(r"^Xcode (\d+)(?:\.\d+)*$", version, re.MULTILINE)
    require(match is not None and int(match.group(1)) >= 26, "Select Xcode 26 or later for current App Store Connect submissions.")
    sdk = capture(["xcrun", "--sdk", "iphoneos", "--show-sdk-version"], "The selected Xcode does not provide an iPhoneOS SDK.").strip()
    require(bool(re.fullmatch(r"\d+(?:\.\d+)*", sdk)) and int(sdk.split(".")[0]) >= 26,
            "The selected iPhoneOS SDK must be version 26 or later.")
    help_text = capture(["xcodebuild", "-help"], "Unable to inspect the selected Xcode export options.", combine_output=True)
    for token in ("app-store-connect", "destination", "signingStyle", "signingCertificate",
                  "teamID", "provisioningProfiles", "manageAppVersionAndBuildNumber", "uploadSymbols"):
        require(token in help_text, f"The installed xcodebuild help does not advertise required export option: {token}.")
    altool_help = capture(["xcrun", "altool", "--help"], "The selected Xcode does not provide usable altool help.", combine_output=True)
    for token in ("--validate-app", "--upload-app", "--apiKey", "--apiIssuer"):
        require(token in altool_help, f"The installed altool help does not advertise required option: {token}.")
    print("Read-only preflight passed: Xcode export options and altool API-key upload interface are available.")
    print(version.strip())
    print("iPhoneOS SDK " + sdk)
    return version.strip(), sdk


def validate_profile(profile: dict, identities: str, team: str, bundle: str,
                     now: datetime | None = None) -> dict[str, str]:
    """Check an App Store profile and a `security find-identity -v` result."""
    require(bool(TEAM_RE.fullmatch(team)), "APPLE_TEAM_ID must be the actual 10-character uppercase Apple team ID.")
    require(bool(BUNDLE_RE.fullmatch(bundle)), "APP_BUNDLE_ID must be the registered explicit bundle identifier; wildcards and placeholders are unsupported.")
    require(isinstance(profile, dict), "The provisioning profile payload is not a property-list dictionary.")
    identifier = profile.get("UUID", "")
    require(isinstance(identifier, str) and bool(UUID_RE.fullmatch(identifier)), "The provisioning profile has no valid UUID.")
    require(profile.get("TeamIdentifier") == [team], "Provisioning profile team does not match APPLE_TEAM_ID.")
    platforms = profile.get("Platform", [])
    require(isinstance(platforms, list) and "iOS" in platforms, "Supply an iOS App Store Connect provisioning profile.")
    require("ProvisionedDevices" not in profile and not profile.get("ProvisionsAllDevices", False),
            "Development, Ad Hoc, and Enterprise profiles are unsupported; supply an App Store Connect distribution profile.")
    entitlements = profile.get("Entitlements", {})
    require(isinstance(entitlements, dict), "Provisioning profile entitlements are missing or malformed.")
    require(entitlements.get("get-task-allow") is False and entitlements.get("beta-reports-active") is True,
            "The profile must disable debugging and enable App Store/TestFlight distribution (beta-reports-active).")
    require(entitlements.get("com.apple.developer.team-identifier") == team,
            "The profile's team entitlement does not match APPLE_TEAM_ID.")
    prefixes = profile.get("ApplicationIdentifierPrefix", [])
    require(isinstance(prefixes, list) and prefixes and all(isinstance(p, str) and TEAM_RE.fullmatch(p) for p in prefixes),
            "The profile has no valid App ID prefix.")
    application_identifier = entitlements.get("application-identifier")
    # Legacy App ID prefixes can differ from Team ID. Validate them separately.
    require(application_identifier in [prefix + "." + bundle for prefix in prefixes],
            "The profile's explicit application identifier does not match APP_BUNDLE_ID and its App ID prefix.")
    now = now or datetime.now(timezone.utc)
    expiry = profile.get("ExpirationDate")
    require(isinstance(expiry, datetime), "The provisioning profile has no valid expiration date.")
    expiry = expiry.replace(tzinfo=timezone.utc) if expiry.tzinfo is None else expiry.astimezone(timezone.utc)
    require(expiry > now, "The provisioning profile has expired. Renew the App Store Connect profile before retrying.")
    created = profile.get("CreationDate")
    if isinstance(created, datetime):
        created = created.replace(tzinfo=timezone.utc) if created.tzinfo is None else created.astimezone(timezone.utc)
        require(created <= now + timedelta(minutes=5), "The profile is not yet valid. Check the runner clock and supplied profile.")
    certificates = profile.get("DeveloperCertificates", [])
    require(isinstance(certificates, list) and certificates and all(isinstance(c, bytes) and c for c in certificates),
            "The provisioning profile contains no usable distribution certificates.")
    valid_identities = re.findall(r'^\s*\d+\) ([0-9A-Fa-f]{40}) "(.*?)"\s*$', identities, re.MULTILINE)
    require(len(valid_identities) == 1, "The p12 must contain exactly one valid code-signing identity with its private key. Check certificate expiry, trust chain, and export contents.")
    fingerprint, common_name = valid_identities[0]
    require(common_name.startswith(("Apple Distribution:", "iPhone Distribution:")),
            "The imported identity must be an Apple Distribution certificate, not a development identity.")
    fingerprint = fingerprint.upper()
    allowed_fingerprints = {hashlib.sha1(c).hexdigest().upper() for c in certificates}
    require(fingerprint in allowed_fingerprints, "The p12 signing certificate is not included in this provisioning profile. Export the matching certificate/private key or regenerate the profile with that certificate.")
    return {"profile_uuid": identifier, "certificate_sha1": fingerprint, "team_id": team,
            "bundle_id": bundle, "application_identifier": application_identifier}


def export_options(metadata: dict[str, str]) -> dict:
    return {
        "method": "app-store-connect", "destination": "export", "signingStyle": "manual",
        "teamID": metadata["team_id"], "signingCertificate": metadata["certificate_sha1"],
        "provisioningProfiles": {metadata["bundle_id"]: metadata["profile_uuid"]},
        "manageAppVersionAndBuildNumber": False, "uploadSymbols": False,
    }


def signing_config(metadata: dict[str, str], build: str, keychain: Path) -> str:
    path = str(keychain).replace("\\", "\\\\").replace('"', '\\"')
    return ("// Temporary CI signing settings; removed after export.\n"
            "CODE_SIGN_STYLE = Manual\n"
            f"DEVELOPMENT_TEAM = {metadata['team_id']}\n"
            f"PRODUCT_BUNDLE_IDENTIFIER = {metadata['bundle_id']}\n"
            f"CURRENT_PROJECT_VERSION = {build}\n"
            f"CODE_SIGN_IDENTITY = {metadata['certificate_sha1']}\n"
            f"PROVISIONING_PROFILE_SPECIFIER = {metadata['profile_uuid']}\n"
            f'OTHER_CODE_SIGN_FLAGS = $(inherited) --keychain "{path}"\n')


class Context:
    def __init__(self) -> None:
        temporary = Path(required("RUNNER_TEMP")).resolve()
        run, attempt = required("GITHUB_RUN_ID"), required("GITHUB_RUN_ATTEMPT")
        require(run.isdecimal() and attempt.isdecimal(), "Invalid GitHub run identity for temporary signing paths.")
        self.private = temporary / f"rhea-testflight-private-{run}-{attempt}"
        self.output = temporary / f"rhea-testflight-output-{run}-{attempt}"
        require(Path(required("RHEA_OUTPUT_DIR")).resolve() == self.output,
                "RHEA_OUTPUT_DIR must be the dedicated output directory for this workflow run.")
        workspace = Path(required("GITHUB_WORKSPACE")).resolve()
        self.source = Path(required("RHEA_SOURCE_DIR")).resolve()
        require(self.source == workspace / "source", "RHEA_SOURCE_DIR must be the separate source checkout in this workflow.")
        self.profile_directory = Path.home() / "Library/Developer/Xcode/UserData/Provisioning Profiles"
        self.api_directory = Path.home() / ".appstoreconnect/private_keys"
        self.keychain = self.private / "signing.keychain-db"
        self.state: dict = {}

    def start(self) -> None:
        require(not self.private.exists(), "Temporary signing state already exists; run cleanup before retrying.")
        self.private.mkdir(mode=0o700)
        self.save_state()

    def save_state(self) -> None:
        temporary = self.private / "state.next"
        if temporary.exists():
            temporary.unlink()
        write_private(temporary, json.dumps(self.state).encode())
        temporary.replace(self.private / "state.json")

    def run(self, command: list[str], label: str, log: str) -> None:
        with (self.private / log).open("wb") as handle:
            result = subprocess.run(command, cwd=self.source, env=child_environment(),
                                    stdout=handle, stderr=subprocess.STDOUT, check=False)
        require(result.returncode == 0, label + f" Tool exit status: {result.returncode}. Raw signing-tool logs remain private and are removed during cleanup.")

    def decode_profile(self, profile_path: Path, name: str) -> dict:
        decoded = self.private / name
        self.run(["security", "cms", "-D", "-i", str(profile_path), "-o", str(decoded)],
                 "The provisioning profile could not be decoded. Supply the original Apple-issued mobileprovision file.", name + ".log")
        with decoded.open("rb") as handle:
            return plistlib.load(handle)

    def cleanup(self) -> bool:
        if not self.private.exists():
            return True
        failures: list[str] = []
        try:
            self.state = json.loads((self.private / "state.json").read_text())
        except (OSError, ValueError):
            failures.append("Temporary signing state could not be read.")

        def quiet_cleanup(command: list[str]) -> bool:
            try:
                return subprocess.run(command, stdout=subprocess.DEVNULL,
                                      stderr=subprocess.DEVNULL, check=False).returncode == 0
            except OSError:
                return False

        if self.state.get("search_list_changed"):
            if not quiet_cleanup(["security", "list-keychains", "-d", "user", "-s", *self.state.get("original_search_list", [])]):
                failures.append("Could not restore the original keychain search list.")
        if self.keychain.exists():
            if not quiet_cleanup(["security", "delete-keychain", str(self.keychain)]):
                failures.append("Could not delete the temporary signing keychain.")
        profile_uuid = self.state.get("installed_profile_uuid")
        if isinstance(profile_uuid, str) and UUID_RE.fullmatch(profile_uuid):
            try:
                (self.profile_directory / (profile_uuid + ".mobileprovision")).unlink(missing_ok=True)
            except OSError:
                failures.append("Could not remove the temporary provisioning profile.")
        key_id = self.state.get("installed_api_key_id")
        if isinstance(key_id, str) and TEAM_RE.fullmatch(key_id):
            try:
                (self.api_directory / ("AuthKey_" + key_id + ".p8")).unlink(missing_ok=True)
            except OSError:
                failures.append("Could not remove the temporary App Store Connect key file.")
        if self.state.get("created_signing_config"):
            try:
                (self.source / "Config/Signing.local.xcconfig").unlink(missing_ok=True)
            except OSError:
                failures.append("Could not remove the temporary signing configuration.")
        try:
            shutil.rmtree(self.private)
        except OSError:
            failures.append("Could not remove the private temporary signing directory.")
        for failure in failures:
            print("::error::" + failure, file=sys.stderr)
        return not failures


def verify_product(context: Context, app: Path, metadata: dict[str, str], identities: str,
                   build: str, prefix: str) -> dict:
    require(app.is_dir(), "The expected application bundle is missing from the archive or exported IPA.")
    with (app / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    require(info.get("CFBundleIdentifier") == metadata["bundle_id"], "The built application bundle identifier does not match the approved profile.")
    require(str(info.get("CFBundleVersion")) == build, "The built application version does not match the requested build number.")
    profile = context.decode_profile(app / "embedded.mobileprovision", prefix + "-profile.plist")
    actual = validate_profile(profile, identities, metadata["team_id"], metadata["bundle_id"])
    require(actual["profile_uuid"] == metadata["profile_uuid"], "Xcode used a different provisioning profile than the one approved for this run.")
    context.run(["codesign", "--verify", "--deep", "--strict", str(app)],
                "The archived/exported application failed local code-signature verification.", prefix + "-verify.log")
    entitlements_path = context.private / (prefix + "-entitlements.plist")
    with entitlements_path.open("wb") as output, (context.private / (prefix + "-entitlements.log")).open("wb") as error:
        result = subprocess.run(["codesign", "-d", "--entitlements", ":-", str(app)],
                                stdout=output, stderr=error, env=child_environment(), check=False)
    require(result.returncode == 0, "Unable to read the application's signed entitlements.")
    with entitlements_path.open("rb") as handle:
        entitlements = plistlib.load(handle)
    require(entitlements.get("application-identifier") == metadata["application_identifier"]
            and entitlements.get("com.apple.developer.team-identifier") == metadata["team_id"]
            and entitlements.get("get-task-allow", False) is False,
            "Signed application entitlements do not match the approved team/App ID or permit debugging.")
    return info


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def archive(context: Context) -> None:
    commit, build = validate_inputs()
    version, sdk = preflight()
    require(capture(["git", "rev-parse", "HEAD"], "Unable to read the source commit.", context.source).strip() == commit,
            "Source checkout does not match the requested full commit SHA.")
    require(not capture(["git", "status", "--porcelain", "--untracked-files=all"], "Unable to inspect source checkout.", context.source).strip(),
            "The source checkout must be clean before signing settings are generated.")
    require('#include? "Signing.local.xcconfig"' in (context.source / "Config/Project.xcconfig").read_text(),
            "This source revision does not include the required app-target signing override.")
    team, bundle = required("APPLE_TEAM_ID"), required("APP_BUNDLE_ID")
    require(bool(TEAM_RE.fullmatch(team)) and bool(BUNDLE_RE.fullmatch(bundle)), "Supply the real registered APPLE_TEAM_ID and APP_BUNDLE_ID in the protected testflight environment.")
    p12_password = required("APPLE_DISTRIBUTION_P12_PASSWORD")
    context.start()
    p12, profile = context.private / "distribution.p12", context.private / "profile.mobileprovision"
    write_private(p12, decode_secret("APPLE_DISTRIBUTION_P12_BASE64"))
    write_private(profile, decode_secret("APP_STORE_PROFILE_BASE64"))
    # This random password protects only a temporary local keychain. It is not
    # an Apple credential or a newly created GitHub environment secret.
    keychain_password = secrets.token_urlsafe(32)
    original = capture(["security", "list-keychains", "-d", "user"], "Unable to inspect the runner's keychain search list.")
    context.state["original_search_list"] = shlex.split(original)
    context.save_state()
    context.run(["security", "create-keychain", "-p", keychain_password, str(context.keychain)], "Unable to create the temporary signing keychain.", "keychain-create.log")
    context.run(["security", "set-keychain-settings", "-lut", "7200", str(context.keychain)], "Unable to configure the temporary keychain timeout.", "keychain-settings.log")
    context.run(["security", "unlock-keychain", "-p", keychain_password, str(context.keychain)], "Unable to unlock the temporary signing keychain.", "keychain-unlock.log")
    context.run(["security", "import", str(p12), "-k", str(context.keychain), "-P", p12_password, "-T", "/usr/bin/codesign"],
                "Unable to import the p12. Check its password and confirm that it includes the distribution private key.", "keychain-import.log")
    context.run(["security", "set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychain_password, str(context.keychain)],
                "Unable to grant Apple's signing tools access to the imported private key.", "keychain-partition.log")
    context.state["search_list_changed"] = True
    context.save_state()
    context.run(["security", "list-keychains", "-d", "user", "-s", str(context.keychain)], "Unable to select the temporary signing keychain.", "keychain-search.log")
    identities = capture(["security", "find-identity", "-v", "-p", "codesigning", str(context.keychain)], "Unable to inspect valid signing identities in the temporary keychain.")
    payload = context.decode_profile(profile, "profile.plist")
    metadata = validate_profile(payload, identities, team, bundle)
    print("Signing preflight passed: App Store profile type, expiry, team, explicit App ID, and matching distribution identity.")
    installed_profile = context.profile_directory / (metadata["profile_uuid"] + ".mobileprovision")
    context.profile_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    require(not installed_profile.exists(), "A profile with this UUID is already installed; refusing to replace runner signing state.")
    context.state["installed_profile_uuid"] = metadata["profile_uuid"]
    context.save_state()
    write_private(installed_profile, profile.read_bytes())
    configuration = context.source / "Config/Signing.local.xcconfig"
    require(not configuration.exists(), "A local signing configuration already exists; refusing to overwrite it.")
    context.state["created_signing_config"] = True
    context.save_state()
    write_private(configuration, signing_config(metadata, build, context.keychain).encode())
    options = context.private / "ExportOptions.plist"
    write_private(options, plistlib.dumps(export_options(metadata)))
    project = ["xcodebuild", "-project", str(context.source / "RheaRFSpanner.xcodeproj"),
               "-scheme", "RheaRFSpanner", "-configuration", "Release", "-destination", "generic/platform=iOS"]
    settings = json.loads(capture(project + ["-showBuildSettings", "-json"], "Unable to inspect the app target's signing build settings.", context.source))
    selected = [item.get("buildSettings", {}) for item in settings if item.get("target") == "RheaRFSpanner"]
    require(len(selected) == 1, "The expected application target was not found in the selected source revision.")
    expected = {"CODE_SIGN_STYLE": "Manual", "DEVELOPMENT_TEAM": team, "PRODUCT_BUNDLE_IDENTIFIER": bundle,
                "CURRENT_PROJECT_VERSION": build, "PROVISIONING_PROFILE_SPECIFIER": metadata["profile_uuid"],
                "CODE_SIGN_IDENTITY": metadata["certificate_sha1"]}
    require(all(str(selected[0].get(key)) == value for key, value in expected.items()),
            "Xcode did not apply the expected manual app-target signing settings. Review the selected revision's build configuration.")
    require(not context.output.exists(), "The release output directory already exists; refusing to reuse an earlier export.")
    context.output.mkdir(mode=0o700)
    archive_path = context.output / "RheaRFSpanner.xcarchive"
    print("Archiving the exact source commit with the validated manual signing configuration.")
    context.run(project + ["-archivePath", str(archive_path), "-derivedDataPath", str(context.private / "DerivedData"), "archive"],
                "The Release archive failed. Reproduce the archive with the same source and signing settings in Xcode to inspect source, entitlement, or signing diagnostics.", "archive.log")
    verify_product(context, archive_path / "Products/Applications/RheaRFSpanner.app", metadata, identities, build, "archive")
    export_path = context.private / "export"
    print("Exporting an App Store Connect IPA locally; automatic upload and version management are disabled.")
    context.run(["xcodebuild", "-exportArchive", "-archivePath", str(archive_path), "-exportOptionsPlist", str(options), "-exportPath", str(export_path)],
                "App Store Connect IPA export failed. Verify that the selected Xcode supports the manual export options and that the profile covers the app's entitlements.", "export.log")
    ipa_files = list(export_path.glob("*.ipa"))
    require(len(ipa_files) == 1, "Export did not produce exactly one IPA; no file is eligible for upload.")
    unpacked = context.private / "exported-product"
    context.run(["ditto", "-x", "-k", str(ipa_files[0]), str(unpacked)], "Unable to inspect the exported application.", "unpack.log")
    info = verify_product(context, unpacked / "Payload/RheaRFSpanner.app", metadata, identities, build, "export")
    ipa = context.output / "RheaRFSpanner.ipa"
    shutil.move(str(ipa_files[0]), ipa)
    archive_zip = context.output / "RheaRFSpanner.xcarchive.zip"
    context.run(["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(archive_path), str(archive_zip)], "Unable to package the signed archive.", "archive-zip.log")
    manifest = {"source_commit": commit, "workflow_commit": required("WORKFLOW_COMMIT"),
                "version": info.get("CFBundleShortVersionString"), "build_number": build,
                "xcode": version, "iphoneos_sdk": sdk,
                "ipa_sha256": sha256_file(ipa), "archive_zip_sha256": sha256_file(archive_zip),
                "local_signature_and_profile_checks": "passed", "apple_validation": "not_requested", "apple_upload": "not_requested"}
    (context.output / "release-manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    if os.environ.get("GITHUB_OUTPUT"):
        with Path(os.environ["GITHUB_OUTPUT"]).open("a") as output:
            output.write("exported=true\n")
    print("Signed archive and IPA export completed. No App Store Connect upload has been performed by this command.")


def upload(context: Context) -> None:
    require(os.environ.get("UPLOAD_TO_TESTFLIGHT") == "true", "Upload is disabled. Set the workflow's explicit upload_to_testflight input to true to request Apple validation and upload.")
    commit, build = validate_inputs()
    require(sys.platform == "darwin", "App Store Connect upload requires the selected macOS/Xcode toolchain.")
    manifest_path = context.output / "release-manifest.json"
    require(manifest_path.is_file(), "A successful verified export is required before upload.")
    manifest = json.loads(manifest_path.read_text())
    ipa = context.output / "RheaRFSpanner.ipa"
    require(manifest.get("source_commit") == commit and manifest.get("build_number") == build
            and manifest.get("local_signature_and_profile_checks") == "passed"
            and ipa.is_file() and manifest.get("ipa_sha256") == sha256_file(ipa),
            "The exported IPA or manifest does not match this workflow's verified source/build. Upload refused.")
    key_id, issuer = required("ASC_KEY_ID"), required("ASC_ISSUER_ID")
    require(bool(TEAM_RE.fullmatch(key_id)), "ASC_KEY_ID must be the issued 10-character App Store Connect team API key ID.")
    require(bool(UUID_RE.fullmatch(issuer)), "ASC_ISSUER_ID must be the UUID for the App Store Connect team API key issuer.")
    context.start()
    context.api_directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    key_path = context.api_directory / ("AuthKey_" + key_id + ".p8")
    require(not key_path.exists(), "An App Store Connect key with this ID already exists on the runner; refusing to replace it.")
    data = decode_secret("ASC_PRIVATE_KEY_P8_BASE64")
    require(b"-----BEGIN PRIVATE KEY-----" in data and b"-----END PRIVATE KEY-----" in data,
            "ASC_PRIVATE_KEY_P8_BASE64 must decode to the original Apple-issued PKCS#8 private key.")
    context.state["installed_api_key_id"] = key_id
    context.save_state()
    write_private(key_path, data)
    curve = context.private / "api-key-curve.der"
    context.run(["openssl", "ec", "-in", str(key_path), "-param_out", "-outform", "DER", "-out", str(curve)],
                "The App Store Connect private key could not be read as an EC key.", "api-key-check.log")
    require(curve.read_bytes() == bytes.fromhex("06082a8648ce3d030107"), "The App Store Connect API key must use Apple's expected P-256 curve.")
    authentication = ["--apiKey", key_id, "--apiIssuer", issuer]
    print("The explicit upload request is enabled. Validating the exported IPA with Apple.")
    manifest["apple_validation"] = "requested_outcome_pending"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    context.run(["xcrun", "altool", "--validate-app", "-f", str(ipa), "-t", "ios", *authentication],
                "Apple validation failed. Check the App Store Connect app record, API key/issuer and role, build number, required agreements, and submitted app metadata.", "altool-validate.log")
    manifest["apple_validation"] = "passed"
    manifest["apple_upload"] = "requested_outcome_pending"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    context.run(["xcrun", "altool", "--upload-app", "-f", str(ipa), "-t", "ios", *authentication],
                "Apple upload failed after validation. Check whether the build number was already received before retrying; do not assume the upload was rolled back.", "altool-upload.log")
    manifest["apple_upload"] = "accepted_by_upload_tool_processing_pending"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    print("Upload tool reported success. Apple processing, TestFlight availability, tester assignment, and review are separate steps.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("preflight", "toolchain", "archive", "upload", "cleanup"))
    arguments = parser.parse_args()
    os.umask(0o077)
    context: Context | None = None
    status = 0
    try:
        if arguments.command in ("preflight", "toolchain"):
            preflight()
        else:
            context = Context()
            if arguments.command == "archive":
                archive(context)
            elif arguments.command == "upload":
                upload(context)
    except ReleaseError as error:
        print("::error::" + str(error), file=sys.stderr)
        status = 1
    except (OSError, ValueError, TypeError, KeyError, plistlib.InvalidFileException):
        # Exception details may quote key/profile contents; never emit them.
        print("::error::A required signing file, tool result, or generated property list could not be read. Check the selected source and Apple-issued input files.", file=sys.stderr)
        status = 1
    finally:
        if context is not None and not context.cleanup():
            status = 1
    return status


if __name__ == "__main__":
    raise SystemExit(main())
