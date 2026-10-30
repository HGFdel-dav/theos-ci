#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""用手机导出的真实 news.plist 验证「下载地址构造 + 落盘命名」，并对真实源做 HTTP 校验。

- 用 C 语言调用与插件同一份 DNBLogic.h（不是重写一遍逻辑）
- HEAD 抽查若干真实 URL，再挑一个体积小的真下下来验 deb 魔术字节
用法：python3 tests/news_sample_test.py [news.plist 路径]
"""
import os
import plistlib
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC_DIR = os.path.join(ROOT, "DebsNewsBatch")
NEWS = sys.argv[1] if len(sys.argv) > 1 else "/var/minis/workspace/debs-news/device-read/news.plist"
CASE_LIMIT = 12
HEAD_LIMIT = 5
MAX_GET_BYTES = 3 * 1024 * 1024


def c_escape(text):
    return (text or "").replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def main():
    with open(NEWS, "rb") as fh:
        news = plistlib.load(fh)
    print("样本新闻条目：%d 条" % len(news))

    cases = []
    for item in news:
        pkg = item.get("package") or {}
        src = item.get("source") or {}
        url = src.get("url") or {}
        base = url.get("relative") or ""
        rel = pkg.get("filename") or ""
        if not base or not rel:
            continue
        expected = base.rstrip("/") + "/" + rel.lstrip("/") if not rel.startswith("http") else rel
        cases.append({
            "base": base, "rel": rel, "expected": expected,
            "name": pkg.get("name") or "", "version": pkg.get("version") or "",
            "arch": pkg.get("architecture") or "",
        })
    print("可构造下载地址的条目：%d 条" % len(cases))
    if not cases:
        print("没有可用样本")
        return 1
    cases = cases[:CASE_LIMIT]

    lines = ['#include <stdio.h>', '#include <string.h>', '#include "DNBLogic.h"', 'static int pass=0, fail=0;',
             '#define OK(c,m) do{ if(c){pass++;} else {fail++; printf("  x %s\\n", m);} }while(0)', 'int main(void){',
             '  char url[2048]; char name[512];']
    for idx, case in enumerate(cases):
        lines.append('  /* case %d: %s */' % (idx, c_escape(case["name"])[:40]))
        lines.append('  OK(dnblogic_join_url(url,sizeof url,"%s","%s")==1, "join_url 返回失败");'
                     % (c_escape(case["base"]), c_escape(case["rel"])))
        lines.append('  OK(strcmp(url,"%s")==0, "join_url 结果不符");' % c_escape(case["expected"]))
        lines.append('  OK(strncmp(url,"http",4)==0, "URL 不是 http(s)");')
        lines.append('  OK(dnblogic_save_name(name,sizeof name,"%s","%s","%s")==1, "save_name 失败");'
                     % (c_escape(case["name"]), c_escape(case["version"]), c_escape(case["arch"])))
        lines.append('  { size_t n=strlen(name); OK(n>4 && strcmp(name+n-4,".deb")==0, "落盘名不以 .deb 结尾");'
                     ' OK(strchr(name,(int)47)==NULL, "落盘名含斜杠"); }')
    lines.append('  printf("真实数据用例：通过 %d 项，失败 %d 项\\n", pass, fail);')
    lines.append('  return fail ? 1 : 0;')
    lines.append('}')
    c_path = "/tmp/dnb_real_cases.c"
    with open(c_path, "w") as fh:
        fh.write("\n".join(lines) + "\n")

    proc = subprocess.run(["cc", "-Wall", "-Wextra", "-Werror", "-I", SRC_DIR, c_path, "-o", "/tmp/dnb_real_cases"],
                          capture_output=True, text=True)
    if proc.returncode != 0:
        print("生成用例编译失败：\n" + proc.stderr[-600:])
        return 1
    run = subprocess.run(["/tmp/dnb_real_cases"], capture_output=True, text=True)
    print(run.stdout.strip())
    if run.returncode != 0:
        print(run.stderr.strip()[-400:])
        return 1

    # ---- 真实源 HTTP 抽查 ----
    print("\n真实源抽查（HEAD，不下载）：")
    ok_urls = []
    for case in cases[:HEAD_LIMIT]:
        proc = subprocess.run(["curl", "-sS", "-I", "-L", "--max-time", "25", case["expected"]],
                              capture_output=True, text=True)
        head = proc.stdout
        status = ""
        length = 0
        ctype = ""
        for line in head.splitlines():
            low = line.lower()
            if low.startswith("http/"):
                status = line.split()[1] if len(line.split()) > 1 else "?"
            elif low.startswith("content-length:"):
                try:
                    length = int(line.split(":", 1)[1].strip())
                except ValueError:
                    length = 0
            elif low.startswith("content-type:"):
                ctype = line.split(":", 1)[1].strip()
        tag = "OK " if status in ("200", "206") else "!! "
        print("  %s %s  HTTP %s  %s  %d 字节" % (tag, case["name"][:18], status or "无响应", ctype[:24], length))
        if status in ("200", "206") and length > 100:
            ok_urls.append((length, case))

    if not ok_urls:
        print("  没有任何样本能取到文件（源可能已删档，属正常现象）")
        return 0

    ok_urls.sort()
    size, case = ok_urls[0]
    if size > MAX_GET_BYTES:
        print("  最小样本 %d 字节偏大，跳过实际下载校验" % size)
        return 0

    print("\n实际下载一个最小样本验证内容：")
    out = "/tmp/dnb_sample.deb"
    proc = subprocess.run(["curl", "-sS", "-L", "--max-time", "120", "-o", out, case["expected"]],
                          capture_output=True, text=True)
    if proc.returncode != 0 or not os.path.exists(out):
        print("  下载失败：%s" % proc.stderr.strip()[-200:])
        return 1
    with open(out, "rb") as fh:
        magic = fh.read(8)
    real = os.path.getsize(out)
    good = magic == b"!<arch>\n"
    print("  %s  %s  落盘名 %s  大小 %d 字节  魔术字节 %r" % (
        "OK " if good else "!! ", case["name"][:20],
        (case["name"] + "-" + case["version"] + "-" + case["arch"] + ".deb")[:44], real, magic))
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
