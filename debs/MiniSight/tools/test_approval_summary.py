#!/usr/bin/env python3
"""Host-only regression tests for the bounded approval summary parser."""
import argparse
import json
import pathlib
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
CLI_SRC = ROOT / "tests" / "approval" / "summary_cli.c"

CASES = [
    ("grep-sort-pipeline", 'grep -a -o -E "x" /tmp/extensions.json 2>/dev/null | sort -u || true', 0, 0, "排序去重"),
    ("find-read", "find /var/mobile -type f -name extensions.json", 0, 0, "查找"),
    ("find-delete", "find /var/mobile -type f -name extensions.json -delete", 0, 1, "删除"),
    ("find-exec", "find /var/mobile -type f -name extensions.json -exec rm -f {} \\\\;", 1, 1, "无法"),
    ("find-fprint", "find /var/mobile -type f -name extensions.json -fprint /tmp/found", 0, 1, "写入"),
    ("sort-only", "sort /tmp/x", 0, 0, "排序；"),
    ("sort-unique", "sort -u /tmp/x", 0, 0, "排序去重"),
    ("redirect-write", "grep x /tmp/x > /tmp/out", 0, 1, "写入"),
    ("unknown", "getent passwd", 1, 1, "无法"),
    ("noop", "true", 0, 0, "辅助"),
    ("direct-read-tool", "minis-mcp-cli call 越狱mcp get_device_info", 0, 0, "设备"),
    ("direct-write-tool", "minis-mcp-cli call 越狱mcp write_file path=/tmp/x content=x", 0, 1, "写入"),
    ("nested-json", "minis-mcp-cli call 越狱mcp run_command --input '{\"command\":\"grep x /tmp/x 2>/dev/null | sort -u || true\"}'", 0, 0, "排序去重"),
]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--cc", default="cc")
    args = ap.parse_args()
    with tempfile.TemporaryDirectory() as td:
        exe = pathlib.Path(td) / "summary_cli"
        subprocess.run([
            args.cc, "-std=c11", "-O2", "-Wall", "-Wextra", "-Werror", "-pedantic",
            "-I", str(ROOT), str(CLI_SRC), "-o", str(exe),
        ], check=True)
        for name, command, expected_unknown, expected_write, phrase in CASES:
            result = subprocess.run([str(exe), command], check=True, text=True, capture_output=True)
            obj = json.loads(result.stdout)
            assert obj["unknown"] == expected_unknown, (name, obj)
            assert obj["is_write"] == expected_write, (name, obj)
            assert phrase in obj["title"] + obj["purpose"], (name, obj)
            assert "完整命令" not in obj["purpose"], (name, obj)
            print("PASS", name)
    print(f"approval summary cases: {len(CASES)} PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
