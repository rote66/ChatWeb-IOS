#!/usr/bin/env python3
import re
import subprocess

path = "build/firefox-src/obj-gemini-gecko-ios-arm64/dist/bin/XUL"
lines = subprocess.run(
    ["nm", "-n", "-C", path], capture_output=True, text=True, check=True
).stdout.splitlines()

symbols = []
for line in lines:
    m = re.match(r"^([0-9a-fA-F]+) ([tT]) (.+)$", line)
    if m:
        symbols.append((int(m.group(1), 16), m.group(3)))

rows = []
for i, (addr, name) in enumerate(symbols[:-1]):
    size = symbols[i + 1][0] - addr
    if 0 < size < 2_000_000:
        rows.append((size, name))

groups = {
    "Warp frontend": re.compile(
        r"js::jit::(?:Warp|TrialInlining)|\bWarp(?:Builder|Oracle|Snapshot|CacheIR)"
    ),
    "Ion explicit": re.compile(
        r"js::jit::(?:Ion(?:Compile|Optimization|Analysis|IC|CacheIR|Script|Builder)|"
        r"CanEnterIon|LinkIonScript|LazyLinkTopActivation|OptimizeMIR)"
    ),
    "JS MIR/LIR backend": re.compile(
        r"js::jit::(?:MIR|LIR|CodeGenerator|Lowering|RegisterAllocator|"
        r"BacktrackingAllocator|RangeAnalysis|ScalarReplacement|ValueNumbering|"
        r"AliasAnalysis|LICM|DominatorTree|BranchPruning|Sink|UnrollLoops|"
        r"InstructionReordering|EffectiveAddressAnalysis|FoldTests|"
        r"FoldLinearArithConstants|TypeAnalysis|TypePolicy|Recover|Safepoint)"
    ),
    "Baseline": re.compile(r"js::jit::(?:Baseline|ICStub|ICFallbackStub)"),
    "CacheIR generic": re.compile(r"js::jit::(?:CacheIR|ICCacheIR)"),
    "MacroAssembler/Jit core": re.compile(
        r"js::jit::(?:MacroAssembler|Assembler|JitRuntime|JitCode|JitActivation|"
        r"JitFrame|JSJitFrameIter|Trampoline|ExecutableAllocator|Linker)"
    ),
    "Wasm namespace": re.compile(r"js::wasm::"),
}

for label, regex in groups.items():
    matches = [(size, name) for size, name in rows if regex.search(name)]
    total = sum(size for size, _ in matches)
    print(f"{label}: {total / 1048576:.3f} MiB ({len(matches)} symbols)")
    for size, name in sorted(matches, reverse=True)[:12]:
        print(f"  {size / 1024:7.1f} KiB  {name[:180]}")
    print()
