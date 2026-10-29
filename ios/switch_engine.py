#!/usr/bin/env python3
"""iOS 双引擎切换(终态版):App 工程 pbxproj 的 SPM 包引用切换。

用法:
  switch_engine.py native    # 切自研(126.9.x):saas 包引用 -> 本地 SoftphoneCompat
  switch_engine.py acrobits  # 回切 Acrobits(26.9.x):git restore 恢复 HEAD 基线
  switch_engine.py status    # 当前引擎 / 版本 / pbxproj git 状态
  switch_engine.py selftest  # 对 git HEAD 基线跑 native 变换自检(只读不写文件)

边界(任务决策):
- 仅操作 NovoOneApp target:saas 包引用 + 该 target 两个 config 的
  MARKETING_VERSION;OEM(saas-video 包/target)不动——pbxproj 内 OEM 是
  独立包引用与独立 target,变换正则均精确锚定 saas(非 saas-video)。
- App 仓库 git 基线恒为 Acrobits 形态:native 产物由脚本即时生成、不提交。
- acrobits 方向不做文本逆变换:xcodebuild -list/build 会规范化重写 pbxproj
  (包引用拆 section、注释名/URL 大小写改写、relativePath 加引号),逆变换
  正则在新格式上必然失配,故直接 git restore 回 HEAD 基线。
"""
import re
import subprocess
import sys
import pathlib

APP_PBXPROJ = pathlib.Path(
    "/Users/lzj/Desktop/novosdk/SDK/novoone-app/ios/NovoOneApp.xcodeproj/project.pbxproj"
)
APP_MAIN_TARGET = "NovoOneApp"
GIT_CWD = str(APP_PBXPROJ.parents[1])          # .../novoone-app/ios
GIT_PATHSPEC = "NovoOneApp.xcodeproj/project.pbxproj"

REMOTE_BLOCK_RE = re.compile(
    r'(?P<id>\w{24}) /\* XCRemoteSwiftPackageReference "SoftphoneSwiftPackage-saas" \*/ = \{\n'
    r"\t+isa = XCRemoteSwiftPackageReference;\n"
    r'\t+repositoryURL = "https://github\.com/Acrobits-Dev/SoftphoneSwiftPackage-saas";\n'
    r"\t+requirement = \{\n"
    r"\t+kind = upToNextMajorVersion;\n"
    r"\t+minimumVersion = 25\.3\.35;\n"
    r"\t+\};\n"
    r"\t+\};"
)
LOCAL_BLOCK = (
    '%(id)s /* XCLocalSwiftPackageReference "SoftphoneSwiftPackage-saas" */ = {\n'
    "\t\t\tisa = XCLocalSwiftPackageReference;\n"
    "\t\t\trelativePath = ../../novoone-sdk/ios/SoftphoneCompat;\n"
    "\t\t};"
)


# ---------------- git 基线 ----------------

def pbxproj_clean() -> bool:
    """pbxproj 与 HEAD 是否一致(自研形态切换的安全基线)"""
    return subprocess.run(
        ["git", "-C", GIT_CWD, "diff", "--quiet", "--", GIT_PATHSPEC],
    ).returncode == 0


def diff_stat() -> str:
    return subprocess.run(
        ["git", "-C", GIT_CWD, "diff", "--stat", "--", GIT_PATHSPEC],
        capture_output=True, text=True,
    ).stdout.strip()


