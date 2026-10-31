#!/usr/bin/env python3
"""iOS 双引擎切换(终态版):App 工程 pbxproj 的 SPM 包引用切换。

用法:
  switch_engine.py native [app_ios_dir]    # 切自研(126.x):saas 包引用 -> 本地 SoftphoneCompat
  switch_engine.py acrobits [app_ios_dir]  # 回切 Acrobits(26.x):git restore 恢复 HEAD 基线
  switch_engine.py status [app_ios_dir]    # 当前引擎 / 版本 / pbxproj git 状态
  switch_engine.py selftest [app_ios_dir]  # 对该工程 git HEAD 基线跑 native 变换自检(只读不写)

app_ios_dir 缺省 = 根目录调试工程(DEFAULT_APP_IOS);任意 novoone-app 仓库的
ios 目录(含 NovoOneApp.xcodeproj)均可传入,relativePath 按两工程实际位置计算。

边界(任务决策):
- 仅操作 NovoOneApp target:saas 包引用 + 该 target 两个 config 的
  MARKETING_VERSION;OEM(saas-video 包/target)不动——pbxproj 内 OEM 是
  独立包引用与独立 target,变换正则均精确锚定 saas(非 saas-video)。
- App 仓库 git 基线恒为 Acrobits 形态:native 产物由脚本即时生成、不提交。
- acrobits 方向不做文本逆变换:xcodebuild -list/build 会规范化重写 pbxproj
  (包引用拆 section、注释名/URL 大小写改写、relativePath 加引号),逆变换
  正则在新格式上必然失配,故直接 git restore 回 HEAD 基线。
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
SDK_COMPAT = pathlib.Path(__file__).resolve().parent / "SoftphoneCompat"

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


# ---------------- 目标工程解析 ----------------

class AppProject:
    """一次切换的目标 App 工程(pbxproj 路径 + git 操作位 + 本地包相对路径)"""

    def __init__(self, app_ios: str):
        self.pbxproj = pathlib.Path(app_ios, "NovoOneApp.xcodeproj", "project.pbxproj")
        if not self.pbxproj.is_file():
            raise SystemExit("pbxproj not found: " + str(self.pbxproj))
        self.git_cwd = str(self.pbxproj.parents[1])
        self.local_rel = os.path.relpath(SDK_COMPAT, app_ios)
        if '"' in self.local_rel or "\n" in self.local_rel:
            raise SystemExit(
                "relativePath not representable in pbxproj: " + self.local_rel)
        # 占位符 @ID@ 后期 replace 注入(%s/% 格式化会被路径中的 % 破坏);
        # relativePath 加引号——pbxproj 字符串值标准形式,含空格路径必须
        self.local_block = (
            '@ID@ /* XCLocalSwiftPackageReference "SoftphoneSwiftPackage-saas" */ = {\n'
            "\t\t\tisa = XCLocalSwiftPackageReference;\n"
            '\t\t\trelativePath = "' + self.local_rel + '";\n'
            "\t\t};"
        )


# ---------------- git 基线 ----------------

def pbxproj_clean(app: AppProject) -> bool:
    """pbxproj 与 HEAD 是否一致(自研形态切换的安全基线;显式比 HEAD——
    裸 diff --quiet 只比工作区 vs 索引,staged 改动会穿门)"""
    return subprocess.run(
        ["git", "-C", app.git_cwd, "diff", "--quiet", "HEAD", "--", GIT_PATHSPEC],
    ).returncode == 0


def diff_stat(app: AppProject) -> str:
    return subprocess.run(
        ["git", "-C", app.git_cwd, "diff", "--stat", "HEAD", "--", GIT_PATHSPEC],
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

def transform_to_native(app: AppProject, text: str) -> tuple:
    """Acrobits 基线 -> native 形态;返回 (新文本, 摘要行列表)"""
    notes = []
    if not REMOTE_BLOCK_RE.search(text):
        raise SystemExit("remote saas reference block not found (baseline changed?)")
    text = REMOTE_BLOCK_RE.sub(
        lambda mm: app.local_block.replace("@ID@", mm.group("id")), text, count=1)
    text = text.replace(
        'XCRemoteSwiftPackageReference "SoftphoneSwiftPackage-saas" */',
        'XCLocalSwiftPackageReference "SoftphoneSwiftPackage-saas" */')
    notes.append("saas package: XCRemote -> XCLocal (" + app.local_rel + ")")
    text, n = bump_versions_native(text)
    if n == 0:
        raise SystemExit("NovoOneApp MARKETING_VERSION 26.x.y not found")
    notes.append(f"MARKETING_VERSION: 26.x -> 126.x ({APP_MAIN_TARGET} x{n})")
    return text, notes


def engine_state(text: str) -> str:
    return "native" if "XCLocalSwiftPackageReference" in text else "acrobits"


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
              and REMOTE_BLOCK_RE.search(native) is None)
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
        # 安全基线:pbxproj 必须与 HEAD 一致(约定即 Acrobits 形态),
        # 防止把人工改动卷进脚本产物、acrobits 恢复时丢失
        if not pbxproj_clean(app):
            raise SystemExit(
                "REFUSED: pbxproj has uncommitted changes vs HEAD.\n"
                "  Commit/stash/restore them first -- switch must start from the "
                "clean Acrobits baseline.")
        new, notes = transform_to_native(app, app.pbxproj.read_text())
        app.pbxproj.write_text(new)
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
            ["git", "-C", app.git_cwd, "restore", "--", GIT_PATHSPEC], check=True)
        print("\npbxproj:",
              "clean (restored to Acrobits baseline)" if pbxproj_clean(app)
              else "STILL DIRTY AFTER RESTORE -- investigate")
        print_status(app)


if __name__ == "__main__":
    main()
