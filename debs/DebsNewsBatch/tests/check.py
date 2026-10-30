#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""DebsNewsBatch 静态守卫（本地跑，不依赖 iOS 编译）。

检查项覆盖：工程完整性、注入范围、路径安全（只用 App 自己的沙盒）、
下载行为约束（串行、magic 校验、不覆盖默认关）、纯 C 逻辑层是否被真引用。
用法：python3 tests/check.py
"""
import os
import plistlib
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "DebsNewsBatch")

passed = []
failed = []


def check(name, condition, detail=""):
    if condition:
        passed.append(name)
    else:
        failed.append("%s %s" % (name, ("-> " + detail) if detail else ""))


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as fh:
        return fh.read()


def sources():
    out = {}
    for name in sorted(os.listdir(SRC_DIR)):
        if name.endswith((".m", ".h")):
            out[name] = read(os.path.join(SRC_DIR, name))
    return out


def main():
    src = sources()
    all_text = "\n".join(src.values())
    joined = "\n".join(src.values()) + read(os.path.join(ROOT, "Makefile")) + read(os.path.join(ROOT, "control"))

    # ---------------- 工程完整性 ----------------
    for name in ("DBCommon", "DNBCommon.h", "DNBCommon.m", "DNBLogic.h", "DNBNewsItem.h", "DNBNewsItem.m",
                 "DNBNewsStore.h", "DNBNewsStore.m", "DNBDownloader.h", "DNBDownloader.m",
                 "DNBPanelViewController.h", "DNBPanelViewController.m", "DNBFloatingButton.h",
                 "DNBFloatingButton.m", "Tweak.m"):
        if name.startswith("DBCommon"):
            continue
        check("文件存在 %s" % name, os.path.isfile(os.path.join(SRC_DIR, name)))
    for name in ("Makefile", "control", "DebsNewsBatch.plist"):
        check("文件存在 %s" % name, os.path.isfile(os.path.join(ROOT, name)))
    check("纯 C 单测存在", os.path.isfile(os.path.join(ROOT, "tests", "dnb_logic_test.c")))

    # ---------------- 构建配置 ----------------
    makefile = read(os.path.join(ROOT, "Makefile"))
    check("Makefile 双架构", "ARCHS = arm64 arm64e" in makefile)
    check("Makefile SDK 15.5", "SDKVERSION = 15.5" in makefile)
    check("Makefile 目标 iSH 15.5/15.0", "TARGET = iphone:15.5:15.0" in makefile)
    check("Makefile ARC", "-fobjc-arc" in makefile)
    check("Makefile 自动收 .m", "$(wildcard DebsNewsBatch/*.m)" in makefile)
    mcount = len([n for n in src if n.endswith(".m")])
    check("源码 .m 数量 >= 6 (实际 %d)" % mcount, mcount >= 6)

    control = read(os.path.join(ROOT, "control"))
    ctrl = {}
    for line in control.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            ctrl[k] = v
    for key in ("Package", "Name", "Version", "Architecture", "Author", "Maintainer", "Section", "Depends"):
        check("control 含 %s" % key, key in ctrl)
    check("control 包名固定", ctrl.get("Package") == "com.niubiprass.debsnewsbatch")
    check("control 架构 rootless/deb 通用", ctrl.get("Architecture") == "iphoneos-arm64")
    check("control 版本 x.y.z", bool(re.fullmatch(r"\d+\.\d+\.\d+", ctrl.get("Version", ""))))

    # ---------------- 注入范围 ----------------
    with open(os.path.join(ROOT, "DebsNewsBatch.plist"), "rb") as fh:
        filt = plistlib.load(fh)
    bundles = filt.get("Filter", {}).get("Bundles", [])
    check("只注入 Debs 一个进程", bundles == ["com.iosdump.Debs.Debs"], repr(bundles))
    check("没有 %hook（不拦截原生方法）", "%hook" not in all_text and "%orig" not in all_text)
    check("入口使用 constructor", "__attribute__((constructor))" in src.get("Tweak.m", ""))
    tw = src.get("Tweak.m", "")
    check("入口只启动管家", "[DNBSelectionController start]" in tw)
    check("入口用 constructor", "__attribute__((constructor))" in tw)
    check("源码零 MSHook（不依赖 substrate）", "MSHook" not in all_text)
    check("不链接 libsubstrate", "-lsubstrate" not in makefile)

    # ---------------- 列表内选择（0.2.0 起的主交互） ----------------
    for name in ("DNBHook.h", "DNBHook.m", "DNBNewsBarView.h", "DNBNewsBarView.m",
                 "DNBRowTarget.h", "DNBRowTarget.m", "DNBSelectionController.h",
                 "DNBSelectionController.m"):
        check("选择层文件存在 %s" % name, os.path.isfile(os.path.join(SRC_DIR, name)))
    sel = src.get("DNBSelectionController.m", "")
    bar = src.get("DNBNewsBarView.m", "")
    row = src.get("DNBRowTarget.m", "")
    check("底条文案固定", "新闻批量下载 · 选择软件包" in src.get("DNBNewsBarView.m", ""))
    check("底条有取消/全选/下载", all(k in bar for k in ('@"取消"', '@"全选"', '@"下载"')))
    check("行控件画勾选圈", "cornerRadius = 10" in row and 'systemImageNamed:@"checkmark"' in row)
    check("选择态盖住行避免跳转", "sendActionsForControlEvents" in row)
    check("行标签用纯 C 解析", "dnb_parse_row_label" in sel)
    check("行标签按名称+版本+架构匹配", "dnblogic_row_matches" in sel)
    check("全选支持 UITableView", "numberOfRowsInSection" in sel)
    check("全选支持 UICollectionView", "numberOfItemsInSection" in sel)
    check("全选走 dataSource 而非只扫可见行", "cellForRowAtIndexPath" in sel)
    check("可见行优先用 visibleCells", "visibleCells" in sel)
    check("只在标题为新闻的页面绑定", '[root.navigationItem.title isEqualToString:@"新闻"]' in sel)
    check("定时器自找页面（不依赖页面生命周期）", "newsViewControllerFrom" in sel and "onTick" in sel)
    check("离开新闻页摘除", "离开新闻页，摘除覆盖层" in sel and "[self unbind]" in sel)
    check("长按进选择", "handleRowLongPress" in sel)
    check("覆盖层每次提到最前", "bringSubviewToFront:self.host" in sel)
    check("覆盖层按列表可视区裁剪", "clipsToBounds = YES" in sel)
    check("长按成立后吃掉触摸（松手不跳详情）", "cancelsTouchesInView = YES" in sel)
    check("覆盖层自己把拖动转给列表", "handleHostPan" in sel and "addGestureRecognizer:self.hostPan" in sel)
    check("选择时给底部条留出空间", "self.savedInset.bottom + 70" in sel)
    check("刚拖动完不误判点击", "panEndedAt" in sel)
    check("选中色铺满整行（左右内缩）", "self.host.bounds.size.width - 20" in sel)
    check("选中身份按行号（同包同版本不互牵连）", "tokenForRow" in sel and "indexPathForCell" in sel)
    check("全选也带行号", '"%@#%ld-%ld"' in sel)
    check("条按标签栏实际位置贴靠", "repositionBar" in sel and "UITabBar" in sel)
    check("找不到标签栏才退回 safeArea", "safeBottomY - 8.0" in sel)
    check("长按可继续加选", "if ([self.chosen containsObject:token])" in sel)
    check("滚动静默更新覆盖层", "contentOffset" in sel and "observeValueForKeyPath" in sel)
    check("离开页面必定摘除", "[self.host removeFromSuperview]" in sel and "[self.bar removeFromSuperview]" in sel)
    check("下载仍走 DNBDownloader", "initWithItems:items overwrite:NO writeRecord:YES" in sel)
    check("下载中禁用全选/显示停止", "DNBNewsBarStateRunning" in bar and '@"停止"' in bar)
    check("已完成显示统计", "showSummarySuccess" in bar)
    check("面板保留为长按入口", "DNBPanelViewController" in sel and "LongPress" in sel)

    # ---------------- 路径安全：必须走 App 自己的沙盒 ----------------
    forbidden = [
        r"/var/mobile/Containers",
        r"/var/containers/Bundle",
        r"/var/mobile/Library/Preferences",
        r"/private/var",
        r"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}",
    ]
    for pattern in forbidden:
        hits = re.findall(pattern, all_text)
        check("源码不含硬编码路径 %s" % pattern, not hits, str(hits[:3]))
    check("用 NSHomeDirectory 定位沙盒", "NSHomeDirectory()" in src.get("DNBCommon.m", ""))
    for fn in ("DNBAppDocumentsPath", "DNBNewsPath", "DNBDownloadsDir", "DNBMetadataPath", "DNBLogPath"):
        check("路径函数 %s 有定义" % fn, fn in src.get("DNBCommon.m", ""))
    check("新闻读取走 DNBNewsPath", "DNBNewsPath()" in src.get("DNBNewsStore.m", ""))
    check("下载落盘走 DNBDownloadsDir", "DNBDownloadsDir()" in src.get("DNBDownloader.m", ""))
    check("下载记录走 DNBMetadataPath", "DNBMetadataPath()" in src.get("DNBNewsStore.m", ""))
    check("下载器落记录走库接口", "appendDownloadRecords" in src.get("DNBDownloader.m", ""))
    check("写记录前备份", "backup" in src.get("DNBNewsStore.m", ""))

    path_literals = set(re.findall(r'stringByAppendingPathComponent:@"([^"]+)"', all_text))
    allowed_literals = {"Documents", "Downloads", "DEBs", "news.plist", "downloaded_metadata.plist",
                        "debsnewsbatch.log", "debsnewsbatch.log.bak"}
    extra = path_literals - allowed_literals
    check("没有额外路径字面量 %s" % sorted(extra), not extra)
    check("偏好只写自己的 suite", 'initWithSuiteName:@"com.niubiprass.debsnewsbatch"' in all_text)
    check("不写 App 自己的 standardUserDefaults", "standardUserDefaults" not in all_text)

    # ---------------- 下载行为 ----------------
    dl = src.get("DNBDownloader.m", "")
    check("下载用 NSURLSession downloadTask", "downloadTaskWithURL" in dl)
    check("只有下载器发起下载", len(re.findall(r"downloadTaskWithURL", all_text)) == len(re.findall(r"downloadTaskWithURL", dl)))
    check("串行：下载器无并发组", "dispatch_group" not in dl and "concurrentQueue" not in all_text)
    check("deb 头校验", "dnblogic_is_deb_magic" in dl)
    check("HTTP 状态校验", "statusCode" in dl)
    check("超时设置", "timeoutIntervalForRequest" in dl or "timeoutIntervalForResource" in dl)
    check("默认不覆盖", "overwriteSwitch.on = NO" in src.get("DNBPanelViewController.m", ""))
    check("覆盖判断走纯 C 逻辑", "dnblogic_should_write" in dl)
    check("保存名走纯 C 逻辑", "dnblogic_save_name" in all_text)

    # ---------------- 面板功能点 ----------------
    panel = src.get("DNBPanelViewController.m", "")
    for label in ("全选", "全不选", "下载选中", "停止", "刷新", "未下载", "arm64e"):
        check("面板含「%s」" % label, label in panel)
    check("有进度条", "UIProgressView" in panel)
    check("有筛选（4 档）", "全部" in panel and "未下载" in panel)
    check("下载前确认弹窗", "开始批量下载" in panel)
    check("结果汇总弹窗", "下载结束" in panel)
    check("选择状态跨筛选保留", "selectedKeys" in panel and "uniqueKey" in panel)
    check("下载中禁用误操作", "downloadButton.enabled = !running" in panel)
    check("长按菜单可复位按钮", "重置按钮位置" in src.get("DNBFloatingButton.m", ""))
    check("面板关闭恢复按钮", "onDismiss" in src.get("DNBFloatingButton.m", ""))

    # ---------------- 日志 ----------------
    common = src.get("DNBCommon.m", "")
    check("日志有上限", "kDNBLogMaxBytes" in common)
    check("日志线程安全", "@synchronized" in common or "dispatch_queue" in common)
    check("日志同时输出 NSLog", "NSLog" in common)

    # ---------------- 纯 C 逻辑层保持纯净 ----------------
    logic = src.get("DNBLogic.h", "")
    check("DNBLogic 不含 Foundation/UIKit 头",
          not re.search(r"[#](import|include)\s*[<\"]((Foundation)|(UIKit))", logic))
    for fn in ("dnblogic_join_url", "dnblogic_save_name", "dnblogic_filter_match",
               "dnblogic_is_deb_magic", "dnblogic_should_write", "dnblogic_percent",
               "dnblogic_sel_all", "dnblogic_sel_count", "dnblogic_sel_toggle"):
        check("逻辑函数 %s" % fn, fn in logic)
    for name, text in src.items():
        if "dnblogic_" in text and name.endswith((".m", ".c")):
            check("%s 引入 DNBLogic.h" % name, '#import "DNBLogic.h"' in text or '#include "DNBLogic.h"' in text)

    # ---------------- 括号平衡 ----------------
    for name, text in src.items():
        stripped = re.sub(r'"(\\.|[^"\\])*"', '""', text)
        stripped = re.sub(r"//[^\n]*", "", stripped)
        stripped = re.sub(r"/\*.*?\*/", "", stripped, flags=re.S)
        for open_ch, close_ch in (("{", "}"), ("(", ")"), ("[", "]")):
            check("%s 括号平衡 %s%s" % (name, open_ch, close_ch),
                  stripped.count(open_ch) == stripped.count(close_ch),
                  "%d vs %d" % (stripped.count(open_ch), stripped.count(close_ch)))

    # ---------------- 纯 C 单测真的能编过 ----------------
    proc = subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-I", SRC_DIR,
                           os.path.join(ROOT, "tests", "dnb_logic_test.c"),
                           "-o", "/tmp/dnb_logic_test_check"],
                          capture_output=True, text=True)
    check("纯 C 单测编译 -Werror 通过", proc.returncode == 0, proc.stderr.strip()[-400:])
    if proc.returncode == 0:
        run = subprocess.run(["/tmp/dnb_logic_test_check"], capture_output=True, text=True)
        check("纯 C 单测运行通过", run.returncode == 0 and "失败 0 项" in run.stdout,
              (run.stdout + run.stderr).strip()[-400:])

    print("静态守卫：通过 %d 项，失败 %d 项" % (len(passed), len(failed)))
    for item in failed:
        print("  ✗ " + item)
    if not failed:
        print("  全部通过")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
