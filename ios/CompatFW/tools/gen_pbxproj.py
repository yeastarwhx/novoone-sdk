#!/usr/bin/env python3
"""生成 CompatFW.xcodeproj/project.pbxproj(源文件自动发现).

Sources/ 下 *.swift/*.mm/*.cpp 自动纳编——加文件无需维护工程。
UUID 由相对路径哈希生成,稳定可再生。
"""
import hashlib
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent   # CompatFW/
SOURCES = ROOT / "Sources"

# 对 Swift 暴露的 ObjC 头(Headers build phase,Public):构成 Swift 隐式
# 导入的 underlying module——Facade/*.swift 引用引擎类型的唯一通路。
# 只放干净头(Foundation 依赖);ys_pjsua_app.h 等引 C/pjlib 链的头不暴露。
SWIFT_VISIBLE_HEADERS = [
    "SipCore/SipWebrtcEngine.h",
    "SipCore/SipCallSession.h",
    "SipCore/SipCoreLogger.h",
    "SipCore/SipEngineCallback.h",
    "SipCore/CompatUmbrella.h",
]


def uid(rel: str, salt: str = "") -> str:
    h = hashlib.md5((salt + rel).encode()).hexdigest()[:24].upper()
    return h


def main() -> None:
    src_files = sorted(
        str(p.relative_to(SOURCES))
        for p in SOURCES.rglob("*")
        if p.suffix in (".swift", ".mm", ".cpp")
    )
    if not src_files:
        raise SystemExit("no sources under " + str(SOURCES))

    header_files = [h for h in SWIFT_VISIBLE_HEADERS if (SOURCES / h).is_file()]
    missing = [h for h in SWIFT_VISIBLE_HEADERS if h not in header_files]
    if missing:
        raise SystemExit("missing Swift-visible headers: " + ", ".join(missing))

    file_refs, build_files, group_children = [], [], {}
    for rel in src_files:
        fr, bf = uid(rel, "FR"), uid(rel, "BF")
        kind = {
            ".swift": "sourcecode.swift",
            ".mm": "sourcecode.cpp.objcpp",
            ".cpp": "sourcecode.cpp.cpp",
        }[pathlib.Path(rel).suffix]
        file_refs.append(
            f'\t\t{fr} /* {rel} */ = {{isa = PBXFileReference; lastKnownFileType = {kind}; '
            f'path = {pathlib.Path(rel).name}; sourceTree = "<group>"; }};'
        )
        build_files.append(
            f"\t\t{bf} /* {rel} in Sources */ = {{isa = PBXBuildFile; fileRef = {fr} /* {rel} */; }};"
        )
        group_children.setdefault(str(pathlib.Path(rel).parent), []).append((fr, rel))

    for rel in header_files:
        fr, bf = uid(rel, "HFR"), uid(rel, "HBF")
        file_refs.append(
            f'\t\t{fr} /* {rel} */ = {{isa = PBXFileReference; lastKnownFileType = sourcecode.c.h; '
            f'path = {pathlib.Path(rel).name}; sourceTree = "<group>"; }};'
        )
        build_files.append(
            f"\t\t{bf} /* {rel} in Headers */ = {{isa = PBXBuildFile; fileRef = {fr} /* {rel} */; "
            f'settings = {{ATTRIBUTES = (Public, ); }}; }};'
        )
        group_children.setdefault(str(pathlib.Path(rel).parent), []).append((fr, rel))

    def group(name: str, path: str, children: str) -> str:
        gid = uid(name, "GR")
        return (
            f'\t\t{gid} /* {name} */ = {{\n\t\t\tisa = PBXGroup;\n'
            f"\t\t\tchildren = (\n{children}\t\t\t);\n"
            f'\t\t\tpath = {path};\n\t\t\tsourceTree = "<group>";\n\t\t}};'
        )

    # 嵌套目录组(SipCore/ 等)扁平化为二级组
    sub_groups = []
    for gpath in sorted(k for k in group_children if k != "."):
        inner = "".join(
            f"\t\t\t\t{fr} /* {rel} */,\n" for fr, rel in group_children[gpath]
        )
        sub_groups.append(group(gpath, gpath, inner))

    top_children = "".join(
        f"\t\t\t\t{fr} /* {rel} */,\n" for fr, rel in group_children.get(".", [])
    )
    src_group = (
        f"\t\t{uid('Sources', 'GR')} /* Sources */ = {{\n\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n{top_children}"
        + "".join(f"\t\t\t\t{uid(g, 'GR')} /* {g} */,\n" for g in sorted(
            k for k in group_children if k != "."))
        + "\t\t\t);\n\t\t\tpath = Sources;\n\t\t\tsourceTree = \"<group>\";\n\t\t};"
    )
    main_group = (
        f"\t\t{uid('MAIN', 'GR')} = {{\n\t\t\tisa = PBXGroup;\n\t\t\tchildren = (\n"
        f"\t\t\t\t{uid('Sources', 'GR')} /* Sources */,\n"
        f"\t\t\t\t{uid('Products', 'GR')} /* Products */,\n"
        "\t\t\t);\n\t\t\tsourceTree = \"<group>\";\n\t\t};"
    )
    products_group = (
        f"\t\t{uid('Products', 'GR')} /* Products */ = {{\n\t\t\tisa = PBXGroup;\n"
        f"\t\t\tchildren = (\n\t\t\t\t{uid('APPFW', 'FR')} /* Softphone_Swift.framework */,\n"
        "\t\t\t);\n\t\t\tname = Products;\n\t\t\tsourceTree = \"<group>\";\n\t\t};"
    )
    sources_files = "".join(
        f"\t\t\t\t{uid(rel, 'BF')} /* {rel} in Sources */,\n" for rel in src_files
    )
    headers_files = "".join(
        f"\t\t\t\t{uid(rel, 'HBF')} /* {rel} in Headers */,\n" for rel in header_files
    )

    proj = f"""// !$*UTF8*$!
{{
	archiveVersion = 1;
	objectVersion = 56;
	classes = {{
	}};
	objects = {{

/* Begin PBXBuildFile section */
{chr(10).join(build_files)}
/* End PBXBuildFile section */

/* Begin PBXFileReference section */
		{uid('APPFW', 'FR')} /* Softphone_Swift.framework */ = {{isa = PBXFileReference; explicitFileType = wrapper.cfbundle; includeInIndex = 0; path = Softphone_Swift.framework; sourceTree = BUILT_PRODUCTS_DIR; }};
{chr(10).join(file_refs)}
/* End PBXFileReference section */

/* Begin PBXFrameworksBuildPhase section */
		{uid('FWPHASE', 'PH')} /* Frameworks */ = {{
			isa = PBXFrameworksBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXFrameworksBuildPhase section */

/* Begin PBXHeadersBuildPhase section */
			{uid('HDRPHASE', 'PH')} /* Headers */ = {{
				isa = PBXHeadersBuildPhase;
				buildActionMask = 2147483647;
				files = (
{headers_files}\t\t\t);
				runOnlyForDeploymentPostprocessing = 0;
			}};
/* End PBXHeadersBuildPhase section */

/* Begin PBXGroup section */
{main_group}
{products_group}
{src_group}
{chr(10).join(sub_groups)}
/* End PBXGroup section */

/* Begin PBXNativeTarget section */
		{uid('TARGET', 'NT')} /* Softphone_Swift */ = {{
			isa = PBXNativeTarget;
			buildConfigurationList = {uid('TARGET-CL', 'CL')};
			buildPhases = (
				{uid('HDRPHASE', 'PH')} /* Headers */,
				{uid('SRCPHASE', 'PH')} /* Sources */,
				{uid('FWPHASE', 'PH')} /* Frameworks */,
				{uid('RES PHASE', 'PH').replace(' ', '')} /* Resources */,
			);
			buildRules = (
			);
			dependencies = (
			);
			name = Softphone_Swift;
			productName = Softphone_Swift;
			productReference = {uid('APPFW', 'FR')} /* Softphone_Swift.framework */;
			productType = "com.apple.product-type.framework";
		}};
/* End PBXNativeTarget section */

/* Begin PBXProject section */
		{uid('PROJECT', 'PJ')} /* Project object */ = {{
			isa = PBXProject;
			attributes = {{
				BuildIndependentTargetsInParallel = 1;
			}};
			buildConfigurationList = {uid('PROJECT-CL', 'CL')};
			compatibilityVersion = "Xcode 14.0";
			developmentRegion = en;
			hasScannedForEncodings = 0;
			knownRegions = (
				en,
				Base,
			);
			mainGroup = {uid('MAIN', 'GR')};
			productRefGroup = {uid('Products', 'GR')} /* Products */;
			projectDirPath = "";
			projectRoot = "";
			targets = (
				{uid('TARGET', 'NT')} /* Softphone_Swift */,
			);
		}};
/* End PBXProject section */

/* Begin PBXResourcesBuildPhase section */
		{uid('RESPHASE', 'PH')} /* Resources */ = {{
			isa = PBXResourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
			);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXResourcesBuildPhase section */

/* Begin PBXSourcesBuildPhase section */
		{uid('SRCPHASE', 'PH')} /* Sources */ = {{
			isa = PBXSourcesBuildPhase;
			buildActionMask = 2147483647;
			files = (
{sources_files}\t\t\t);
			runOnlyForDeploymentPostprocessing = 0;
		}};
/* End PBXSourcesBuildPhase section */

/* Begin XCBuildConfiguration section */
		{uid('PROJECT-Debug', 'BC')} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CODE_SIGNING_ALLOWED = NO;
				CURRENT_PROJECT_VERSION = 1;
				IPHONEOS_DEPLOYMENT_TARGET = 15.0;
				MARKETING_VERSION = 1.0;
				SWIFT_OPTIMIZATION_LEVEL = "-Onone";
				SWIFT_VERSION = 5.0;
			}};
			name = Debug;
		}};
		{uid('PROJECT-Release', 'BC')} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				ALWAYS_SEARCH_USER_PATHS = NO;
				CODE_SIGNING_ALLOWED = NO;
				CURRENT_PROJECT_VERSION = 1;
				IPHONEOS_DEPLOYMENT_TARGET = 15.0;
				MARKETING_VERSION = 1.0;
				SWIFT_OPTIMIZATION_LEVEL = "-O";
				SWIFT_VERSION = 5.0;
			}};
			name = Release;
		}};
		{uid('TARGET-Debug', 'BC')} /* Debug */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				DEFINES_MODULE = YES;
				MODULEMAP_FILE = \"$(SRCROOT)/Sources/SipCore/Softphone_Swift.modulemap\";
				GCC_PREPROCESSOR_DEFINITIONS = (
					"$(inherited)",
					"PJ_AUTOCONF=1",
					"PJ_ENABLE_WEBRTC_INTEGRATION=1",
				);
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				FRAMEWORK_SEARCH_PATHS = (
					"$(inherited)",
					"$(SRCROOT)/Vendor",
					"$(SRCROOT)/Vendor/WebRTC.xcframework/ios-arm64",
				);
				GENERATE_INFOPLIST_FILE = YES;
				HEADER_SEARCH_PATHS = (
					"$(inherited)",
					"$(SRCROOT)/Sources/SipCore",
					"$(SRCROOT)/Vendor/pjsip-include",
				);
				OTHER_LDFLAGS = (
					"$(inherited)",
					"$(SRCROOT)/Vendor/libpjsip-combined.a",
					"-framework",
					WebRTC,
					"-framework",
					UIKit,
					"-framework",
					AVFoundation,
					"-framework",
					CallKit,
					"-framework",
					PushKit,
					"-framework",
					AudioToolbox,
					"-framework",
					CoreTelephony,
					"-framework",
					Network,
					"-framework",
					SystemConfiguration,
					"-framework",
					CFNetwork,
				);
				PRODUCT_BUNDLE_IDENTIFIER = net.yeastar.softphone.swift;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				SWIFT_INSTALL_OBJC_HEADER = YES;
				SWIFT_OBJC_INTERFACE_HEADER_NAME = Softphone_Swift.h;
			}};
			name = Debug;
		}};
		{uid('TARGET-Release', 'BC')} /* Release */ = {{
			isa = XCBuildConfiguration;
			buildSettings = {{
				CLANG_ENABLE_MODULES = YES;
				CLANG_ENABLE_OBJC_ARC = YES;
				DEFINES_MODULE = YES;
				MODULEMAP_FILE = \"$(SRCROOT)/Sources/SipCore/Softphone_Swift.modulemap\";
				GCC_PREPROCESSOR_DEFINITIONS = (
					"$(inherited)",
					"PJ_AUTOCONF=1",
					"PJ_ENABLE_WEBRTC_INTEGRATION=1",
				);
				DYLIB_INSTALL_NAME_BASE = "@rpath";
				FRAMEWORK_SEARCH_PATHS = (
					"$(inherited)",
					"$(SRCROOT)/Vendor",
					"$(SRCROOT)/Vendor/WebRTC.xcframework/ios-arm64",
				);
				GENERATE_INFOPLIST_FILE = YES;
				HEADER_SEARCH_PATHS = (
					"$(inherited)",
					"$(SRCROOT)/Sources/SipCore",
					"$(SRCROOT)/Vendor/pjsip-include",
				);
				OTHER_LDFLAGS = (
					"$(inherited)",
					"$(SRCROOT)/Vendor/libpjsip-combined.a",
					"-framework",
					WebRTC,
					"-framework",
					UIKit,
					"-framework",
					AVFoundation,
					"-framework",
					CallKit,
					"-framework",
					PushKit,
					"-framework",
					AudioToolbox,
					"-framework",
					CoreTelephony,
					"-framework",
					Network,
					"-framework",
					SystemConfiguration,
					"-framework",
					CFNetwork,
				);
				PRODUCT_BUNDLE_IDENTIFIER = net.yeastar.softphone.swift;
				PRODUCT_NAME = "$(TARGET_NAME)";
				SKIP_INSTALL = YES;
				SWIFT_INSTALL_OBJC_HEADER = YES;
				SWIFT_OBJC_INTERFACE_HEADER_NAME = Softphone_Swift.h;
			}};
			name = Release;
		}};
/* End XCBuildConfiguration section */

/* Begin XCConfigurationList section */
		{uid('PROJECT-CL', 'CL')} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{uid('PROJECT-Debug', 'BC')} /* Debug */,
				{uid('PROJECT-Release', 'BC')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
		{uid('TARGET-CL', 'CL')} = {{
			isa = XCConfigurationList;
			buildConfigurations = (
				{uid('TARGET-Debug', 'BC')} /* Debug */,
				{uid('TARGET-Release', 'BC')} /* Release */,
			);
			defaultConfigurationIsVisible = 0;
			defaultConfigurationName = Release;
		}};
/* End XCConfigurationList section */
	}};
	rootObject = {uid('PROJECT', 'PJ')} /* Project object */;
}}
"""
    out = ROOT / "CompatFW.xcodeproj" / "project.pbxproj"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(proj)
    print(f"wrote {out} ({len(src_files)} sources)")


if __name__ == "__main__":
    main()
