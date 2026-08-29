#!/usr/bin/env python3
import re
import subprocess

p = "build/firefox-src/obj-gemini-gecko-ios-arm64/dist/bin/XUL"
lines = subprocess.run(["nm", "-n", "-C", p], capture_output=True, text=True, check=True).stdout.splitlines()

symbols_by_address = {}
for line in lines:
    m = re.match(r"^([0-9a-fA-F]+) ([tT]) (.+)$", line)
    if m:
        symbols_by_address.setdefault(int(m.group(1), 16), []).append(m.group(3))

rows = []
symbols = sorted(symbols_by_address.items())
for i, (addr, names) in enumerate(symbols[:-1]):
    size = symbols[i + 1][0] - addr
    if 0 < size < 2_000_000:
        rows.append((size, names))

patterns = {
    "Glean/Telemetry": ["glean", "telemetry", "fog::"],
    "Profiler": ["profiler", "profiling"],
    "PDF": ["pdfjs", "pdfium", "pdf::", "pdfviewer"],
    "DevTools/Heap": ["heapsnapshot", "dominatortree", "devtools"],
    "WebExtensions/Addons": ["webextension", "extensionparent", "addon", "webext"],
    "Sync/ApplicationServices": ["sync15", "remote_settings", "suggest::", "relevancy", "tabs::", "logins::", "application_services"],
    "SafeBrowsing/URLClassifier": ["urlclassifier", "lookupcache", "hashstore", "safebrows", "classifier::"],
    "WebAuthn": ["webauthn", "authenticator", "ctap", "u2f"],
    "Payments": ["paymentrequest", "paymentresponse", "paymentmethod"],
    "GMP/EME/DRM": [
        "mozilla::gmp::",
        "gmpchild",
        "gmpparent",
        "gmpservice",
        "gmpvideo",
        "mediakey",
        "chromiumcdm",
        "cdmproxy",
        "mozilla::eme::",
    ],
    "ServiceWorker": ["serviceworker"],
    "Push/Notification": ["pushservice", "pushmanager", "notification"],
    "WebTransport/HTTP3": [
        "webtransport",
        "http3",
        "neqo_http3",
        "neqo_transport",
        "neqo_qpack",
        "qlog::",
    ],
    "MathML": ["mathml"],
    "Spellcheck": ["spellcheck", "hunspell"],
    "Accessibility": ["accessibility", "accessible", "a11y"],
    "Printing": ["printjob", "printsettings", "nsprint", "printing"],
    "WebGPU": ["wgpu", "naga", "webgpu"],
    "WebGL": ["webgl"],
    "WebAudio": ["webaudio", "audiocontext", "audionode", "audioworklet"],
    "WebCodecs": ["webcodecs", "videoframe", "audiodecoder", "videoencoder"],
    "WebXR/VR": ["webxr", "xrsession", "xrframe", "vrmanager", "vrdisplay"],
    "Temporal": ["temporal"],
    "WebRender": ["webrender"],
    "WebRTC": ["webrtc", "libwebrtc"],
    "Media": ["media", "video", "audio"],
    "SpiderMonkey JIT": [
        "js::jit::",
        "warpbuilder",
        "warporacle",
        "warpsnapshot",
        "warpcacheir",
        "cacheir",
        "baselinecompiler",
        "baselineinterpreter",
    ],
    "WebAssembly": ["js::wasm::", "wasm::", "wasm"],
    "Stylo/Servo CSS": ["style::", "servo", "cssparser"],
    "DOM/Layout": ["mozilla::dom::", "mozilla::pres", "layout", "nsframe", "nsdisplay"],
    "Networking": ["mozilla::net::", "necko", "httpchannel", "nshttp"],
    "Image": ["mozilla::image", "image::", "imgloader", "imgrequest"],
}

for label, needles in patterns.items():
    total = sum(
        size
        for size, names in rows
        if any(needle in name.lower() for name in names for needle in needles)
    )
    print(f"{label}: {total / 1048576:.2f} MiB")

print("--- top symbols ---")
for size, names in sorted(rows, reverse=True)[:100]:
    aliases = " | ".join(names)
    print(f"{size / 1024:.1f} KiB {aliases[:180]}")
