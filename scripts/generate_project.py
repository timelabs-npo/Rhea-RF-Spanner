#!/usr/bin/env python3
"""Generate the committed Xcode application project without XcodeGen or Ruby.

The app links the local RheaRFCore Swift package. Running this script only
rewrites the project and shared scheme; it never changes signing material.
"""
from __future__ import annotations

import hashlib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT = ROOT / "RheaRFSpanner.xcodeproj"


def uid(label: str) -> str:
    return hashlib.sha256(label.encode()).hexdigest()[:24].upper()


def quote(value: str) -> str:
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"') + '"'


def main() -> None:
    sources = sorted(p.relative_to(ROOT).as_posix()
                     for p in (ROOT / "App/Sources").rglob("*")
                     if p.suffix in {".swift", ".metal"})
    test_sources = sorted(p.relative_to(ROOT).as_posix()
                          for p in (ROOT / "AppTests").glob("*.swift"))
    if not sources:
        raise SystemExit("No app sources found; refusing to create an empty app target.")
    resources = ["App/Resources/Assets.xcassets", "App/Resources/PrivacyInfo.xcprivacy"]
    policy = ROOT / "App/Resources/PrivacyPolicy.txt"
    if policy.exists():
        resources.append(policy.relative_to(ROOT).as_posix())
    support = ["App/Resources/Info.plist", "Config/Project.xcconfig", "Config/Signing.example.xcconfig"]
    objects: list[tuple[str, str]] = []

    def add(label: str, body: str) -> str:
        ident = uid(label)
        objects.append((ident, body))
        return ident

    file_refs: dict[str, str] = {}
    for path in sources + resources + support + test_sources:
        ext = Path(path).suffix
        kind = {".swift": "sourcecode.swift", ".metal": "sourcecode.metal",
                ".xcassets": "folder.assetcatalog", ".xcconfig": "text.xcconfig",
                ".plist": "text.plist.xml", ".xcprivacy": "text.xml"}.get(ext, "text")
        file_refs[path] = add("file:" + path,
            f"isa = PBXFileReference; lastKnownFileType = {kind}; path = {quote(path)}; sourceTree = SOURCE_ROOT;")

    source_builds = [add("build:" + p, f"isa = PBXBuildFile; fileRef = {file_refs[p]};") for p in sources]
    resource_builds = [add("build:" + p, f"isa = PBXBuildFile; fileRef = {file_refs[p]};") for p in resources]
    package = add("local-package", 'isa = XCLocalSwiftPackageReference; relativePath = ".";')
    product = add("package-product", f"isa = XCSwiftPackageProductDependency; package = {package}; productName = RheaRFCore;")
    package_build = add("package-build", f"isa = PBXBuildFile; productRef = {product};")
    source_phase = add("source-phase", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" + ",".join(source_builds) + "); runOnlyForDeploymentPostprocessing = 0;")
    resource_phase = add("resource-phase", "isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (" + ",".join(resource_builds) + "); runOnlyForDeploymentPostprocessing = 0;")
    framework_phase = add("framework-phase", f"isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = ({package_build},); runOnlyForDeploymentPostprocessing = 0;")
    app_product = add("app-product", 'isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = RheaRFSpanner.app; sourceTree = BUILT_PRODUCTS_DIR;')
    app_group = add("app-group", 'isa = PBXGroup; name = App; sourceTree = "<group>"; children = (' + ",".join(file_refs[p] for p in sources + resources + support[:1]) + ");")
    config_group = add("config-group", 'isa = PBXGroup; name = Config; sourceTree = "<group>"; children = (' + ",".join(file_refs[p] for p in support[1:]) + ");")
    products_group = add("products-group", f'isa = PBXGroup; name = Products; sourceTree = "<group>"; children = ({app_product},);')
    tests_group = add("tests-group", 'isa = PBXGroup; name = AppTests; sourceTree = "<group>"; children = (' + ",".join(file_refs[p] for p in test_sources) + ");")
    main_group = add("main-group", f'isa = PBXGroup; sourceTree = "<group>"; children = ({app_group},{tests_group},{config_group},{products_group},);')
    project_configs: list[str] = []
    target_configs: list[str] = []
    for name in ("Debug", "Release"):
        debug = name == "Debug"
        project_configs.append(add("project-config:" + name,
            f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ SDKROOT = iphoneos; CLANG_WARN_DOCUMENTATION_COMMENTS = YES; GCC_WARN_UNINITIALIZED_AUTOS = YES_AGGRESSIVE; CLANG_WARN_OBJC_IMPLICIT_RETAIN_SELF = YES; }};'))
        settings = 'SWIFT_OPTIMIZATION_LEVEL = "-Onone"; SWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG $(inherited)"; DEBUG_INFORMATION_FORMAT = dwarf; ENABLE_TESTABILITY = YES;' if debug else 'SWIFT_OPTIMIZATION_LEVEL = "-O"; SWIFT_COMPILATION_MODE = wholemodule; DEBUG_INFORMATION_FORMAT = "dwarf-with-dsym"; VALIDATE_PRODUCT = YES;'
        target_configs.append(add("target-config:" + name,
            f'isa = XCBuildConfiguration; name = {name}; baseConfigurationReference = {file_refs["Config/Project.xcconfig"]}; buildSettings = {{ {settings} }};'))
    project_config_list = add("project-config-list", "isa = XCConfigurationList; buildConfigurations = (" + ",".join(project_configs) + "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    target_config_list = add("target-config-list", "isa = XCConfigurationList; buildConfigurations = (" + ",".join(target_configs) + "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;")
    target = add("app-target", f'isa = PBXNativeTarget; buildConfigurationList = {target_config_list}; buildPhases = ({source_phase},{framework_phase},{resource_phase},); buildRules = (); dependencies = (); name = RheaRFSpanner; packageProductDependencies = ({product},); productName = RheaRFSpanner; productReference = {app_product}; productType = "com.apple.product-type.application";')
    test_product = add("test-product", 'isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = RheaRFSpannerTests.xctest; sourceTree = BUILT_PRODUCTS_DIR;')
    test_builds = [add("test-build:" + p, f"isa = PBXBuildFile; fileRef = {file_refs[p]};") for p in test_sources]
    test_phase = add("test-source-phase", "isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = (" + ",".join(test_builds) + "); runOnlyForDeploymentPostprocessing = 0;")
    test_framework_phase = add("test-framework-phase", "isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;")
    test_configs = []
    for name in ("Debug", "Release"):
        optimization = "-Onone" if name == "Debug" else "-O"
        test_configs.append(add("test-config:" + name,
            f'isa = XCBuildConfiguration; name = {name}; buildSettings = {{ PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = org.timelabs.RheaRFSpanner.Tests; GENERATE_INFOPLIST_FILE = YES; IPHONEOS_DEPLOYMENT_TARGET = 18.0; SWIFT_VERSION = 6.0; SWIFT_STRICT_CONCURRENCY = complete; SWIFT_OPTIMIZATION_LEVEL = "{optimization}"; TEST_HOST = "$(BUILT_PRODUCTS_DIR)/RheaRFSpanner.app/RheaRFSpanner"; BUNDLE_LOADER = "$(TEST_HOST)"; TARGETED_DEVICE_FAMILY = 1; LD_RUNPATH_SEARCH_PATHS = "$(inherited) @executable_path/Frameworks @loader_path/Frameworks"; }};'))
    test_config_list = add("test-config-list", "isa = XCConfigurationList; buildConfigurations = (" + ",".join(test_configs) + "); defaultConfigurationIsVisible = 0; defaultConfigurationName = Debug;")
    test_proxy = add("test-app-proxy", f'isa = PBXContainerItemProxy; containerPortal = {uid("project")}; proxyType = 1; remoteGlobalIDString = {target}; remoteInfo = RheaRFSpanner;')
    test_dependency = add("test-app-dependency", f"isa = PBXTargetDependency; target = {target}; targetProxy = {test_proxy};")
    test_target = add("test-target", f'isa = PBXNativeTarget; buildConfigurationList = {test_config_list}; buildPhases = ({test_phase},{test_framework_phase},); buildRules = (); dependencies = ({test_dependency},); name = RheaRFSpannerTests; productName = RheaRFSpannerTests; productReference = {test_product}; productType = "com.apple.product-type.bundle.unit-test";')
    project = add("project", f'isa = PBXProject; attributes = {{ BuildIndependentTargetsInParallel = YES; }}; buildConfigurationList = {project_config_list}; compatibilityVersion = "Xcode 14.0"; developmentRegion = en; hasScannedForEncodings = 0; knownRegions = (en,Base,); mainGroup = {main_group}; packageReferences = ({package},); productRefGroup = {products_group}; projectDirPath = ""; projectRoot = ""; targets = ({target},{test_target},);')
    contents = "// !$*UTF8*$!\n{\n\tarchiveVersion = 1;\n\tclasses = {};\n\tobjectVersion = 56;\n\tobjects = {\n"
    contents += "".join(f"\t\t{ident} = {{ {body} }};\n" for ident, body in objects)
    contents += f"\t}};\n\trootObject = {project};\n}}\n"
    PROJECT.mkdir(exist_ok=True)
    (PROJECT / "project.pbxproj").write_text(contents)
    scheme_dir = PROJECT / "xcshareddata/xcschemes"
    scheme_dir.mkdir(parents=True, exist_ok=True)
    buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{target}" BuildableName="RheaRFSpanner.app" BlueprintName="RheaRFSpanner" ReferencedContainer="container:RheaRFSpanner.xcodeproj"/>'
    test_buildable = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{test_target}" BuildableName="RheaRFSpannerTests.xctest" BlueprintName="RheaRFSpannerTests" ReferencedContainer="container:RheaRFSpanner.xcodeproj"/>'
    scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme version="1.3">
  <BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES">
    <BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{buildable}</BuildActionEntry></BuildActionEntries>
  </BuildAction>
  <TestAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" shouldUseLaunchSchemeArgsEnv="YES"><Testables><TestableReference skipped="NO">{test_buildable}</TestableReference></Testables></TestAction>
  <LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="NO"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></LaunchAction>
  <ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{buildable}</BuildableProductRunnable></ProfileAction>
  <AnalyzeAction buildConfiguration="Debug"/>
  <ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
'''
    (scheme_dir / "RheaRFSpanner.xcscheme").write_text(scheme)
    print(f"Generated app project: {len(sources)} source files, {len(resources)} resources.")


if __name__ == "__main__":
    main()
