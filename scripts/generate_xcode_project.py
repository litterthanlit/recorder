#!/usr/bin/env python3
import os
import uuid

ROOT = "/Users/niki_g/Local Files/workflow/Projects/recorder"
OUT = os.path.join(ROOT, "Recorder.xcodeproj", "project.pbxproj")

def u():
    return uuid.uuid4().hex[:24].upper()

# IDs
PROJECT = u()
TARGET_APP = u()
TARGET_TEST = u()
PROJ_CFG_LIST = u()
APP_CFG_LIST = u()
TEST_CFG_LIST = u()
CFG_DBG = u()
CFG_REL = u()
TEST_CFG_DBG = u()
TEST_CFG_REL = u()
ROOT_GROUP = u()
REC_GROUP = u()
TEST_GROUP = u()
PRODUCTS = u()
SRC_APP = u()
SRC_TEST = u()
FW_APP = u()
FW_TEST = u()
RES = u()
PROD_APP = u()
PROD_TEST = u()
PROXY = u()
DEP = u()
TARGET_DEP = u()

groups = {
    "App": u(),
    "Capture": u(),
    "Zoom": u(),
    "Export": u(),
    "UI": u(),
    "Models": u(),
}

files = [
    ("Recorder/App/RecorderApp.swift", u(), u()),
    ("Recorder/App/PermissionsManager.swift", u(), u()),
    ("Recorder/App/NSScreen+DisplayID.swift", u(), u()),
    ("Recorder/Capture/ScreenRecorder.swift", u(), u()),
    ("Recorder/Capture/InputTracker.swift", u(), u()),
    ("Recorder/Capture/RecordingSession.swift", u(), u()),
    ("Recorder/Zoom/ClickEvent.swift", u(), u()),
    ("Recorder/Zoom/ZoomKeyframe.swift", u(), u()),
    ("Recorder/Zoom/AutoZoomGenerator.swift", u(), u()),
    ("Recorder/Zoom/ZoomInterpolator.swift", u(), u()),
    ("Recorder/Export/VideoExporter.swift", u(), u()),
    ("Recorder/Export/ZoomVideoCompositor.swift", u(), u()),
    ("Recorder/UI/MenuBarView.swift", u(), u()),
    ("Recorder/UI/PreviewView.swift", u(), u()),
    ("Recorder/Models/Project.swift", u(), u()),
]

ASSETS_REF = u()
ASSETS_BUILD = u()
INFO_REF = u()
ENT_REF = u()
TEST_REF = u()
TEST_BUILD = u()

lines = []
lines.append("// !$*UTF8*$!")
lines.append("{")
lines.append("\tarchiveVersion = 1;")
lines.append("\tclasses = {};")
lines.append("\tobjectVersion = 56;")
lines.append("\tobjects = {")

lines.append("\n/* Begin PBXBuildFile section */")
for path, ref, build in files:
    name = os.path.basename(path)
    lines.append(f"\t\t{build} /* {name} in Sources */ = {{isa = PBXBuildFile; fileRef = {ref} /* {name} */; }};")
lines.append(f"\t\t{TEST_BUILD} /* RecorderTests.swift in Sources */ = {{isa = PBXBuildFile; fileRef = {TEST_REF} /* RecorderTests.swift */; }};")
lines.append(f"\t\t{ASSETS_BUILD} /* Assets.xcassets in Resources */ = {{isa = PBXBuildFile; fileRef = {ASSETS_REF} /* Assets.xcassets */; }};")
lines.append("/* End PBXBuildFile section */")

lines.append("\n/* Begin PBXContainerItemProxy section */")
lines.append(f"\t\t{PROXY} /* PBXContainerItemProxy */ = {{")
lines.append("\t\t\tisa = PBXContainerItemProxy;")
lines.append(f"\t\t\tcontainerPortal = {PROJECT} /* Project object */;")
lines.append("\t\t\tproxyType = 1;")
lines.append(f"\t\t\tremoteGlobalIDString = {TARGET_APP};")
lines.append("\t\t\tremoteInfo = Recorder;")
lines.append("\t\t};")
lines.append("/* End PBXContainerItemProxy section */")

lines.append("\n/* Begin PBXFileReference section */")
for path, ref, build in files:
    name = os.path.basename(path)
    lines.append(f"\t\t{ref} /* {name} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = {name}; sourceTree = \"<group>\"; }};")
