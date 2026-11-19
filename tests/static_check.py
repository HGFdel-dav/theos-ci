#!/usr/bin/env python3
"""Static guard for the Insulation sunlight-dimming adapter (local, no build).

Asserts the locked scope in src/ISDisplayPolicy.h + src/ISDisplayRuntime.m:
one hook only, exact ABI, exact UUIDs, bounded main-thread logging, read-only
plist probe, no plist/prefs write, no process kill, no CFBoolean/GOT patching,
no path that turns 0 into 100, and that the rh5 patch table / disasm notes were
not touched. Exit code 0 = all checks passed.
"""
from __future__ import annotations
import hashlib
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
H = (ROOT / "src/ISDisplayPolicy.h").read_text()
M = (ROOT / "src/ISDisplayRuntime.m").read_text()
BOTH = H + "\n" + M

DAEMON_UUID = "32752d2d-270d-378c-b50f-613a45261357"
CORE_UUID = "b05c6dcc-1c2f-52c6-8c43-600f34f52d0e"
DAEMON_BYTES = [0x32,0x75,0x2d,0x2d,0x27,0x0d,0x37,0x8c,0xb5,0x0f,0x61,0x3a,0x45,0x26,0x13,0x57]
CORE_BYTES = [0xb0,0x5c,0x6d,0xcc,0x1c,0x2f,0x52,0xc6,0x8c,0x43,0x60,0x0f,0x34,0xf5,0x2d,0x0e]

results: list[tuple[str, bool, str]] = []


def check(name: str, ok: bool, detail: str = "") -> None:
    results.append((name, ok, detail))


def forbid(tokens, where, label):
    hits = [t for t in tokens if t in where]
    check(label, not hits, "found: " + repr(hits) if hits else "none present")


def strip_comments(text: str) -> str:
    """Remove // and /* */ comments, leaving string literals intact."""
    out, i, n = [], 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            out.append(c)
            i += 1
            while i < n:
                out.append(text[i])
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                i += 1
            continue
        if text.startswith("//", i):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        out.append(c)
        i += 1
    return "".join(out)


CODE_H = strip_comments(H)
CODE_M = strip_comments(M)
CODE_BOTH = CODE_H + "\n" + CODE_M


def byte_array(text: str, var: str):
    m = re.search(re.escape(var) + r"\[16\]\s*=\s*\{(.*?)\}", text, re.S)
    if not m:
        return None
    return [int(x, 16) for x in re.findall(r"0x([0-9a-fA-F]{2})", m.group(1))]


# ---- S01..S02: exactly one hook, and it is the setter ----------------------
check("S01 single hooker call", len(re.findall(r"\bhooker\s*\(", M)) == 1,
      f"hooker( occurrences={len(re.findall(r'hooker', M))-2}")
check("S02 hooked SEL is setBrightnessKey:value:",
      len(re.findall(r'sel_registerName\("setBrightnessKey:value:"\)', M)) == 1
      and "defaultAction" not in M and "ISDActionReplacement" not in M
      and re.search(r"hooker\(single,\s*setter,", M) is not None,
      "setter only; defaultAction absent")
forbid(["MSHookFunction", "method_setImplementation", "class_replaceMethod",
        "class_addMethod", "MSHookIvar", "MSHookClassPair"],
       M, "S02b no alternative hook mechanism")

# ---- S03: ABI -------------------------------------------------------------
abi_calls = re.findall(r'ISDTypes\(\s*(\w+),\s*"([^"]+)",\s*(\d+)\s*\)', CODE_M)
check("S03 exactly one ABI assertion, on the setter",
      abi_calls == [("ms", "v28@0:8@16i24", "4")],
      f"ISDTypes calls={abi_calls}")
check("S03b ABI literal is the setter encoding",
      len(re.findall(r'"v28@0:8@16i24"', CODE_M)) == 1
      and "v28@0:8@16i24" in M, "quoted once in code, documented in header comment")
