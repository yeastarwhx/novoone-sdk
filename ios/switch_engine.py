#!/usr/bin/env python3
"""iOS 双引擎切换(终态版):App 工程 pbxproj 的 SPM 包引用切换。

用法:
  switch_engine.py native [app_ios_dir]    # 切自研(126.x):Acrobits saas 远程包 -> 本地 NovoSDKCompat
  switch_engine.py acrobits [app_ios_dir]  # 回切 Acrobits(26.x):git restore 恢复 HEAD 基线
  switch_engine.py status [app_ios_dir]    # 当前引擎 / 版本 / pbxproj git 状态
  switch_engine.py selftest [app_ios_dir]  # 对该工程 git HEAD 基线跑 native 变换自检(只读不写)

app_ios_dir 缺省 = 根目录调试工程(DEFAULT_APP_IOS);任意 novoone-app 仓库的
ios 目录(含 NovoOneApp.xcodeproj)均可传入,relativePath 按两工程实际位置计算。

边界(任务决策):
- 仅操作 NovoOneApp target:saas 包引用 + 该 target 两个 config 的
  MARKETING_VERSION;OEM(saas-video 包/target)不动——pbxproj 内 OEM 是
  独立包引用与独立 target,变换正则均精确锚定 saas(非 saas-video)。
- 双版本打包联动(11-02-dual-version-packaging):native 方向同时 bump
  NovoOneApp/Supporting/Expo.plist 的 EXUpdatesRuntimeVersion(26.x ->
  126.x)——runtimeVersion 是 expo-updates OTA 通道隔离键,自研形态走独立
  126.x 通道(26.x 线上通道不受影响);该文件与 pbxproj 同模式随 acrobits
  方向 git restore 一并回退。老工程无 Expo.plist 时宽容跳过。
- App 仓库 git 基线恒为 Acrobits 形态:native 产物由脚本即时生成、不提交。
- acrobits 方向不做文本逆变换:xcodebuild -list/build 会规范化重写 pbxproj
  (包引用拆 section、注释名/URL 大小写改写、relativePath 加引号),逆变换
  正则在新格式上必然失配,故直接 git restore 回 HEAD 基线。
- 双名字切换(11-03 标识剥离,2026-11-04):本地包 NovoSDKSwiftPackage 与
  Acrobits 远程包不再同名顶替——native 变换在包引用之外同步替换
  productDependency 的 productName 与注释名,App 侧 productName 引用
  由脚本一并变换(同名红利废弃后这是双形态编译一致性的必要条件)。
- shim 包(NovoSDKAcrobitsShim):Acrobits 基线常驻本地包(module
  NovoSDK_Swift,typealias 再导出 Acrobits 真身 Softphone*),与远程
  saas 包双引用共存;native 变换将 shim 五处引用一并剥除(自研形态
  module 名由 NovoSDKCompat 顶替,不引用 shim)。engine_state 因此
  改锚 productName NovoSDKSwiftPackage——native 独有特征,基线的
  shim local 引用不再能区分形态。
"""
import os
import re
import subprocess
import sys
import pathlib

DEFAULT_APP_IOS = "/Users/lzj/Desktop/novosdk/novoone-app/ios"
APP_MAIN_TARGET = "NovoOneApp"
GIT_PATHSPEC = "NovoOneApp.xcodeproj/project.pbxproj"

# 自研包绝对位置(本脚本所在 ios/ 下)
SDK_COMPAT = pathlib.Path(__file__).resolve().parent / "NovoSDKCompat"

REMOTE_BLOCK_RE = re.compile(
    r'(?P<id>\w{24}) /\* XCRemoteSwiftPackageReference "SoftphoneSwiftPackage-saas" \*/ = \{\n'
    r"\t+isa = XCRemoteSwiftPackageReference;\n"
    r'\t+repositoryURL = "https://github\.com/Acrobits-Dev/SoftphoneSwiftPackage-saas";\n'
    r"\t+requirement = \{\n"
    r"\t+kind = upToNextMajorVersion;\n"
    r"\t+minimumVersion = [\d.]+;\n"
    r"\t+\};\n"
    r"\t+\};"
)