lines.append(f"\t\t{TEST_REF} /* RecorderTests.swift */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = RecorderTests.swift; sourceTree = \"<group>\"; }};")
lines.append(f"\t\t{ASSETS_REF} /* Assets.xcassets */ = {{isa = PBXFileReference; lastKnownFileType = folder.assetcatalog; path = Assets.xcassets; sourceTree = \"<group>\"; }};")
lines.append(f"\t\t{INFO_REF} /* Info.plist */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.xml; path = Info.plist; sourceTree = \"<group>\"; }};")
lines.append(f"\t\t{ENT_REF} /* Recorder.entitlements */ = {{isa = PBXFileReference; lastKnownFileType = text.plist.entitlements; path = Recorder.entitlements; sourceTree = \"<group>\"; }};")
lines.append(f"\t\t{PROD_APP} /* Recorder.app */ = {{isa = PBXFileReference; explicitFileType = wrapper.application; includeInIndex = 0; path = Recorder.app; sourceTree = BUILT_PRODUCTS_DIR; }};")
lines.append(f"\t\t{PROD_TEST} /* RecorderTests.xctest */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = RecorderTests.xctest; sourceTree = BUILT_PRODUCTS_DIR; }};")
lines.append("/* End PBXFileReference section */")

lines.append("\n/* Begin PBXFrameworksBuildPhase section */")
for phase in [FW_APP, FW_TEST]:
    lines.append(f"\t\t{phase} /* Frameworks */ = {{")
    lines.append("\t\t\tisa = PBXFrameworksBuildPhase;")
    lines.append("\t\t\tbuildActionMask = 2147483647;")
    lines.append("\t\t\tfiles = (")
    lines.append("\t\t\t);")
    lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
    lines.append("\t\t};")
lines.append("/* End PBXFrameworksBuildPhase section */")

lines.append("\n/* Begin PBXGroup section */")
lines.append(f"\t\t{ROOT_GROUP} = {{")
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")
lines.append(f"\t\t\t\t{REC_GROUP} /* Recorder */,")
lines.append(f"\t\t\t\t{TEST_GROUP} /* RecorderTests */,")
lines.append(f"\t\t\t\t{PRODUCTS} /* Products */,")
lines.append("\t\t\t);")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")

lines.append(f"\t\t{REC_GROUP} /* Recorder */ = {{")
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")
for gname, gid in groups.items():
    lines.append(f"\t\t\t\t{gid} /* {gname} */,")
lines.append(f"\t\t\t\t{ASSETS_REF} /* Assets.xcassets */,")
lines.append(f"\t\t\t\t{INFO_REF} /* Info.plist */,")
lines.append(f"\t\t\t\t{ENT_REF} /* Recorder.entitlements */,")
lines.append("\t\t\t);")
lines.append("\t\t\tpath = Recorder;")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")

group_map = {
    "App": [files[0], files[1], files[2]],
    "Capture": [files[3], files[4], files[5]],
    "Zoom": [files[6], files[7], files[8], files[9]],
    "Export": [files[10], files[11]],
    "UI": [files[12], files[13]],
    "Models": [files[14]],
}
for gname, gid in groups.items():
    lines.append(f"\t\t{gid} /* {gname} */ = {{")
    lines.append("\t\t\tisa = PBXGroup;")
    lines.append("\t\t\tchildren = (")
    for path, ref, build in group_map[gname]:
        lines.append(f"\t\t\t\t{ref} /* {os.path.basename(path)} */,")
    lines.append("\t\t\t);")
    lines.append(f"\t\t\tpath = {gname};")
    lines.append("\t\t\tsourceTree = \"<group>\";")
    lines.append("\t\t};")

lines.append(f"\t\t{TEST_GROUP} /* RecorderTests */ = {{")
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")
lines.append(f"\t\t\t\t{TEST_REF} /* RecorderTests.swift */,")
lines.append("\t\t\t);")
lines.append("\t\t\tpath = RecorderTests;")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")

lines.append(f"\t\t{PRODUCTS} /* Products */ = {{")
lines.append("\t\t\tisa = PBXGroup;")
lines.append("\t\t\tchildren = (")
lines.append(f"\t\t\t\t{PROD_APP} /* Recorder.app */,")
lines.append(f"\t\t\t\t{PROD_TEST} /* RecorderTests.xctest */,")
lines.append("\t\t\t);")
lines.append("\t\t\tname = Products;")
lines.append("\t\t\tsourceTree = \"<group>\";")
lines.append("\t\t};")
lines.append("/* End PBXGroup section */")

