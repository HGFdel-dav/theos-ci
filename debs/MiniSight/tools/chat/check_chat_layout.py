#!/usr/bin/env python3
"""Run the floating chat geometry contract on the host, using only the C SDK.

Usage: python3 tools/chat/check_chat_layout.py [--cc cc]
Builds in a temporary directory; does not run Theos, Xcode, a device or git.
The test checks exact placement examples, containment, non-overlap, dimensions,
keyboard/rotation, nonfinite inputs and 4096 reproducible random layouts.
"""
import argparse
import pathlib
import shutil
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cc", default="cc", help="host C compiler (default: cc)")
    args = parser.parse_args()
    compiler = shutil.which(args.cc)
    if not compiler:
        raise RuntimeError("host C compiler not found: " + args.cc)
    flags = ["-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", "-O2"]
    with tempfile.TemporaryDirectory(prefix="minisight-chat-layout-") as tmp:
        binary = pathlib.Path(tmp) / "chat_layout_test"
        command = [compiler, *flags, str(ROOT / "tests/chat/chat_layout_test.c"),
                   "-lm", "-o", str(binary)]
        build = subprocess.run(command, capture_output=True, text=True, timeout=60)
        if build.stdout:
            print(build.stdout, end="")
        if build.stderr:
            print(build.stderr, end="", file=sys.stderr)
        if build.returncode:
            raise RuntimeError("host C11 build failed (exit %d)" % build.returncode)
        print("host C11: " + args.cc + " " + " ".join(flags) + " -lm: PASS", flush=True)
        run = subprocess.run([str(binary)], capture_output=True, text=True, timeout=30)
        print(run.stdout, end="", flush=True)
        if run.stderr:
            print(run.stderr, end="", file=sys.stderr)
        if run.returncode or "checks passed" not in run.stdout:
            raise RuntimeError("geometry contract failed (exit %d)" % run.returncode)
    print("check_chat_layout: PASS (local host only)")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, RuntimeError, subprocess.TimeoutExpired) as error:
        print("check_chat_layout: FAIL: " + str(error), file=sys.stderr)
        sys.exit(1)
