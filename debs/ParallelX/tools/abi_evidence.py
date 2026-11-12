#!/usr/bin/env python3
"""Regenerate alpha391 ABI evidence from the pristine vendor dylib.

Outputs are read-only analysis: selector refs, objc call sites, and annotated
disassembly for the functions named by the handoff. No binary modification.
"""
import hashlib
import json
import os
import struct
import subprocess
import sys

import lief
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM, CS_OP_MEM
from capstone.arm64_const import ARM64_REG_X0, ARM64_REG_X1, ARM64_REG_X2, ARM64_REG_X3, ARM64_REG_X17

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BINARY = os.path.join(ROOT, "vendor/alpha391/Library/MobileSubstrate/DynamicLibraries/ParallelX.dylib")
OUT = os.path.join(ROOT, "evidence/abi")
FUNCTIONS = {
    "function_b81c.txt": (0xB81C, 0xBACC),
    "function_bacc.txt": (0xBACC, 0xBC18),
    "function_bdf4.txt": (0xBDF4, 0xC394),
    "function_2971c.txt": (0x2971C, 0x29920),
    "configured_action.txt": (0x63DC8, 0x64000),
    "activated_entry.txt": (0x293D8, 0x29440),
    "open_native.txt": (0x65FC8, 0x66100),
}


def load():
    blob = open(BINARY, "rb").read()
    image = lief.parse(BINARY)
    return blob, image


def section(image, name):
    for candidate in image.sections:
        if candidate.name == name:
            return candidate
    raise SystemExit(f"missing section {name}")


def main():
    blob, image = load()
    digest = hashlib.sha256(blob).hexdigest()

    selectors = {}
    methname = section(image, "__objc_methname")
    selrefs = section(image, "__objc_selrefs")
    for index in range(0, selrefs.size, 8):
        value = struct.unpack_from("<Q", blob, selrefs.offset + index)[0]
        target = value & ((1 << 43) - 1)
        if methname.virtual_address <= target < methname.virtual_address + methname.size:
            selectors[selrefs.virtual_address + index] = \
                blob[target:].split(b"\0")[0].decode("utf-8", "replace")

    # Resolve objc_msgSend/objc_msgSendSuper stubs from chained imports.
    stub_map = {}
    stubs = section(image, "__auth_stubs")
    bindings = {}
    for command in image.commands:
        if command.command == lief.MachO.LoadCommand.TYPE.DYLD_CHAINED_FIXUPS:
            for binding in command.bindings:
                if binding.has_symbol:
                    bindings[binding.address] = binding.symbol.name

    decoder = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    decoder.detail = True
    for offset in range(0, stubs.size, 16):
        instructions = list(decoder.disasm(blob[stubs.offset + offset:stubs.offset + offset + 16],
                                          stubs.virtual_address + offset))
        if len(instructions) < 4 or instructions[0].mnemonic != "adrp":
            continue
        page = instructions[0].operands[1].imm
        delta = instructions[1].operands[2].imm if instructions[1].mnemonic == "add" else 0
        symbol = bindings.get(page + delta)
        if symbol in ("_objc_msgSend", "_objc_msgSendSuper2"):
            stub_map[stubs.virtual_address + offset] = symbol

    text = section(image, "__text")
    instructions = list(decoder.disasm(blob[text.offset:text.offset + text.size],
                                       text.virtual_address))
    calls = []
    starts = [item.address for item in instructions if item.mnemonic == "pacibsp"]
    current = 0
    for index, instruction in enumerate(instructions):
        while current + 1 < len(starts) and starts[current + 1] <= instruction.address:
            current += 1
        if instruction.mnemonic not in ("blraa", "bl") or not instruction.operands:
            continue
        target = instruction.operands[0].imm
        if target not in stub_map:
            continue
        selector = None
        for back in range(index - 1, max(-1, index - 8), -1):
            probe = instructions[back]
            if probe.mnemonic != "ldr" or len(probe.operands) < 2:
                continue
            memory = probe.operands[1]
            if memory.type != CS_OP_MEM:
                continue
            base = memory.mem.base
            if not base:
                continue
            for deeper in range(back - 1, max(-1, back - 6), -1):
                page_insn = instructions[deeper]
                if page_insn.mnemonic == "adrp" and page_insn.operands[0].reg == base:
                    address = page_insn.operands[1].imm + memory.mem.disp
                    selector = selectors.get(address)
                    break
            break
        if selector:
            calls.append({"address": instruction.address,
                          "function": starts[current] if starts else 0,
                          "selector": selector})

    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "selector_stubs391.json"), "w") as handle:
        json.dump({"binary_sha256": digest,
                   "image": "ParallelX.dylib",
                   "selectors": {hex(k): v for k, v in sorted(selectors.items())}},
                  handle, ensure_ascii=False, indent=2)
    with open(os.path.join(OUT, "objc_calls391.json"), "w") as handle:
        json.dump({"binary_sha256": digest,
                   "image": "ParallelX.dylib",
                   "calls": [{"address": hex(x["address"]),
                              "function": hex(x["function"]),
                              "selector": x["selector"]} for x in calls]},
                  handle, ensure_ascii=False, indent=2)

    header = f"# ParallelX.dylib sha256 {digest}\n# arm64e, offsets are vmaddr\n"
    for name, (start, stop) in FUNCTIONS.items():
        with open(os.path.join(OUT, name), "w") as handle:
            handle.write(header)
            handle.write(subprocess.run(
                [sys.executable, os.path.join(ROOT, "tools", "annotate_one.py"), BINARY,
                 hex(start), hex(stop)], capture_output=True, text=True).stdout)

    with open(os.path.join(OUT, "annotated391.txt"), "w") as handle:
        handle.write(header)
        handle.write(subprocess.run(["llvm-objdump", "--arch=arm64e", "-d", BINARY],
                                    capture_output=True, text=True).stdout)
    print("selectors", len(selectors), "calls", len(calls), "sha256", digest)


if __name__ == "__main__":
    main()