check("S03c no other method type encoding hooked",
      re.findall(r'"v\d+@0:8[^"]*"', CODE_M) == ['"v28@0:8@16i24"']
      and "v16@0:8" not in CODE_M,
      "no defaultAction/init encodings")

# ---- S04: UUIDs -----------------------------------------------------------
check("S04 daemon UUID bytes", byte_array(M, "ISDDaemonUUID") == DAEMON_BYTES,
      str(byte_array(M, "ISDDaemonUUID")))
check("S04b core UUID bytes", byte_array(M, "ISDCoreUUID") == CORE_BYTES,
      str(byte_array(M, "ISDCoreUUID")))
check("S04c canonical UUID text present",
      DAEMON_UUID in M and CORE_UUID in M, "both strings documented")
check("S04d exactly two 16-byte UUID arrays",
      len(re.findall(r"uint8_t\s+ISD\w+UUID\[16\]", M)) == 2,
      f"count={len(re.findall(r'uint8_t\\s+ISD\\w+UUID\\[16\\]', M))}")
check("S04e progname gate", 'strcmp(getprogname(), "thermalmonitord")' in M,
      "thermalmonitord only")
check("S04f LC_UUID walk + dladdr used",
      "LC_UUID" in M and "dladdr(" in M, "image identity verified twice")

# ---- S05: bounded, main-thread-only logging -------------------------------
check("S05 log budget constant 64",
      re.search(r"#define\s+ISD_LOG_BUDGET\s+64\b", H) is not None,
      "ISD_LOG_BUDGET == 64")
check("S05b budget actually enforced",
      "ISDLogRemaining" in M and "atomic_compare_exchange_weak_explicit" in M,
      "atomic claim, decrement per line")
check("S05c every os_log is behind the claim",
      M.count("os_log_with_type(") == M.count("if (!ISDClaimLog()) return;"),
      f"os_log={M.count('os_log_with_type(')} guards={M.count('if (!ISDClaimLog()) return;')}")
check("S05d main-thread gate", "pthread_main_np()" in M and "ISDMainThread()" in M,
      "pthread_main_np in ISDClaimLog")
check("S05e required startup events",
      all(e in M for e in ["ready", "inactive-missing-core", "inactive-core-version",
                           "inactive-unsupported-ABI", "inactive-conflicting-hook"]),
      "5/5 present")
check("S05f cap + restore events",
      '"cap-adjust"' in M and '"restore"' in M and '"enable-reconcile"' in M,
      "cap/restore logged")

# ---- S06: read-only probe ------------------------------------------------
check("S06 plist opened read-only",
      "O_RDONLY" in M and not re.search(r"O_WRONLY|O_RDWR|O_CREAT|O_TRUNC", M),
      "open(path, O_RDONLY)")
check("S06b immutable property list",
      "kCFPropertyListImmutable" in M and "CFPropertyListWrite" not in M,
      "no plist serialization")
check("S06c probe reads the three values",
      all(k in M for k in ["maxThermalPower", "minThermalPower", "expectsCPMSSupport"]),
      "3/3 keys")
check("S06d sysctl is a read",
      re.search(r'sysctlbyname\("hw\.model",\s*model,\s*&len,\s*NULL,\s*0\)', M) is not None,
      "newp==NULL")
forbid(["CFPreferencesSet", "CFPreferencesAppSynchronize", "CFPreferencesSetAppValue",
        "writeToFile", "NSUserDefaults", "CFPropertyListWriteToStream",
        "setObject:forKey:", "PlistBuddy"],
       BOTH, "S06e no preference/plist write")

# ---- S07: no process control --------------------------------------------
forbid(["kill(", "SIGKILL", "SIGTERM", "launchctl", "posix_spawn", "execve",
        "execvp", "system(", "popen("],
       BOTH, "S07 no kill/relaunch/spawn")

# ---- S08: no CFBoolean / GOT patching -----------------------------------
bool_tokens = set(re.findall(r"CFBoolean\w*", CODE_M))
check("S08 CFBoolean only read",
      bool_tokens <= {"CFBooleanGetTypeID", "CFBooleanGetValue", "CFBooleanRef"},
      f"code tokens={sorted(bool_tokens)}")