# shim 包(NovoSDKAcrobitsShim)五处引用——native 变换剥除。基线手写与
# xcodebuild 规范化两种格式都兼容(relativePath 引号可选、缩进 \t+)
SHIM_BUILD_FILE_RE = re.compile(
    r"\t\t\w{24} /\* NovoSDK_Swift in Frameworks \*/ = \{isa = PBXBuildFile;"
    r" productRef = \w{24} /\* NovoSDK_Swift \*/; \};\n")
SHIM_FRAMEWORKS_LINE_RE = re.compile(
    r"\t+\w{24} /\* NovoSDK_Swift in Frameworks \*/,\n")
SHIM_PKGREF_LINE_RE = re.compile(
    r'\t+\w{24} /\* XCLocalSwiftPackageReference "NovoSDKAcrobitsShim" \*/,\n')
SHIM_LOCAL_BLOCK_RE = re.compile(
    r'\t\t\w{24} /\* XCLocalSwiftPackageReference "NovoSDKAcrobitsShim" \*/ = \{\n'
    r"\t+isa = XCLocalSwiftPackageReference;\n"
    r'\t+relativePath = "?NovoSDKAcrobitsShim"?;\n'
    r"\t+\};\n")
SHIM_PRODUCTDEP_BLOCK_RE = re.compile(
    r'\t\t\w{24} /\* NovoSDK_Swift \*/ = \{\n'
    r"\t+isa = XCSwiftPackageProductDependency;\n"
    r'\t+package = \w{24} /\* XCLocalSwiftPackageReference "NovoSDKAcrobitsShim" \*/;\n'
    r'\t+productName = "NovoSDK_Swift";\n'
    r"\t+\};\n")

# shim 接线的三个手写 pbxproj ID(剥除后残留断言用;native 产物必无)
SHIM_IDS = (
    "E4D5FA1130538F190051F770",  # XCLocalSwiftPackageReference
    "E4D5FA1230538F190051F770",  # XCSwiftPackageProductDependency
    "E4D5FA1330538F190051F770",  # PBXBuildFile
)


def strip_shim(text: str) -> tuple:
    """剥除 Acrobits 基线中 shim(NovoSDKAcrobitsShim)的五处引用;返回
    (新文本, 删除处数)。每处必须恰好命中一次,失配即报错(基线变更,或
    shim 接线尚未提交——selftest 对 HEAD 基线跑,提交前属预期)。
    五处均为 NovoOneApp target 接线;OEM(saas-video)是既有断点不接
    shim——若日后给 OEM 接 shim,此处与上方五正则须同步扩展计数。
    剥除后兜底断言:Xcode 若把接线重写成五正则之外的形态(如
    packageProductDependencies 列表),exact-1 仍可能全过而残留悬空
    ID/注释,此处兜住(shim ID 为本工程手写值,native 产物必无)"""
    total = 0
    for pat in (SHIM_BUILD_FILE_RE, SHIM_FRAMEWORKS_LINE_RE,
                SHIM_PKGREF_LINE_RE, SHIM_LOCAL_BLOCK_RE,
                SHIM_PRODUCTDEP_BLOCK_RE):
        text, n = pat.subn("", text)
        if n != 1:
            raise SystemExit(
                "shim strip expected 1 hit, got %d (baseline changed,"
                " or shim wiring not yet committed?): %s"
                % (n, pat.pattern[:60]))
        total += n
    if any(i in text for i in SHIM_IDS):
        raise SystemExit("shim id residue after strip (rewritten wiring?)")
    if "NovoSDKAcrobitsShim" in text:
        raise SystemExit("shim package name residue after strip")
    return text, total


# ---------------- 目标工程解析 ----------------