lines.append("\n/* Begin PBXNativeTarget section */")
lines.append(f"\t\t{TARGET_APP} /* Recorder */ = {{")
lines.append("\t\t\tisa = PBXNativeTarget;")
lines.append(f"\t\t\tbuildConfigurationList = {APP_CFG_LIST};")
lines.append("\t\t\tbuildPhases = (")
lines.append(f"\t\t\t\t{SRC_APP} /* Sources */,")
lines.append(f"\t\t\t\t{FW_APP} /* Frameworks */,")
lines.append(f"\t\t\t\t{RES} /* Resources */,")
lines.append("\t\t\t);")
lines.append("\t\t\tbuildRules = ();")
lines.append("\t\t\tdependencies = ();")
lines.append("\t\t\tname = Recorder;")
lines.append("\t\t\tproductName = Recorder;")
lines.append(f"\t\t\tproductReference = {PROD_APP};")
lines.append("\t\t\tproductType = \"com.apple.product-type.application\";")
lines.append("\t\t};")

lines.append(f"\t\t{TARGET_TEST} /* RecorderTests */ = {{")
lines.append("\t\t\tisa = PBXNativeTarget;")
lines.append(f"\t\t\tbuildConfigurationList = {TEST_CFG_LIST};")
lines.append("\t\t\tbuildPhases = (")
lines.append(f"\t\t\t\t{SRC_TEST} /* Sources */,")
lines.append(f"\t\t\t\t{FW_TEST} /* Frameworks */,")
lines.append("\t\t\t);")
lines.append("\t\t\tbuildRules = ();")
lines.append("\t\t\tdependencies = (")
lines.append(f"\t\t\t\t{DEP} /* PBXTargetDependency */,")
lines.append("\t\t\t);")
lines.append("\t\t\tname = RecorderTests;")
lines.append("\t\t\tproductName = RecorderTests;")
lines.append(f"\t\t\tproductReference = {PROD_TEST};")
lines.append("\t\t\tproductType = \"com.apple.product-type.bundle.unit-test\";")
lines.append("\t\t};")
lines.append("/* End PBXNativeTarget section */")

lines.append("\n/* Begin PBXProject section */")
lines.append(f"\t\t{PROJECT} /* Project object */ = {{")
lines.append("\t\t\tisa = PBXProject;")
lines.append("\t\t\tattributes = {")
lines.append("\t\t\t\tBuildIndependentTargetsInParallel = 1;")
lines.append("\t\t\t\tLastSwiftUpdateCheck = 1600;")
lines.append("\t\t\t\tLastUpgradeCheck = 1600;")
lines.append("\t\t\t\tTargetAttributes = {")
lines.append(f"\t\t\t\t\t{TARGET_APP} = {{ CreatedOnToolsVersion = 16.0; }};")
lines.append(f"\t\t\t\t\t{TARGET_TEST} = {{ CreatedOnToolsVersion = 16.0; TestTargetID = {TARGET_APP}; }};")
lines.append("\t\t\t\t};")
lines.append("\t\t\t};")
lines.append(f"\t\t\tbuildConfigurationList = {PROJ_CFG_LIST};")
lines.append("\t\t\tcompatibilityVersion = \"Xcode 14.0\";")
lines.append("\t\t\tdevelopmentRegion = en;")
lines.append("\t\t\thasScannedForEncodings = 0;")
lines.append("\t\t\tknownRegions = (en, Base);")
lines.append(f"\t\t\tmainGroup = {ROOT_GROUP};")
lines.append(f"\t\t\tproductRefGroup = {PRODUCTS};")
lines.append("\t\t\tprojectDirPath = \"\";")
lines.append("\t\t\tprojectRoot = \"\";")
lines.append("\t\t\ttargets = (")
lines.append(f"\t\t\t\t{TARGET_APP} /* Recorder */,")
lines.append(f"\t\t\t\t{TARGET_TEST} /* RecorderTests */,")
lines.append("\t\t\t);")
lines.append("\t\t};")
lines.append("/* End PBXProject section */")

