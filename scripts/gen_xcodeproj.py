#!/usr/bin/env python3
from pathlib import Path
import uuid

root = Path(__file__).resolve().parents[1]


def uid() -> str:
    return uuid.uuid4().hex[:24].upper()


ids = {k: uid() for k in [
    "project", "appTarget", "appConfigList", "projectConfigList",
    "appDebug", "appRelease", "projectDebug", "projectRelease",
    "appSources", "appResources", "appFrameworks",
    "appGroup", "productsGroup", "frameworksGroup", "appProduct",
    "assets", "privacy", "appEnt", "appPlist",
    "themeGroup", "sessionGroup", "uiGroup", "chatGroup", "audioGroup", "webGroup",
]}

app_files = [
    ("ZCodeMobileApp.swift", "App/ZCodeMobileApp.swift"),
    ("Theme.swift", "App/Theme/Theme.swift"),
    ("Models.swift", "App/Session/Models.swift"),
    ("AppSettings.swift", "App/Session/AppSettings.swift"),
    ("AppState.swift", "App/Session/AppState.swift"),
    ("OfficialLink.swift", "App/Session/OfficialLink.swift"),
    ("OfficialRelay.swift", "App/Session/OfficialRelay.swift"),
    ("VSCodeIPC.swift", "App/Session/VSCodeIPC.swift"),
    ("RpcFrame.swift", "App/Session/RpcFrame.swift"),
    ("NotificationCenter.swift", "App/Session/NotificationCenter.swift"),
    ("RootView.swift", "App/UI/RootView.swift"),
    ("ReviewPanel.swift", "App/UI/ReviewPanel.swift"),
    ("MarkdownRenderer.swift", "App/Chat/MarkdownRenderer.swift"),
    ("ComposerView.swift", "App/Chat/ComposerView.swift"),
    ("InsertWebView.swift", "App/Chat/InsertWebView.swift"),
    ("ChatViewController.swift", "App/Chat/ChatViewController.swift"),
    ("QRScannerViewController.swift", "App/Chat/QRScannerViewController.swift"),
    ("SilentAudio.swift", "App/Audio/SilentAudio.swift"),
]

file_ids = {path: uid() for _, path in app_files}
build_ids = {path: uid() for _, path in app_files}
assets_id = ids["assets"]
privacy_id = ids["privacy"]
assets_build = uid()
privacy_build = uid()
proj_id = uid()

fw = {
    "UIKit": uid(),
    "SwiftUI": uid(),
    "UserNotifications": uid(),
    "AVFoundation": uid(),
    "Vision": uid(),
    "PhotosUI": uid(),
    "CryptoKit": uid(),
    "WebKit": uid(),
}
fw_build = {k: uid() for k in fw}

P = []


def add(s: str = "") -> None:
    P.append(s)


add("// !$*UTF8*$!")
add("{")
add("\tarchiveVersion = 1;")
add("\tclasses = {")
add("\t};")
add("\tobjectVersion = 56;")
add("\tobjects = {")
add("")
add("/* Begin PBXBuildFile section */")
for name, path in app_files:
    add(f"\t\t{build_ids[path]} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {file_ids[path]} /* {name} */; }};")
add(f"\t\t{assets_build} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {assets_id} /* Assets.xcassets */; }};")
add(f"\t\t{privacy_build} /* PrivacyInfo.xcprivacy in Resources */ = {{isa = PBXBuildFile; fileRef = {privacy_id} /* PrivacyInfo.xcprivacy */; }};")
for k, fid in fw.items():
    add(f"\t\t{fw_build[k]} /* {k}.framework in Frameworks */ = {{isa = PBXBuildFile; fileRef = {fid} /* {k}.framework */; }};")