class AppProject:
    """一次切换的目标 App 工程(pbxproj 路径 + git 操作位 + 本地包相对路径)"""

    def __init__(self, app_ios: str):
        self.pbxproj = pathlib.Path(app_ios, "NovoOneApp.xcodeproj", "project.pbxproj")
        if not self.pbxproj.is_file():
            raise SystemExit("pbxproj not found: " + str(self.pbxproj))
        self.git_cwd = str(self.pbxproj.parents[1])
        # Expo.plist(expo-updates 原生配置,EXUpdatesRuntimeVersion 固化处)。
        # 存在才处理:老工程/无 OTA 工程宽容跳过
        self.expo_plist = pathlib.Path(
            app_ios, "NovoOneApp", "Supporting", "Expo.plist")
        if not self.expo_plist.is_file():
            self.expo_plist = None
        self.local_rel = os.path.relpath(SDK_COMPAT, app_ios)
        if '"' in self.local_rel or "\n" in self.local_rel:
            raise SystemExit(
                "relativePath not representable in pbxproj: " + self.local_rel)
        # 占位符 @ID@ 后期 replace 注入(%s/% 格式化会被路径中的 % 破坏);
        # relativePath 加引号——pbxproj 字符串值标准形式,含空格路径必须
        self.local_block = (
            '@ID@ /* XCLocalSwiftPackageReference "NovoSDKSwiftPackage" */ = {\n'
            "\t\t\tisa = XCLocalSwiftPackageReference;\n"
            '\t\t\trelativePath = "' + self.local_rel + '";\n'
            "\t\t};"
        )


# ---------------- git 基线 ----------------