def head_text() -> str:
    """git HEAD 的 pbxproj 文本(约定即 Acrobits 基线)"""
    root = subprocess.run(
        ["git", "-C", GIT_CWD, "rev-parse", "--show-toplevel"],
        capture_output=True, text=True,
    )
    if root.returncode != 0:
        raise SystemExit("git repo root not found: " + GIT_CWD)
    rel = APP_PBXPROJ.resolve().relative_to(root.stdout.strip())
    out = subprocess.run(
        ["git", "-C", GIT_CWD, "show", "HEAD:" + str(rel)],
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
    """仅 NovoOneApp 的 config 块内 26.9.x -> 126.9.x;返回 (新文本, 替换处数)"""
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

def transform_to_native(text: str) -> tuple:
    """Acrobits 基线 -> native 形态;返回 (新文本, 摘要行列表)"""
    notes = []
    if not REMOTE_BLOCK_RE.search(text):
        raise SystemExit("remote saas reference block not found (baseline changed?)")
    text = REMOTE_BLOCK_RE.sub(
        lambda mm: LOCAL_BLOCK % {"id": mm.group("id")}, text, count=1)
    text = text.replace(
        'XCRemoteSwiftPackageReference "SoftphoneSwiftPackage-saas" */',
        'XCLocalSwiftPackageReference "SoftphoneSwiftPackage-saas" */')
    notes.append("saas package: XCRemote -> XCLocal (../../novoone-sdk/ios/SoftphoneCompat)")
    text, n = bump_versions_native(text)
    if n == 0:
        raise SystemExit("NovoOneApp MARKETING_VERSION 26.9.x not found")
    notes.append(f"MARKETING_VERSION: 26.9.x -> 126.9.x ({APP_MAIN_TARGET} x{n})")
    return text, notes


def engine_state(text: str) -> str:
    return "native" if "XCLocalSwiftPackageReference" in text else "acrobits"


def print_status() -> None:
    text = APP_PBXPROJ.read_text()
    ver = sorted(set(re.findall(r"MARKETING_VERSION = ([0-9.]+)", text)))
    state = engine_state(text)
    print(f"engine={state} MARKETING_VERSION={ver}")
    if pbxproj_clean():
        print("pbxproj: clean (= git HEAD, Acrobits baseline)")
    elif state == "native":
        print("pbxproj: script/xcodebuild-modified (native form, by design NOT"
              " committed; `switch_engine.py acrobits` = git restore)")
    else:
        print("pbxproj: DIRTY in acrobits state (manual edits?) -- review and"
              f" restore manually:\n{diff_stat()}")


def main() -> None:
    mode = sys.argv[1] if len(sys.argv) > 1 else "status"
    if mode == "status":
        print_status()
        return

    if mode == "selftest":
        base = head_text()
        native, notes = transform_to_native(base)
        ok = ("XCLocalSwiftPackageReference" in native
              and "MARKETING_VERSION = 126.9." in native
              and REMOTE_BLOCK_RE.search(native) is None)
        print("selftest (native transform over git HEAD baseline):",
              "PASS" if ok else "FAIL")
        for line in notes:
            print("  + " + line)
        sys.exit(0 if ok else 1)

    if mode not in ("native", "acrobits"):
        raise SystemExit(__doc__)

    if mode == "native":
        if engine_state(APP_PBXPROJ.read_text()) == "native":
            print("already native (use `switch_engine.py acrobits` to go back)")
            print_status()
            return
        # 安全基线:pbxproj 必须与 HEAD 一致(约定即 Acrobits 形态),
        # 防止把人工改动卷进脚本产物、acrobits 恢复时丢失
        if not pbxproj_clean():
            raise SystemExit(
                "REFUSED: pbxproj has uncommitted changes vs HEAD.\n"
                "  Commit/stash/restore them first -- switch must start from the "
                "clean Acrobits baseline.")
        new, notes = transform_to_native(APP_PBXPROJ.read_text())
        APP_PBXPROJ.write_text(new)
        for line in notes:
            print("+ " + line)
        print(f"\ngit diff --stat:\n{diff_stat()}")
        print_status()
    else:
        # acrobits:git restore 回 HEAD 基线(不做文本逆变换,见模块 docstring)
        if pbxproj_clean():
            print("already acrobits (pbxproj clean = git HEAD baseline)")
            print_status()
            return
        if engine_state(APP_PBXPROJ.read_text()) != "native":
            raise SystemExit(
                "REFUSED: pbxproj dirty in acrobits state (manual edits?).\n"
                "  Review and restore manually -- auto-restore would drop them:\n"
                + diff_stat())
        print("discarding native-form changes, git restore to HEAD baseline")
        print("dropping:\n" + (diff_stat() or "(stat empty)"))
        subprocess.run(
            ["git", "-C", GIT_CWD, "restore", "--", GIT_PATHSPEC], check=True)
        print("\npbxproj:",
              "clean (restored to Acrobits baseline)" if pbxproj_clean()
              else "STILL DIRTY AFTER RESTORE -- investigate")
        print_status()


if __name__ == "__main__":
    main()