lines.append("\n/* Begin PBXResourcesBuildPhase section */")
lines.append(f"\t\t{RES} /* Resources */ = {{")
lines.append("\t\t\tisa = PBXResourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
lines.append(f"\t\t\t\t{ASSETS_BUILD} /* Assets.xcassets in Resources */,")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXResourcesBuildPhase section */")

lines.append("\n/* Begin PBXSourcesBuildPhase section */")
lines.append(f"\t\t{SRC_APP} /* Sources */ = {{")
lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
for path, ref, build in files:
    lines.append(f"\t\t\t\t{build} /* {os.path.basename(path)} in Sources */,")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")

lines.append(f"\t\t{SRC_TEST} /* Sources */ = {{")
lines.append("\t\t\tisa = PBXSourcesBuildPhase;")
lines.append("\t\t\tbuildActionMask = 2147483647;")
lines.append("\t\t\tfiles = (")
lines.append(f"\t\t\t\t{TEST_BUILD} /* RecorderTests.swift in Sources */,")
lines.append("\t\t\t);")
lines.append("\t\t\trunOnlyForDeploymentPostprocessing = 0;")
lines.append("\t\t};")
lines.append("/* End PBXSourcesBuildPhase section */")

lines.append("\n/* Begin PBXTargetDependency section */")
lines.append(f"\t\t{DEP} /* PBXTargetDependency */ = {{")
lines.append("\t\t\tisa = PBXTargetDependency;")
lines.append(f"\t\t\ttarget = {TARGET_APP};")
lines.append(f"\t\t\ttargetProxy = {PROXY};")
lines.append("\t\t};")
lines.append("/* End PBXTargetDependency section */")

lines.append("\n/* Begin XCBuildConfiguration section */")
for cfg_id, name in [(CFG_DBG, "Debug"), (CFG_REL, "Release")]:
    lines.append(f"\t\t{cfg_id} /* {name} */ = {{")
    lines.append("\t\t\tisa = XCBuildConfiguration;")
    lines.append("\t\t\tbuildSettings = {")
    lines.append("\t\t\t\tALWAYS_SEARCH_USER_PATHS = NO;")
    lines.append("\t\t\t\tCLANG_ENABLE_MODULES = YES;")
    lines.append("\t\t\t\tCOPY_PHASE_STRIP = NO;")
    lines.append("\t\t\t\tDEBUG_INFORMATION_FORMAT = dwarf;")
    lines.append("\t\t\t\tENABLE_TESTABILITY = YES;" if name == "Debug" else "\t\t\t\tENABLE_NS_ASSERTIONS = NO;")
    lines.append("\t\t\t\tGCC_DYNAMIC_NO_PIC = NO;" if name == "Debug" else "\t\t\t\tGCC_OPTIMIZATION_LEVEL = s;")
    lines.append("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;")
    lines.append(f"\t\t\t\tMTL_ENABLE_DEBUG_INFO = {'INCLUDE_SOURCE' if name == 'Debug' else 'NO'};")
    if name == "Debug":
        lines.append('\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = "DEBUG";')
    else:
        lines.append("\t\t\t\tSWIFT_ACTIVE_COMPILATION_CONDITIONS = \"\";")
    lines.append("\t\t\t\tSWIFT_OPTIMIZATION_LEVEL = \"-Onone\";" if name == "Debug" else "\t\t\t\tSWIFT_COMPILATION_MODE = wholemodule;")
    lines.append("\t\t\t};")
    lines.append(f"\t\t\tname = {name};")
    lines.append("\t\t};")

lines.append(f"\t\t{TEST_CFG_DBG} /* Debug */ = {{")
lines.append("\t\t\tisa = XCBuildConfiguration;")
lines.append("\t\t\tbuildSettings = {")
lines.append("\t\t\t\tBUNDLE_LOADER = \"$(TEST_HOST)\";")
lines.append("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;")
lines.append("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;")
lines.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.recorder.appTests;")
lines.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
lines.append("\t\t\t\tTEST_HOST = \"$(BUILT_PRODUCTS_DIR)/Recorder.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Recorder\";")
lines.append("\t\t\t};")
lines.append("\t\t\tname = Debug;")
lines.append("\t\t};")

lines.append(f"\t\t{TEST_CFG_REL} /* Release */ = {{")
lines.append("\t\t\tisa = XCBuildConfiguration;")
lines.append("\t\t\tbuildSettings = {")
lines.append("\t\t\t\tBUNDLE_LOADER = \"$(TEST_HOST)\";")
lines.append("\t\t\t\tGENERATE_INFOPLIST_FILE = YES;")
lines.append("\t\t\t\tMACOSX_DEPLOYMENT_TARGET = 13.0;")
lines.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.recorder.appTests;")
lines.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
lines.append("\t\t\t\tTEST_HOST = \"$(BUILT_PRODUCTS_DIR)/Recorder.app/$(BUNDLE_EXECUTABLE_FOLDER_PATH)/Recorder\";")
lines.append("\t\t\t};")
lines.append("\t\t\tname = Release;")
lines.append("\t\t};")

APP_DBG = u()
APP_REL = u()

lines.append(f"\t\t{APP_DBG} /* Debug */ = {{")
lines.append("\t\t\tisa = XCBuildConfiguration;")
lines.append("\t\t\tbuildSettings = {")
lines.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
lines.append("\t\t\t\tCODE_SIGN_ENTITLEMENTS = Recorder/Recorder.entitlements;")
lines.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
lines.append("\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;")
lines.append("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
lines.append("\t\t\t\tDEVELOPMENT_TEAM = \"\";")
lines.append("\t\t\t\tENABLE_HARDENED_RUNTIME = YES;")
lines.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
lines.append("\t\t\t\tINFOPLIST_FILE = Recorder/Info.plist;")
lines.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/../Frameworks\");")
lines.append("\t\t\t\tMARKETING_VERSION = 1.0;")
lines.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.recorder.app;")
lines.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
lines.append("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
lines.append("\t\t\t};")
lines.append("\t\t\tname = Debug;")
lines.append("\t\t};")

lines.append(f"\t\t{APP_REL} /* Release */ = {{")
lines.append("\t\t\tisa = XCBuildConfiguration;")
lines.append("\t\t\tbuildSettings = {")
lines.append("\t\t\t\tASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
lines.append("\t\t\t\tCODE_SIGN_ENTITLEMENTS = Recorder/Recorder.entitlements;")
lines.append("\t\t\t\tCODE_SIGN_STYLE = Automatic;")
lines.append("\t\t\t\tCOMBINE_HIDPI_IMAGES = YES;")
lines.append("\t\t\t\tCURRENT_PROJECT_VERSION = 1;")
lines.append("\t\t\t\tDEVELOPMENT_TEAM = \"\";")
lines.append("\t\t\t\tENABLE_HARDENED_RUNTIME = YES;")
lines.append("\t\t\t\tGENERATE_INFOPLIST_FILE = NO;")
lines.append("\t\t\t\tINFOPLIST_FILE = Recorder/Info.plist;")
lines.append("\t\t\t\tLD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/../Frameworks\");")
lines.append("\t\t\t\tMARKETING_VERSION = 1.0;")
lines.append("\t\t\t\tPRODUCT_BUNDLE_IDENTIFIER = com.recorder.app;")
lines.append("\t\t\t\tPRODUCT_NAME = \"$(TARGET_NAME)\";")
lines.append("\t\t\t\tSWIFT_EMIT_LOC_STRINGS = YES;")
lines.append("\t\t\t\tSWIFT_VERSION = 5.0;")
lines.append("\t\t\t};")
lines.append("\t\t\tname = Release;")
lines.append("\t\t};")
lines.append("/* End XCBuildConfiguration section */")

lines.append("\n/* Begin XCConfigurationList section */")
for list_id, cfgs in [
    (PROJ_CFG_LIST, [(CFG_DBG, "Debug"), (CFG_REL, "Release")]),
    (APP_CFG_LIST, [(APP_DBG, "Debug"), (APP_REL, "Release")]),
    (TEST_CFG_LIST, [(TEST_CFG_DBG, "Debug"), (TEST_CFG_REL, "Release")]),
]:
    lines.append(f"\t\t{list_id} /* Build configuration list */ = {{")
    lines.append("\t\t\tisa = XCConfigurationList;")
    lines.append("\t\t\tbuildConfigurations = (")
    for cid, cname in cfgs:
        lines.append(f"\t\t\t\t{cid} /* {cname} */,")
    lines.append("\t\t\t);")
    lines.append("\t\t\tdefaultConfigurationIsVisible = 0;")
    lines.append("\t\t\tdefaultConfigurationName = Release;")
    lines.append("\t\t};")
lines.append("/* End XCConfigurationList section */")

lines.append("\t};")
lines.append(f"\trootObject = {PROJECT} /* Project object */;")
lines.append("}")

os.makedirs(os.path.dirname(OUT), exist_ok=True)
with open(OUT, "w") as f:
    f.write("\n".join(lines) + "\n")
print(f"Wrote {OUT}")