add("/* End PBXBuildFile section */")
add("")
add("/* Begin PBXFileReference section */")
add(f"\t\t{ids['appProduct']} /* ZCode.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = ZCode.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
add(f'\t\t{assets_id} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = "<group>"; }};')
add(f'\t\t{privacy_id} /* PrivacyInfo.xcprivacy */ = {{isa = PBXFileReference; lastKnownFileType = text.xml; path = PrivacyInfo.xcprivacy; sourceTree = "<group>"; }};')
add(f'\t\t{ids["appEnt"]} /* ZCodeMobile.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = ZCodeMobile.entitlements; sourceTree = "<group>"; }};')
add(f'\t\t{ids["appPlist"]} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = "<group>"; }};')
for name, path in app_files:
    add(f'\t\t{file_ids[path]} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = "<group>"; }};')
for k, fid in fw.items():
    add(f"\t\t{fid} /* {k}.framework */ = {{isa = PBXFileReference; lastKnownFileType = wrapper.framework; name = {k}.framework; path = System/Library/Frameworks/{k}.framework; sourceTree = SDKROOT; }};")
add("/* End PBXFileReference section */")
add("")
add("/* Begin PBXFrameworksBuildPhase section */")
add(f"\t\t{ids['appFrameworks']} /* Frameworks */ = {{")
add("\t\t\tisa = PBXFrameworksBuildPhase;")
add("\t\t\tbuildActionMask = 2147483647;")
add("\t\t\tfiles = (")
for k in fw:
    add(f"\t\t\t\t{fw_build[k]} /* {k}.framework in Frameworks */,")
add("\t\t\t);")
add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
add("\t\t};")
add("/* End PBXFrameworksBuildPhase section */")
add("")
add("/* Begin PBXGroup section */")
add(f"\t\t{ids['project']} = {{")
add("\t\t\tisa = PBXGroup;")
add("\t\t\tchildren = (")
add(f"\t\t\t\t{ids['appGroup']} /* App */,")
add(f"\t\t\t\t{ids['frameworksGroup']} /* Frameworks */,")
add(f"\t\t\t\t{ids['productsGroup']} /* Products */,")
add("\t\t\t);")
add('\t\t\tsourceTree = "<group>";')
add("\t\t};")
add(f"\t\t{ids['appGroup']} /* App */ = {{")
add("\t\t\tisa = PBXGroup;")
add("\t\t\tchildren = (")
add(f"\t\t\t\t{file_ids['App/ZCodeMobileApp.swift']} /* ZCodeMobileApp.swift */,")
add(f"\t\t\t\t{ids['themeGroup']} /* Theme */,")
add(f"\t\t\t\t{ids['sessionGroup']} /* Session */,")
add(f"\t\t\t\t{ids['uiGroup']} /* UI */,")
add(f"\t\t\t\t{ids['chatGroup']} /* Chat */,")
add(f"\t\t\t\t{ids['audioGroup']} /* Audio */,")
add(f"\t\t\t\t{ids['webGroup']} /* Web */,")
add(f"\t\t\t\t{assets_id} /* Assets.xcassets */,")
add(f"\t\t\t\t{privacy_id} /* PrivacyInfo.xcprivacy */,")
add(f"\t\t\t\t{ids['appEnt']} /* ZCodeMobile.entitlements */,")
add(f"\t\t\t\t{ids['appPlist']} /* Info.plist */,")
add("\t\t\t);")
add("\t\t\tpath = App;")
add('\t\t\tsourceTree = "<group>";')
add("\t\t};")


def subgroup(gid: str, title: str, prefix: str) -> None:
    add(f"\t\t{gid} /* {title} */ = {{")
    add("\t\t\tisa = PBXGroup;")
    add("\t\t\tchildren = (")
    for name, path in app_files:
        if path.startswith(prefix):
            add(f"\t\t\t\t{file_ids[path]} /* {name} */,")
    add("\t\t\t);")
    add(f"\t\t\tpath = {title};")
    add('\t\t\tsourceTree = "<group>";')
    add("\t\t};")


subgroup(ids["themeGroup"], "Theme", "App/Theme/")
subgroup(ids["sessionGroup"], "Session", "App/Session/")
subgroup(ids["uiGroup"], "UI", "App/UI/")
subgroup(ids["chatGroup"], "Chat", "App/Chat/")
subgroup(ids["audioGroup"], "Audio", "App/Audio/")

add(f"\t\t{ids['productsGroup']} /* Products */ = {{")
add("\t\t\tisa = PBXGroup;")
add("\t\t\tchildren = (")
add(f"\t\t\t\t{ids['appProduct']} /* ZCode.app */,")
add("\t\t\t);")
add("\t\t\tname = Products;")
add('\t\t\tsourceTree = "<group>";')
add("\t\t};")
add(f"\t\t{ids['frameworksGroup']} /* Frameworks */ = {{")
add("\t\t\tisa = PBXGroup;")
add("\t\t\tchildren = (")
for k, fid in fw.items():
    add(f"\t\t\t\t{fid} /* {k}.framework */,")
add("\t\t\t);")
add("\t\t\tname = Frameworks;")
add('\t\t\tsourceTree = "<group>";')
add("\t\t};")
add("/* End PBXGroup section */")
add("")
add("/* Begin PBXNativeTarget section */")
add(f"\t\t{ids['appTarget']} /* ZCode */ = {{")
add("\t\t\tisa = PBXNativeTarget;")
add(f'\t\t\tbuildConfigurationList = {ids["appConfigList"]} /* Build configuration list for PBXNativeTarget "ZCode" */;')
add("\t\t\tbuildPhases = (")
add(f"\t\t\t\t{ids['appSources']} /* Sources */,")
add(f"\t\t\t\t{ids['appFrameworks']} /* Frameworks */,")
add(f"\t\t\t\t{ids['appResources']} /* Resources */,")
add("\t\t\t);")
add("\t\t\tbuildRules = (")
add("\t\t\t);")
add("\t\t\tdependencies = (")
add("\t\t\t);")
add("\t\t\tname = ZCode;")
add("\t\t\tproductName = ZCode;")
add(f"\t\t\tproductReference = {ids['appProduct']} /* ZCode.app */;")
add('\t\t\tproductType = "com.apple.product-type.application";')
add("\t\t};")
add("/* End PBXNativeTarget section */")
add("")
add("/* Begin PBXProject section */")
add(f"\t\t{proj_id} /* Project object */ = {{")
add("\t\t\tisa = PBXProject;")
add("\t\t\tattributes = {")
add("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
add("\t\t\t\tLastSwiftUpdateCheck = 1600;")
add("\t\t\t\tLastUpgradeCheck = 1600;")
add("\t\t\t\tTargetAttributes = {")
add(f"\t\t\t\t\t{ids['appTarget']} = {{")
add("\t\t\t\t\t\tCreatedOnToolsVersion = 16.0;")
add("\t\t\t\t\t};")
add("\t\t\t\t};")
add("\t\t\t};")
add(f'\t\t\tbuildConfigurationList = {ids["projectConfigList"]} /* Build configuration list for PBXProject "ZCodeMobile" */;')
add('\t\t\tcompatibilityVersion = "Xcode 14.0";')
add('\t\t\tdevelopmentRegion = "zh-Hans";')
add("\t\t\thasScannedForEncodings = 0;")
add("\t\t\tknownRegions = (")
add("\t\t\t\ten,")
add("\t\t\t\tBase,")
add('\t\t\t\t"zh-Hans",')
add("\t\t\t);")
add(f"\t\t\tmainGroup = {ids['project']};")
add(f"\t\t\tproductRefGroup = {ids['productsGroup']} /* Products */;")
add('\t\t\tprojectDirPath = "";')
add('\t\t\tprojectRoot = "";')
add("\t\t\ttargets = (")
add(f"\t\t\t\t{ids['appTarget']} /* ZCode */,")
add("\t\t\t);")
add("\t\t};")
add("/* End PBXProject section */")
add("")
add("/* Begin PBXResourcesBuildPhase section */")
add(f"\t\t{ids['appResources']} /* Resources */ = {{")
add("\t\t\tisa = PBXResourcesBuildPhase;")
add("\t\t\tbuildActionMask = 2147483647;")
add("\t\t\tfiles = (")
add(f"\t\t\t\t{assets_build} /* Assets.xcassets in Resources */,")
add(f"\t\t\t\t{privacy_build} /* PrivacyInfo.xcprivacy in Resources */,")
add("\t\t\t);")
add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
add("\t\t};")
add("/* End PBXResourcesBuildPhase section */")
add("")
add("/* Begin PBXSourcesBuildPhase section */")
add(f"\t\t{ids['appSources']} /* Sources */ = {{")
add("\t\t\tisa = PBXSourcesBuildPhase;")
add("\t\t\tbuildActionMask = 2147483647;")
add("\t\t\tfiles = (")
for name, path in app_files:
    add(f"\t\t\t\t{build_ids[path]} /* {name} in Sources */,")
add("\t\t\t);")
add("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
add("\t\t};")
add("/* End PBXSourcesBuildPhase section */")
add("")


def xcconfig(cid: str, name: str, extra) -> None:
    add(f"\t\t{cid} /* {name} */ = {{")
    add("\t\t\tisa = XCBuildConfiguration;")
    add("\t\t\tbuildSettings = {")
    for k, v in extra:
        add(f"\t\t\t\t{k} = {v};")
    add("\t\t\t};")
    add(f"\t\t\tname = {name};")
    add("\t\t};")


add("/* Begin XCBuildConfiguration section */")
common_proj = [
    ("ALWAYS_SEARCH_USER_PATHS", "NO"),
    ("CLANG_ENABLE_MODULES", "YES"),
    ("CLANG_ENABLE_OBJC_ARC", "YES"),
    ("COPY_PHASE_STRIP", "NO"),
    ("ENABLE_STRICT_OBJC_MSGSEND", "YES"),
    ("GCC_NO_COMMON_BLOCKS", "YES"),
    ("IPHONEOS_DEPLOYMENT_TARGET", "16.0"),
    ("SDKROOT", "iphoneos"),
    ("SWIFT_VERSION", "5.0"),
]
xcconfig(ids["projectDebug"], "Debug", common_proj + [
    ("DEBUG_INFORMATION_FORMAT", "dwarf"),
    ("ENABLE_TESTABILITY", "YES"),
    ("GCC_DYNAMIC_NO_PIC", "NO"),
    ("GCC_OPTIMIZATION_LEVEL", "0"),
    ("MTL_ENABLE_DEBUG_INFO", "INCLUDE_SOURCE"),
    ("ONLY_ACTIVE_ARCH", "YES"),
    ("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "DEBUG"),
    ("SWIFT_OPTIMIZATION_LEVEL", '"-Onone"'),
])
xcconfig(ids["projectRelease"], "Release", common_proj + [
    ("DEBUG_INFORMATION_FORMAT", '"dwarf-with-dsym"'),
    ("ENABLE_NS_ASSERTIONS", "NO"),
    ("MTL_ENABLE_DEBUG_INFO", "NO"),
    ("SWIFT_COMPILATION_MODE", "wholemodule"),
    ("SWIFT_OPTIMIZATION_LEVEL", '"-O"'),
    ("VALIDATE_PRODUCT", "YES"),
])
app_settings = [
    ("ASSETCATALOG_COMPILER_APPICON_NAME", "AppIcon"),
    ("ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "AccentColor"),
    ("CODE_SIGN_ENTITLEMENTS", "App/ZCodeMobile.entitlements"),
    ("CODE_SIGNING_ALLOWED", "NO"),
    ("CODE_SIGNING_REQUIRED", "NO"),
    ("CODE_SIGN_IDENTITY", '""'),
    ("CODE_SIGN_STYLE", "Manual"),
    ("CURRENT_PROJECT_VERSION", "1"),
    ("DEVELOPMENT_TEAM", '""'),
    ("GENERATE_INFOPLIST_FILE", "NO"),
    ("INFOPLIST_FILE", "App/Info.plist"),
    ("LD_RUNPATH_SEARCH_PATHS", '"$(inherited) @executable_path/Frameworks"'),
    ("MARKETING_VERSION", "1.0.0"),
    ("PRODUCT_BUNDLE_IDENTIFIER", "dev.zcode.mobile"),
    ("PRODUCT_NAME", "ZCode"),
    ("SUPPORTS_MACCATALYST", "NO"),
    ("SWIFT_EMIT_LOC_STRINGS", "YES"),
    ("TARGETED_DEVICE_FAMILY", '"1,2"'),
]
xcconfig(ids["appDebug"], "Debug", app_settings)
xcconfig(ids["appRelease"], "Release", app_settings)
add("/* End XCBuildConfiguration section */")
add("")
add("/* Begin XCConfigurationList section */")


def clist(cid: str, title: str, debug: str, release: str) -> None:
    add(f"\t\t{cid} /* Build configuration list for {title} */ = {{")
    add("\t\t\tisa = XCConfigurationList;")
    add("\t\t\tbuildConfigurations = (")
    add(f"\t\t\t\t{debug} /* Debug */,")
    add(f"\t\t\t\t{release} /* Release */,")
    add("\t\t\t);")
    add("\t\t\tdefaultConfigurationIsVisible = 0;")
    add("\t\t\tdefaultConfigurationName = Release;")
    add("\t\t};")


clist(ids["projectConfigList"], 'PBXProject "ZCodeMobile"', ids["projectDebug"], ids["projectRelease"])
clist(ids["appConfigList"], 'PBXNativeTarget "ZCode"', ids["appDebug"], ids["appRelease"])
add("/* End XCConfigurationList section */")
add("\t};")
add(f"\trootObject = {proj_id} /* Project object */;")
add("}")

out = root / "ZCodeMobile.xcodeproj" / "project.pbxproj"
out.parent.mkdir(parents=True, exist_ok=True)
out.write_text("\n".join(P) + "\n", encoding="utf-8")
print("wrote", out, "lines", len(P))

scheme_dir = root / "ZCodeMobile.xcodeproj" / "xcshareddata" / "xcschemes"
scheme_dir.mkdir(parents=True, exist_ok=True)
scheme = f'''<?xml version="1.0" encoding="UTF-8"?>
<Scheme
   LastUpgradeVersion = "1600"
   version = "1.7">
   <BuildAction
      parallelizeBuildables = "YES"
      buildImplicitDependencies = "YES">
      <BuildActionEntries>
         <BuildActionEntry
            buildForTesting = "YES"
            buildForRunning = "YES"
            buildForProfiling = "YES"
            buildForArchiving = "YES"
            buildForAnalyzing = "YES">
            <BuildableReference
               BuildableIdentifier = "primary"
               BlueprintIdentifier = "{ids['appTarget']}"
               BuildableName = "ZCode.app"
               BlueprintName = "ZCode"
               ReferencedContainer = "container:ZCodeMobile.xcodeproj">
            </BuildableReference>
         </BuildActionEntry>
      </BuildActionEntries>
   </BuildAction>
   <TestAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      shouldUseLaunchSchemeArgsEnv = "YES"
      shouldAutocreateTestPlan = "YES">
   </TestAction>
   <LaunchAction
      buildConfiguration = "Debug"
      selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
      selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
      launchStyle = "0"
      useCustomWorkingDirectory = "NO"
      ignoresPersistentStateOnLaunch = "NO"
      debugDocumentVersioning = "YES"
      debugServiceExtension = "internal"
      allowLocationSimulation = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{ids['appTarget']}"
            BuildableName = "ZCode.app"
            BlueprintName = "ZCode"
            ReferencedContainer = "container:ZCodeMobile.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </LaunchAction>
   <ProfileAction
      buildConfiguration = "Release"
      shouldUseLaunchSchemeArgsEnv = "YES"
      savedToolIdentifier = ""
      useCustomWorkingDirectory = "NO"
      debugDocumentVersioning = "YES">
      <BuildableProductRunnable
         runnableDebuggingMode = "0">
         <BuildableReference
            BuildableIdentifier = "primary"
            BlueprintIdentifier = "{ids['appTarget']}"
            BuildableName = "ZCode.app"
            BlueprintName = "ZCode"
            ReferencedContainer = "container:ZCodeMobile.xcodeproj">
         </BuildableReference>
      </BuildableProductRunnable>
   </ProfileAction>
   <AnalyzeAction
      buildConfiguration = "Debug">
   </AnalyzeAction>
   <ArchiveAction
      buildConfiguration = "Release"
      revealArchiveInOrganizer = "YES">
   </ArchiveAction>
</Scheme>
'''
scheme_path = scheme_dir / "ZCode.xcscheme"
scheme_path.write_text(scheme, encoding="utf-8")
print("wrote", scheme_path)