def _git_pathspec() -> list:
    """切换脚本管辖的 pathspec(pbxproj + Expo.plist + SPM Package.resolved);
    acrobits 方向 git restore 一并回退。Package.resolved:native 形态下
    xcodebuild 会删除(SPM 仅剩本地包无远程可锁),acrobits 方向须复原"""
    return [
        GIT_PATHSPEC,
        # 以下均相对 git_cwd(即 ios 目录)
        "NovoOneApp/Supporting/Expo.plist",
        "NovoOneApp.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ]


def pbxproj_clean(app: AppProject) -> bool:
    """管辖文件与 HEAD 是否一致(自研形态切换的安全基线;显式比 HEAD——
    裸 diff --quiet 只比工作区 vs 索引,staged 改动会穿门)"""
    return subprocess.run(
        ["git", "-C", app.git_cwd, "diff", "--quiet", "HEAD", "--"]
        + _git_pathspec(),
    ).returncode == 0


def diff_stat(app: AppProject) -> str:
    return subprocess.run(
        ["git", "-C", app.git_cwd, "diff", "--stat", "HEAD", "--"]
        + _git_pathspec(),
        capture_output=True, text=True,
    ).stdout.strip()


def head_text(app: AppProject) -> str:
    """git HEAD 的 pbxproj 文本(约定即 Acrobits 基线)"""
    root = subprocess.run(
        ["git", "-C", app.git_cwd, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    if root.returncode != 0:
        raise SystemExit("git repo root not found: " + app.git_cwd)
    rel = app.pbxproj.resolve().relative_to(root.stdout.strip())
    out = subprocess.run(
        ["git", "-C", app.git_cwd, "show", "HEAD:" + str(rel)],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise SystemExit("git show HEAD:" + str(rel) + " failed:\n" + out.stderr)
    return out.stdout


# ---------------- MARKETING_VERSION(仅 NovoOneApp target) ----------------

def app_target_config_ids(text: str) -> list:
    """NovoOneApp 的 XCConfigurationList -> 两个 XCBuildConfiguration id"""
    m = re.search(
        r'(\w{24}) /\* Build configuration list for PBXNativeTarget "'
        + re.escape(APP_MAIN_TARGET) + r'" \*/ = \{\n'
        r"\t+isa = XCConfigurationList;\n"
        r"\t+buildConfigurations = \(\n((?:\t+\w{24}[^\n]*\n)+)",
        text,
    )
    if not m:
        raise SystemExit("NovoOneApp configuration list not found")
    return re.findall(r"(\w{24}) /\* \w+ \*/", m.group(2))


def bump_versions_native(text: str) -> tuple:
    """仅 NovoOneApp 的 config 块内 26.x.y -> 126.x.y;返回 (新文本, 替换处数)"""
    count = 0

    def sub_block(match: "re.Match") -> str:
        nonlocal count
        block, n = re.subn(
            r"MARKETING_VERSION = 26\.(\d+\.\d+);",
            r"MARKETING_VERSION = 126.\1;", match.group(0))
        count += n
        return block

    new_text = text
    for cid in app_target_config_ids(text):
        block_re = re.compile(
            re.escape(cid) + r" /\* (Debug|Release) \*/ = \{.*?\n\t\t\};",
            re.S)
        new_text = block_re.sub(sub_block, new_text, count=1)
    return new_text, count


# ---------------- 变换(唯一文本变换:native 方向) ----------------

EXPO_RUNTIME_VERSION_RE = re.compile(
    r'(<key>EXUpdatesRuntimeVersion</key>\s*<string>)26\.(\d+\.\d+)(</string>)')


def bump_expo_runtime_version(text: str) -> tuple:
    """Expo.plist 的 EXUpdatesRuntimeVersion 26.x.y -> 126.x.y;
    返回 (新文本, 替换处数)。双版本打包:runtimeVersion 是 expo-updates
    OTA 通道隔离键,自研形态必须与 Acrobits 通道分离(126.x 独立通道)"""
    return EXPO_RUNTIME_VERSION_RE.subn(r"\g<1>126.\g<2>\g<3>", text)


def transform_to_native(app: AppProject, text: str) -> tuple:
    """Acrobits 基线 -> native 形态;返回 (新文本, 摘要行列表)。
    Expo.plist(存在时)在函数外单独 bump(native 分支主体处理)。
    双名字切换(11-03):包引用块之外,productDependency 的 productName 与
    各处注释名一并 SoftphoneSwiftPackage-saas -> NovoSDKSwiftPackage"""
    notes = []
    if not REMOTE_BLOCK_RE.search(text):
        raise SystemExit("remote saas reference block not found (baseline changed?)")
    text = REMOTE_BLOCK_RE.sub(
        lambda mm: app.local_block.replace("@ID@", mm.group("id")), text, count=1)
    text, shim_n = strip_shim(text)
    notes.append(f"shim NovoSDKAcrobitsShim: stripped ({shim_n} refs)")
    text = text.replace(
        'XCRemoteSwiftPackageReference "SoftphoneSwiftPackage-saas" */',
        'XCLocalSwiftPackageReference "NovoSDKSwiftPackage" */')
    text, n = re.subn(
        r'productName = "SoftphoneSwiftPackage-saas";',
        'productName = "NovoSDKSwiftPackage";', text)
    if n == 0:
        raise SystemExit("productDependency productName saas not found (baseline changed?)")
    text = text.replace(
        "/* SoftphoneSwiftPackage-saas in Frameworks */",
        "/* NovoSDKSwiftPackage in Frameworks */")
    text = text.replace(
        "/* SoftphoneSwiftPackage-saas */", "/* NovoSDKSwiftPackage */")
    notes.append("saas package: XCRemote -> XCLocal (" + app.local_rel + ")")
    notes.append(f"productName: SoftphoneSwiftPackage-saas -> NovoSDKSwiftPackage (x{n})")
    text, n = bump_versions_native(text)
    if n == 0:
        raise SystemExit("NovoOneApp MARKETING_VERSION 26.x.y not found")
    notes.append(f"MARKETING_VERSION: 26.x -> 126.x ({APP_MAIN_TARGET} x{n})")
    return text, notes


def bump_expo_plist_native(app: AppProject, notes: list) -> None:
    """Expo.plist EXUpdatesRuntimeVersion 就地 bump(native 方向;存在才
    处理,老工程宽容跳过)。与 pbxproj 同模式:产物不提交,acrobits 方向
    git restore 一并回退"""
    if app.expo_plist is None:
        return
    expo_text = app.expo_plist.read_text()
    expo_new, n = bump_expo_runtime_version(expo_text)
    if n == 0:
        raise SystemExit(
            "Expo.plist EXUpdatesRuntimeVersion 26.x.y not found (baseline changed?)")
    app.expo_plist.write_text(expo_new)
    notes.append(f"Expo.plist EXUpdatesRuntimeVersion: 26.x -> 126.x (x{n})")


def write_version_marker(app: AppProject, native: bool, base: str = None) -> None:
    """写/删 app.config.js 的版本标记文件 android/app/build/dual-version.json
    (与 Android gradle 配置期同一通道;iOS 不跑 gradle,由本脚本维护)。
    JS 层(Metro dev / expo export:embed)读它决定 expo.version 与
    runtimeVersion——缺失时 app.config.js 回落默认 26.x,自研形态的
    关于页/help-support 上报会显示错值(UA/versionName 不受影响,走原生)。
    build/ 目录 gitignored,不入库、acrobits 方向直接删除。
    native 方向的 base 须由调用方在 pbxproj bump 前提取传入(提取后
    NovoOneApp 已是 126.x,剩 OEM 的 26.x 会误匹配)"""
    # 标记在仓库根 android/ 下(pbxproj.parents[1] 是 ios/ 目录,
    # 会误写 ios/android/...;git rev-parse 取仓库根,失败回落 parents[2])
    root = subprocess.run(
        ["git", "-C", app.git_cwd, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True)
    if root.returncode == 0:
        repo_root = pathlib.Path(root.stdout.strip())
    else:
        repo_root = app.pbxproj.parents[2]
    marker = repo_root / "android" / "app" / "build" / "dual-version.json"
    if native:
        if not base:
            raise SystemExit("base version required for native marker")
        marker.parent.mkdir(parents=True, exist_ok=True)
        marker.write_text(
            '{"nativeEngine": true, "baseVersion": "' + base + '"}')
    else:
        marker.unlink(missing_ok=True)


def engine_state(text: str) -> str:
    """native 特征锚定:productName NovoSDKSwiftPackage 仅 native 产物有
    (Acrobits 基线的 shim 也是 XCLocalSwiftPackageReference,旧判据已失效)"""
    return "native" if 'productName = "NovoSDKSwiftPackage";' in text else "acrobits"


def print_status(app: AppProject) -> None:
    text = app.pbxproj.read_text()
    ver = sorted(set(re.findall(r"MARKETING_VERSION = ([0-9.]+)", text)))
    state = engine_state(text)
    print(f"engine={state} MARKETING_VERSION={ver}")
    if pbxproj_clean(app):
        print("pbxproj: clean (= git HEAD, Acrobits baseline)")
    elif state == "native":
        print("pbxproj: script/xcodebuild-modified (native form, by design NOT"
              " committed; `switch_engine.py acrobits` = git restore)")
    else:
        print("pbxproj: DIRTY in acrobits state (manual edits?) -- review and"
              f" restore manually:\n{diff_stat(app)}")


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "status"
    # 先校验 mode 再碰工程:--help/拼错子命令不该被缺省工程缺失误导
    if mode not in ("status", "selftest", "native", "acrobits"):
        raise SystemExit(__doc__)
    app = AppProject(sys.argv[2] if len(sys.argv) > 2 else DEFAULT_APP_IOS)
    if mode == "status":
        print_status(app)
        return

    if mode == "selftest":
        base = head_text(app)
        native, notes = transform_to_native(app, base)
        ok = ("XCLocalSwiftPackageReference" in native
              and "MARKETING_VERSION = 126." in native
              and REMOTE_BLOCK_RE.search(native) is None
              and 'productName = "NovoSDKSwiftPackage";' in native
              # 收尾引号锚定:OEM 的 "SoftphoneSwiftPackage-saas-video" 是
              # 合法保留项,裸前缀子串会误伤
              and 'SoftphoneSwiftPackage-saas"' not in native
              # shim 五处引用须全部剥除(分号锚定,NovoSDKSwiftPackage
              # 是不同串不受影响)
              and "NovoSDKAcrobitsShim" not in native
              and 'productName = "NovoSDK_Swift";' not in native)
        # Expo.plist bump 自检(HEAD 基线文本,只读不写)
        if app.expo_plist is not None:
            root = subprocess.run(
                ["git", "-C", app.git_cwd, "rev-parse", "--show-toplevel"],
                capture_output=True, text=True)
            if root.returncode == 0:
                rel = app.expo_plist.resolve().relative_to(
                    root.stdout.strip())
                expo_out = subprocess.run(
                    ["git", "-C", app.git_cwd, "show", "HEAD:" + str(rel)],
                    capture_output=True, text=True)
                if expo_out.returncode == 0:
                    expo_new, n = bump_expo_runtime_version(expo_out.stdout)
                    ok = ok and n > 0 and "126." in expo_new
        # saas 版本双声明一致性:pbxproj 远程引用的 minimumVersion 与 shim 包
        # Package.swift 的 from: 须同版本——只升一处会令 SPM 对同一包解析出
        # 不可交约束,且报错位置(shim 包内)远离实际改动(pbxproj)。shim 包
        # 尚未入库时 HEAD 无该文件,此检查跳过(提交后生效)。
        shim_pkg = pathlib.Path(
            app.pbxproj.parents[1], "NovoSDKAcrobitsShim", "Package.swift")
        remote_m = REMOTE_BLOCK_RE.search(base)
        if remote_m is not None and shim_pkg.is_file():
            root = subprocess.run(
                ["git", "-C", app.git_cwd, "rev-parse", "--show-toplevel"],
                capture_output=True, text=True)
            if root.returncode == 0:
                rel = shim_pkg.resolve().relative_to(root.stdout.strip())
                pkg_out = subprocess.run(
                    ["git", "-C", app.git_cwd, "show", "HEAD:" + str(rel)],
                    capture_output=True, text=True)
                if pkg_out.returncode == 0:
                    v_pbx = re.search(
                        r"minimumVersion = ([\d.]+);", remote_m.group(0))
                    v_pkg = re.search(r'from:\s*"([\d.]+)"', pkg_out.stdout)
                    same = (v_pbx is not None and v_pkg is not None
                            and v_pbx.group(1) == v_pkg.group(1))
                    ok = ok and same
                    if not same:
                        print("  ! saas version drift: pbxproj=%s shim=%s"
                              % (v_pbx.group(1) if v_pbx else "?",
                                 v_pkg.group(1) if v_pkg else "?"))
        print("selftest (native transform over git HEAD baseline):",
              "PASS" if ok else "FAIL")
        for line in notes:
            print("  + " + line)
        sys.exit(0 if ok else 1)

    if mode == "native":
        if engine_state(app.pbxproj.read_text()) == "native":
            print("already native (use `switch_engine.py acrobits` to go back)")
            print_status(app)
            return
        # 安全基线:管辖文件(pbxproj + Expo.plist)必须与 HEAD 一致(约定即
        # Acrobits 形态),防止把人工改动卷进脚本产物、acrobits 恢复时丢失
        if not pbxproj_clean(app):
            raise SystemExit(
                "REFUSED: pbxproj/Expo.plist/Package.resolved has uncommitted changes vs HEAD.\n"
                "  Commit/stash/restore them first -- switch must start from the "
                "clean Acrobits baseline.")
        # base 版本在 bump 前提取(标记文件 + JS 层版本用;bump 后
        # NovoOneApp 已是 126.x,剩 OEM 的 26.x 会误匹配)
        base_m = re.search(
            r"MARKETING_VERSION = 26\.(\d+\.\d+);", app.pbxproj.read_text())
        if not base_m:
            raise SystemExit("NovoOneApp MARKETING_VERSION 26.x.y not found")
        base_version = "26." + base_m.group(1)
        new, notes = transform_to_native(app, app.pbxproj.read_text())
        app.pbxproj.write_text(new)
        bump_expo_plist_native(app, notes)
        write_version_marker(app, native=True, base=base_version)
        notes.append("dual-version.json: written (native, base=" + base_version + ")")
        for line in notes:
            print("+ " + line)
        print(f"\ngit diff --stat:\n{diff_stat(app)}")
        print_status(app)
    else:
        # acrobits:git restore 回 HEAD 基线(不做文本逆变换,见模块 docstring)
        if pbxproj_clean(app):
            print("already acrobits (pbxproj clean = git HEAD baseline)")
            print_status(app)
            return
        if engine_state(app.pbxproj.read_text()) != "native":
            raise SystemExit(
                "REFUSED: pbxproj dirty in acrobits state (manual edits?).\n"
                "  Review and restore manually -- auto-restore would drop them:\n"
                + diff_stat(app))
        print("discarding native-form changes, git restore to HEAD baseline")
        print("dropping:\n" + (diff_stat(app) or "(stat empty)"))
        subprocess.run(
            ["git", "-C", app.git_cwd, "restore", "--"] + _git_pathspec(),
            check=True)
        # 版本标记文件是 build/ 产物(不在 git 管辖),restore 不覆盖,手动清
        write_version_marker(app, native=False)
        print("\npbxproj:",
              "clean (restored to Acrobits baseline)" if pbxproj_clean(app)
              else "STILL DIRTY AFTER RESTORE -- investigate")
        print_status(app)


if __name__ == "__main__":
    main()