forbid(["kCFBooleanTrue", "kCFBooleanFalse", "_GOT", "GOT[", "got_slot"],
       BOTH, "S08b no CFBoolean/GOT write")

# ---- S09: no 0 -> 100 path ---------------------------------------------
body = re.search(r"static inline int ISDResolve\(int requested, bool enabled\) \{(.*?)\n\}",
                 H, re.S)
check("S09 resolve body found", body is not None, "")
if body:
    b = body.group(1)
    check("S09b single 100-return site", b.count("ISD_CAP_PERCENT") == 1,
          f"count={b.count('ISD_CAP_PERCENT')}")
    check("S09c disabled passes through first", "if (!enabled) return requested;" in b, "")
    check("S09d lower bound 1 / upper bound 99 enforced",
          "requested < ISD_MIN_CAPPED || requested > ISD_MAX_CAPPED" in b
          and re.search(r"#define\s+ISD_MIN_CAPPED\s+1\b", H) is not None
          and re.search(r"#define\s+ISD_MAX_CAPPED\s+99\b", H) is not None, "")
    check("S09e no ternary to the cap", "? ISD_CAP_PERCENT" not in BOTH and "? 100" not in BOTH, "")
check("S09f cap constant is 100",
      re.search(r"#define\s+ISD_CAP_PERCENT\s+100\b", H) is not None, "")

# ---- S10: switch symbol ------------------------------------------------
check("S10 switch symbol is the T export",
      M.count("InsulationThermalDimmingBypassActive") == 1
      and "InsulationDisplayDimmingBypassEnabled" not in BOTH,
      "InsulationThermalDimmingBypassActive only")
check("S10b reader ABI bool(*)(void)",
      re.search(r"typedef bool \(\*ISDEnabledReader\)\(void\)", M) is not None
      and 'dlsym(RTLD_DEFAULT, ISD_ENABLED_SYMBOL)' in M, "")

# ---- S11: instance isolation / keys ------------------------------------
check("S11 exact-class instance check",
      "object_getClass(object) == ISDControllerClass" in M, "no isKindOfClass")
check("S11b only the two keys", 'isEqualToString:@"MaxBrightness"' in M
      and 'isEqualToString:@"BrightnessWeakCap"' in M
      and len(re.findall(r"isEqualToString:@", M)) == 2, "2/2 keys")
check("S11c per-instance state via associated object",
      "objc_setAssociatedObject" in M and "OBJC_ASSOCIATION_RETAIN" in M, "")

# ---- S12: rh5 patch table / disasm untouched ---------------------------
base = ROOT / "tests/baseline.sha256"
bad = []
if base.exists():
    for line in base.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        want, _, rel = line.partition(" ")
        if not re.fullmatch(r"[0-9a-f]{64}", want):
            continue
        p = ROOT / rel.strip()
        got = hashlib.sha256(p.read_bytes()).hexdigest() if p.exists() else "missing"
        if got != want:
            bad.append(rel.strip())
check("S12 read-only inputs unchanged", not bad, f"changed={bad}" if bad else "hash match")
patch = (ROOT / "reference/published-patch.txt").read_text()
entries = re.findall(r"^\s*\('arm64e?'", patch, re.M)
check("S12b rh5 table still 18 entries", len(entries) == 18, f"entries={len(entries)}")
check("S12c 600 constant still in table (not rewritten)",
      patch.count("0x52804b00") == 2 and "0.1.38.1-rh5" in patch,
      "4 backlight patches intact")

# ---- report -----------------------------------------------------------
failed = [r for r in results if not r[1]]
for i, (name, ok, detail) in enumerate(results, 1):
    print(f"{'PASS' if ok else 'FAIL'} {i:02d}: {name}" + (f"  [{detail}]" if detail else ""))
print(f"\n{len(results)} checks, {len(failed)} failed")
if failed:
    print("FAILED: " + ", ".join(n for n, _, _ in failed))
sys.exit(1 if failed else 0)
