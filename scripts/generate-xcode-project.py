#!/usr/bin/env python3
"""Reproducible Xcode project; no XcodeGen, CocoaPods or Ruby gems required."""
from pathlib import Path
import hashlib

root = Path(__file__).resolve().parents[1] / "ios"
project = root / "Mediaserver.xcodeproj"
project.mkdir(exist_ok=True)
def ident(name):
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()
objects = []
def obj(name, value):
    objects.append(f"{ident(name)} = {{ {value} }};")
files = sorted((root / "Miniply").glob("*.swift"))
for path in files:
    display_name = 'name = MediaserverApp.swift; ' if path.name == "MiniplyApp.swift" else ""
    obj(path.name, f'isa = PBXFileReference; lastKnownFileType = sourcecode.swift; {display_name}path = {path.name}; sourceTree = "<group>";')
    obj("build:" + path.name, f'isa = PBXBuildFile; fileRef = {ident(path.name)};')
obj("info", 'isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>";')
obj("app", 'isa = PBXFileReference; explicitFileType = wrapper.application; path = Mediaserver.app; sourceTree = BUILT_PRODUCTS_DIR;')
obj("sourcegroup", f'isa = PBXGroup; children = ({",".join(ident(p.name) for p in files)},{ident("info")},); name = Mediaserver; path = Miniply; sourceTree = "<group>";')
obj("products", f'isa = PBXGroup; children = ({ident("app")},); name = Products; sourceTree = "<group>";')
obj("main", f'isa = PBXGroup; children = ({ident("sourcegroup")},{ident("products")},); sourceTree = "<group>";')
obj("sources", f'isa = PBXSourcesBuildPhase; buildActionMask = 2147483647; files = ({",".join(ident("build:"+p.name) for p in files)},); runOnlyForDeploymentPostprocessing = 0;')
obj("frameworks", 'isa = PBXFrameworksBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
obj("resources", 'isa = PBXResourcesBuildPhase; buildActionMask = 2147483647; files = (); runOnlyForDeploymentPostprocessing = 0;')
for level in ["Debug", "Release"]:
    debug = level == "Debug"
    settings = ('SDKROOT = iphoneos; IPHONEOS_DEPLOYMENT_TARGET = 17.0; SWIFT_VERSION = 5.0; CLANG_ENABLE_MODULES = YES; '
                'CLANG_ENABLE_OBJC_ARC = YES; ENABLE_USER_SCRIPT_SANDBOXING = YES; '
                f'SWIFT_OPTIMIZATION_LEVEL = "{"-Onone" if debug else "-O"}"; '
                f'SWIFT_ACTIVE_COMPILATION_CONDITIONS = "{"DEBUG" if debug else ""} $(inherited)"; '
                f'DEBUG_INFORMATION_FORMAT = "{"dwarf" if debug else "dwarf-with-dsym"}";')
    obj("project:" + level, f'isa = XCBuildConfiguration; buildSettings = {{ {settings} }}; name = {level};')
    obj("target:" + level, f'isa = XCBuildConfiguration; buildSettings = {{ CODE_SIGN_STYLE = Automatic; PRODUCT_NAME = "$(TARGET_NAME)"; PRODUCT_BUNDLE_IDENTIFIER = net.miniply.ios; INFOPLIST_FILE = Miniply/Info.plist; MARKETING_VERSION = 1.5; CURRENT_PROJECT_VERSION = 8; TARGETED_DEVICE_FAMILY = "1,2"; SUPPORTED_PLATFORMS = "iphoneos iphonesimulator"; SWIFT_EMIT_LOC_STRINGS = YES; }}; name = {level};')
for kind in ["project", "target"]:
    obj(kind+":configs", f'isa = XCConfigurationList; buildConfigurations = ({ident(kind+":Debug")},{ident(kind+":Release")},); defaultConfigurationIsVisible = 0; defaultConfigurationName = Release;')
obj("target", f'isa = PBXNativeTarget; buildConfigurationList = {ident("target:configs")}; buildPhases = ({ident("sources")},{ident("frameworks")},{ident("resources")},); buildRules = (); dependencies = (); name = Mediaserver; productName = Mediaserver; productReference = {ident("app")}; productType = "com.apple.product-type.application";')
obj("project", f'isa = PBXProject; attributes = {{ LastUpgradeCheck = 2600; }}; buildConfigurationList = {ident("project:configs")}; compatibilityVersion = "Xcode 14.0"; developmentRegion = de; hasScannedForEncodings = 0; knownRegions = (de,en,Base,); mainGroup = {ident("main")}; productRefGroup = {ident("products")}; projectDirPath = ""; projectRoot = ""; targets = ({ident("target")},);')
(project / "project.pbxproj").write_text('// !$*UTF8*$!\n{ archiveVersion = 1; classes = {}; objectVersion = 56; objects = {\n' + '\n'.join(objects) + f'\n}}; rootObject = {ident("project")}; }}\n')
schemes = project / "xcshareddata/xcschemes"
schemes.mkdir(parents=True, exist_ok=True)
reference = f'<BuildableReference BuildableIdentifier="primary" BlueprintIdentifier="{ident("target")}" BuildableName="Mediaserver.app" BlueprintName="Mediaserver" ReferencedContainer="container:Mediaserver.xcodeproj"/>'
(schemes / "Mediaserver.xcscheme").write_text(f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme LastUpgradeVersion="2600" version="1.3">
<BuildAction parallelizeBuildables="YES" buildImplicitDependencies="YES"><BuildActionEntries><BuildActionEntry buildForTesting="YES" buildForRunning="YES" buildForProfiling="YES" buildForArchiving="YES" buildForAnalyzing="YES">{reference}</BuildActionEntry></BuildActionEntries></BuildAction>
<LaunchAction buildConfiguration="Debug" selectedDebuggerIdentifier="Xcode.DebuggerFoundation.Debugger.LLDB" selectedLauncherIdentifier="Xcode.IDEFoundation.Launcher.LLDB" launchStyle="0" useCustomWorkingDirectory="NO" ignoresPersistentStateOnLaunch="NO" debugDocumentVersioning="YES" allowLocationSimulation="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></LaunchAction>
<ProfileAction buildConfiguration="Release" shouldUseLaunchSchemeArgsEnv="YES" savedToolIdentifier="" useCustomWorkingDirectory="NO" debugDocumentVersioning="YES"><BuildableProductRunnable runnableDebuggingMode="0">{reference}</BuildableProductRunnable></ProfileAction>
<AnalyzeAction buildConfiguration="Debug"/><ArchiveAction buildConfiguration="Release" revealArchiveInOrganizer="YES"/>
</Scheme>
''')
print(project)
