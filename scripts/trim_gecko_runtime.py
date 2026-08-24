#!/usr/bin/env python3
"""Trim Firefox-product resources from the staged UIKit Gecko runtime.

This runs only on the disposable staging tree.  It deliberately keeps Gecko's
web platform, networking/security resources, GeckoView chrome, prompt/download
paths, and the password-form actor used by Google login.  The removed pieces
are Firefox browser UI or features explicitly deferred for Gemini phase two.
"""

from __future__ import annotations

import shutil
import sys
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"trim_gecko_runtime: {message}")


if len(sys.argv) != 2:
    fail("usage: trim_gecko_runtime.py STAGE_DIR")

root = Path(sys.argv[1]).resolve()
if not (root / "XUL").is_file():
    fail(f"missing XUL in {root}")


def remove(rel: str) -> None:
    path = root / rel
    if path.is_dir() and not path.is_symlink():
        shutil.rmtree(path)
    elif path.exists() or path.is_symlink():
        path.unlink()


def prune_tree(rel: str, keep_files: set[str], keep_prefixes: tuple[str, ...]) -> None:
    base = root / rel
    if not base.is_dir():
        return
    for path in sorted(base.rglob("*"), reverse=True):
        if path.is_dir():
            continue
        name = path.relative_to(base).as_posix()
        if name in keep_files or any(name.startswith(prefix) for prefix in keep_prefixes):
            continue
        path.unlink()
    for path in sorted((p for p in base.rglob("*") if p.is_dir()), reverse=True):
        try:
            path.rmdir()
        except OSError:
            pass


# GeckoView delayed startup normally initializes Firefox add-on blocklisting,
# captcha telemetry and several optional GeckoView product modules.  The slim
# runtime does not ship those browser-product layers.  Remove their startup
# hooks so there are no dangling lazy imports.
geckoview = root / "chrome/geckoview/content/geckoview.js"
text = geckoview.read_text()

# DualAI's UIKit embedding runs without BrowserEngineKit content-process
# extensions on iOS 15.  When the host requests useRemoteProcess=false, make
# the inner GeckoView <browser> in-process as well so it owns a real docshell
# instead of a hollow remote BrowsingContext with frameLoader.remoteTab == nil.
needle = "    const browser = createBrowser(this.settings);\n"
replacement = (
    "    const browser = createBrowser(\n"
    "      this.settings,\n"
    "      initData.useRemoteProcess !== false\n"
    "    );\n"
)
if needle not in text:
    fail("unable to locate GeckoView createBrowser call")
text = text.replace(needle, replacement, 1)

needle = "function createBrowser(settings) {\n"
if needle not in text:
    fail("unable to locate GeckoView createBrowser definition")
text = text.replace(
    needle,
    "function createBrowser(settings, useRemoteProcess = true) {\n",
    1,
)

remote_block = '''  browser.setAttribute("maychangeremoteness", "true");\n  browser.setAttribute("remote", "true");\n  browser.setAttribute(\n    "remoteType",\n    ChromeUtils.predictRemoteTypeForURI(null, {\n      window,\n      geckoViewSessionContextId: settings.sessionContextId ?? undefined,\n    })\n  );\n'''
remote_replacement = '''  if (useRemoteProcess) {\n    browser.setAttribute("maychangeremoteness", "true");\n    browser.setAttribute("remote", "true");\n    browser.setAttribute(\n      "remoteType",\n      ChromeUtils.predictRemoteTypeForURI(null, {\n        window,\n        geckoViewSessionContextId: settings.sessionContextId ?? undefined,\n      })\n    );\n  }\n'''
if remote_block not in text:
    fail("unable to locate GeckoView remote browser attribute block")
text = text.replace(remote_block, remote_replacement, 1)

for needle in (
    '  Blocklist: "resource://gre/modules/Blocklist.sys.mjs",\n',
    '  CaptchaDetectionPingUtils:\n    "resource://gre/modules/CaptchaDetectionPingUtils.sys.mjs",\n',
):
    if needle not in text:
        fail(f"expected GeckoView startup fragment not found: {needle!r}")
    text = text.replace(needle, "", 1)

for block in (
    '''    InitLater(() => {\n      // Initialize the blocklist module.\n      // TODO bug 1730026: this runs too often. It should run once.\n      Blocklist.loadBlocklistAsync();\n    });\n\n''',
    '''    InitLater(() => {\n      // Call the init function for the CaptchaDetectionPingUtils module.\n      // This function adds pref observers that flushes the ping. It also\n      // submits the ping if it has data and has been about 24 hours since the\n      // last submission.\n      CaptchaDetectionPingUtils.init();\n    });\n\n''',
):
    if block not in text:
        fail("expected GeckoView delayed-startup block not found")
    text = text.replace(block, "", 1)

# GeckoViewTab is WebExtension-facing glue.  It statically imports
# ExtensionUtils.sys.mjs and lazily imports GeckoViewWebExtension.sys.mjs,
# both of which are intentionally removed from the Phase-1 runtime below.
# Leaving this onInit module in the GeckoView module table aborts
# ModuleManager construction before GeckoViewNavigation.onInit() gets a chance
# to register GeckoView:LoadUri/Reload listeners.
start = text.find('    {\n      name: "GeckoViewTab",')
end = text.find('    {\n      name: "GeckoViewContentBlocking",', start)
if start < 0 or end < 0:
    fail("unable to locate GeckoViewTab module block")
text = text[:start] + text[end:]

# Media control, printing, experiments, translation and page extraction are
# outside phase one.  Print/experiment/translations/page-extractor form the
# tail of this module list, which makes this removal deterministic.
start = text.find('    {\n      name: "GeckoViewMediaControl",')
end = text.find('    {\n      name: "GeckoViewAutocomplete",', start)
if start < 0 or end < 0:
    fail("unable to locate GeckoViewMediaControl module block")
text = text[:start] + text[end:]

# Address/credit-card autocomplete is separate from GeckoViewAutoFill's
# password-form actor.  Gemini needs the latter for login forms, not the former.
start = text.find('    {\n      name: "GeckoViewAutocomplete",')
end = text.find('    {\n      name: "GeckoViewPrompter",', start)
if start < 0 or end < 0:
    fail("unable to locate GeckoViewAutocomplete module block")
text = text[:start] + text[end:]

start = text.find('    {\n      name: "GeckoViewPrintDelegate",')
end = text.find('  ]);', start)
if start < 0 or end < 0:
    fail("unable to locate optional GeckoView module tail")
text = text[:start] + text[end:]
geckoview.write_text(text)

# A non-remote GeckoView browser has a real parent-process docshell, but the
# Android-oriented SetFocused implementation calls browser.focus()/blur(). On
# the UIKit port that immediately enters the native text-input/first-responder
# path during startup and caused Build 30 to SIGSEGV before navigation could be
# delivered. Preserve GeckoView's primary-browser bookkeeping while allowing
# focus to arise naturally from user interaction for the in-process case.
content = root / "modules/GeckoViewContent.sys.mjs"
content_text = content.read_text()
focus_block = '''      case "GeckoView:SetFocused":\n        if (aData.focused) {\n          this.browser.focus();\n          this.browser.setAttribute("primary", "true");\n        } else {\n          this.browser.removeAttribute("primary");\n          this.browser.blur();\n        }\n        break;\n'''
focus_replacement = '''      case "GeckoView:SetFocused":\n        if (aData.focused) {\n          if (this.browser.isRemoteBrowser) {\n            this.browser.focus();\n          }\n          this.browser.setAttribute("primary", "true");\n        } else {\n          this.browser.removeAttribute("primary");\n          if (this.browser.isRemoteBrowser) {\n            this.browser.blur();\n          }\n        }\n        break;\n'''
if focus_block not in content_text:
    fail("unable to locate GeckoViewContent SetFocused block")
content_text = content_text.replace(focus_block, focus_replacement, 1)

# The Gemini "Google 相册" entry is a cross-origin Google Picker document,
# not the native nsIFilePicker path.  On UIKit it can currently create its
# bottom sheet while rendering a blank body.  Observe only that picker document
# in the staged GeckoView chrome module and report DOM/resource/JS state over
# the existing host-visible NavTrace bridge.  Keeping this in staged resources
# avoids baking temporary diagnostics into XUL.
picker_enable = '''    Services.obs.addObserver(this, "oop-frameloader-crashed");\n    Services.obs.addObserver(this, "ipc:content-shutdown");\n'''
picker_enable_replacement = '''    Services.obs.addObserver(this, "oop-frameloader-crashed");\n    Services.obs.addObserver(this, "ipc:content-shutdown");\n    Services.obs.addObserver(this, "document-element-inserted");\n'''
if picker_enable not in content_text:
    fail("unable to locate GeckoViewContent observer enable block")
content_text = content_text.replace(
    picker_enable, picker_enable_replacement, 1
)

picker_disable = '''    Services.obs.removeObserver(this, "oop-frameloader-crashed");\n    Services.obs.removeObserver(this, "ipc:content-shutdown");\n'''
picker_disable_replacement = '''    Services.obs.removeObserver(this, "oop-frameloader-crashed");\n    Services.obs.removeObserver(this, "ipc:content-shutdown");\n    Services.obs.removeObserver(this, "document-element-inserted");\n'''
if picker_disable not in content_text:
    fail("unable to locate GeckoViewContent observer disable block")
content_text = content_text.replace(
    picker_disable, picker_disable_replacement, 1
)

observer_header = '''  observe(aSubject, aTopic) {\n    debug`observe: ${aTopic}`;\n    this._contentCrashed = false;\n    const browser = aSubject.ownerElement;\n\n    switch (aTopic) {\n'''
observer_replacement = '''  observe(aSubject, aTopic) {\n    debug`observe: ${aTopic}`;\n    this._contentCrashed = false;\n\n    if (aTopic === "document-element-inserted") {\n      const doc = aSubject;\n      const href = doc?.documentURI ?? null;\n      if (href?.startsWith("https://docs.google.com/picker/v2/home")) {\n        const win = doc.defaultView;\n        const report = stage => {\n          try {\n            const body = doc.body;\n            const html = doc.documentElement;\n            const style = body && win ? win.getComputedStyle(body) : null;\n            const resources = win?.performance\n              ?.getEntriesByType("resource")\n              ?.slice(0, 20)\n              ?.map(entry => entry.name) ?? [];\n            const childSummary = body\n              ? Array.from(body.children)\n                  .slice(0, 12)\n                  .map(child => ({\n                    tag: child.localName,\n                    id: child.id || null,\n                    className:\n                      typeof child.className === "string"\n                        ? child.className.slice(0, 300)\n                        : null,\n                    textLength: child.innerText?.length ?? null,\n                    htmlLength: child.innerHTML?.length ?? null,\n                  }))\n              : [];\n            const frameSummary = Array.from(doc.querySelectorAll("iframe"))\n              .slice(0, 12)\n              .map(frame => ({\n                src: frame.src || null,\n                id: frame.id || null,\n                name: frame.name || null,\n                width: frame.getBoundingClientRect().width,\n                height: frame.getBoundingClientRect().height,\n              }));\n            const scriptSummary = Array.from(doc.scripts)\n              .slice(0, 12)\n              .map(script => ({\n                src: script.src || null,\n                type: script.type || null,\n                inlineLength: script.src ? 0 : script.textContent?.length ?? 0,\n              }));\n            const styleSummary = Array.from(doc.styleSheets)\n              .slice(0, 12)\n              .map(sheet => ({ href: sheet.href || null }));\n            this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n              stage,\n              uri: href,\n              readyState: doc.readyState,\n              title: doc.title,\n              bodyChildren: body?.childElementCount ?? null,\n              bodyTextLength: body?.innerText?.length ?? null,\n              htmlWidth: html?.scrollWidth ?? null,\n              htmlHeight: html?.scrollHeight ?? null,\n              display: style?.display ?? null,\n              visibility: style?.visibility ?? null,\n              opacity: style?.opacity ?? null,\n              scriptCount: doc.scripts?.length ?? null,\n              styleSheetCount: doc.styleSheets?.length ?? null,\n              resourceCount:\n                win?.performance?.getEntriesByType("resource")?.length ?? null,\n              resources,\n              childSummary,\n              frameSummary,\n              scriptSummary,\n              styleSummary,\n              bodyHTMLSample: body?.innerHTML?.slice(0, 4000) ?? null,\n              windowName: win?.name ?? null,\n              parentIsSelf: win ? win.parent === win : null,\n              topIsSelf: win ? win.top === win : null,\n              frameElementTag: win?.frameElement?.localName ?? null,\n            });\n          } catch (error) {\n            this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n              stage: `${stage}-error`,\n              uri: href,\n              error: String(error),\n              stack: error?.stack ?? null,\n            });\n          }\n        };\n\n        report("picker-dom-inserted");\n        win?.addEventListener("DOMContentLoaded", () =>\n          report("picker-dom-content-loaded")\n        );\n        win?.addEventListener("load", () => report("picker-load"));\n        win?.addEventListener(\n          "error",\n          event => {\n            this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n              stage: "picker-js-error",\n              uri: href,\n              message: event.message ?? null,\n              filename: event.filename ?? null,\n              line: event.lineno ?? null,\n              column: event.colno ?? null,\n              error: event.error ? String(event.error) : null,\n            });\n          },\n          true\n        );\n        win?.addEventListener("unhandledrejection", event => {\n          this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n            stage: "picker-unhandled-rejection",\n            uri: href,\n            error: String(event.reason),\n          });\n        });\n      }\n      return;\n    }\n\n    const browser = aSubject.ownerElement;\n\n    switch (aTopic) {\n'''
if observer_header not in content_text:
    fail("unable to locate GeckoViewContent observer handler")
content_text = content_text.replace(observer_header, observer_replacement, 1)
content.write_text(content_text)

# Gemini currently renders its microphone affordance on the UIKit runtime but
# does not enter getUserMedia/SpeechRecognition after the click.  Keep a
# product-scoped fallback in the staged GeckoView actor: intercept only Gemini
# controls whose accessible text identifies them as microphone/voice actions,
# start the standards SpeechRecognition object that is backed by the UIKit
# Speech.framework service, and place the final transcript into the active
# Gemini composer.  This remains staged-resource glue so it can be iterated
# without relinking XUL.
voice_child = root / "actors/GeckoViewContentChild.sys.mjs"
voice_child_text = voice_child.read_text()
actor_created = '''  actorCreated() {\n    this.pageShow = new Promise(resolve => {\n      this.receivedPageShow = resolve;\n    });\n  }\n'''
actor_created_replacement = '''  actorCreated() {\n    this.pageShow = new Promise(resolve => {\n      this.receivedPageShow = resolve;\n    });\n\n    this._geminiVoiceRecognition = null;\n    this._geminiVoiceTranscript = "";\n    this.contentWindow?.addEventListener("click", this, true);\n    this.contentWindow?.setTimeout(() => this.reportGeminiVoiceCapabilities(), 0);\n  }\n\n  traceGeminiVoice(stage, detail = {}) {\n    try {\n      this.sendAsyncMessage("GeminiGecko:VoiceTrace", {\n        stage,\n        uri: this.contentWindow?.location?.href ?? null,\n        error: JSON.stringify(detail),\n      });\n    } catch {}\n  }\n\n  isGeminiDocument() {\n    try {\n      return this.contentWindow?.location?.hostname === "gemini.google.com";\n    } catch {\n      return false;\n    }\n  }\n\n  reportGeminiVoiceCapabilities() {\n    if (!this.isGeminiDocument()) {\n      return;\n    }\n    const win = this.contentWindow;\n    this.traceGeminiVoice("voice-capabilities", {\n      secureContext: win?.isSecureContext ?? null,\n      speechRecognition: typeof win?.SpeechRecognition,\n      webkitSpeechRecognition: typeof win?.webkitSpeechRecognition,\n      mediaDevices: !!win?.navigator?.mediaDevices,\n      getUserMedia: typeof win?.navigator?.mediaDevices?.getUserMedia,\n      mediaRecorder: typeof win?.MediaRecorder,\n      visibility: win?.document?.visibilityState ?? null,\n      language: win?.document?.documentElement?.lang ?? null,\n      userAgent: win?.navigator?.userAgent ?? null,\n    });\n  }\n\n  describeGeminiAction(aEvent) {\n    const path =\n      typeof aEvent.composedPath === "function"\n        ? aEvent.composedPath()\n        : [aEvent.target];\n    const element = path.find(node =>\n      node?.nodeType === 1 &&\n      (node.matches?.("button,[role='button']") ||\n        node.hasAttribute?.("aria-label") ||\n        node.hasAttribute?.("data-tooltip"))\n    );\n    if (!element) {\n      return null;\n    }\n\n    const values = [\n      element.getAttribute?.("aria-label"),\n      element.getAttribute?.("title"),\n      element.getAttribute?.("data-tooltip"),\n      element.getAttribute?.("data-test-id"),\n      element.getAttribute?.("jsname"),\n      element.innerText,\n      element.textContent,\n      element.className?.baseVal ?? element.className,\n    ]\n      .filter(value => typeof value === "string" && value.trim())\n      .map(value => value.trim());\n+    return { element, label: values.join(" | ").slice(0, 800) };\n+  }\n+\n+  isGeminiMicrophoneAction(label) {\n+    return /microphone|voice input|voice search|speech|dictat|(^|[^a-z])mic([^a-z]|$)|麦克风|話筒|话筒|語音|语音|說話|说话/i.test(\n+      label || ""\n+    );\n+  }\n+\n+  findGeminiComposer() {\n+    const doc = this.contentWindow?.document;\n+    if (!doc) {\n+      return null;\n+    }\n+    const active = doc.activeElement;\n+    if (\n+      active &&\n+      (active.isContentEditable ||\n+        active.localName === "textarea" ||\n+        (active.localName === "input" &&\n+          /^(text|search|url|email)?$/.test(active.type || "")))\n+    ) {\n+      return active;\n+    }\n+\n+    const candidates = Array.from(\n+      doc.querySelectorAll(\n+        "textarea,[contenteditable='true'][role='textbox'],[contenteditable='true'],input[type='text']"\n+      )\n+    ).filter(element => {\n+      const rect = element.getBoundingClientRect();\n+      const style = this.contentWindow.getComputedStyle(element);\n+      return (\n+        rect.width > 80 &&\n+        rect.height > 16 &&\n+        style.display !== "none" &&\n+        style.visibility !== "hidden"\n+      );\n+    });\n+    candidates.sort(\n+      (left, right) =>\n+        right.getBoundingClientRect().bottom - left.getBoundingClientRect().bottom\n+    );\n+    return candidates[0] ?? null;\n+  }\n+\n+  insertGeminiTranscript(text) {\n+    const win = this.contentWindow;\n+    const doc = win?.document;\n+    const editor = this.findGeminiComposer();\n+    if (!win || !doc || !editor || !text) {\n+      this.traceGeminiVoice("voice-insert-missing-editor", { textLength: text?.length ?? 0 });\n+      return false;\n+    }\n+\n+    editor.focus();\n+    if (editor.isContentEditable) {\n+      try {\n+        const selection = win.getSelection();\n+        const range = doc.createRange();\n+        range.selectNodeContents(editor);\n+        range.collapse(false);\n+        selection.removeAllRanges();\n+        selection.addRange(range);\n+        if (doc.execCommand("insertText", false, text)) {\n+          this.traceGeminiVoice("voice-inserted", { kind: "contenteditable", textLength: text.length });\n+          return true;\n+        }\n+      } catch {}\n+      editor.textContent = `${editor.textContent ?? ""}${text}`;\n+    } else {\n+      const oldValue = editor.value ?? "";\n+      editor.value = `${oldValue}${text}`;\n+    }\n+\n+    try {\n+      editor.dispatchEvent(\n+        new win.InputEvent("input", {\n+          bubbles: true,\n+          inputType: "insertText",\n+          data: text,\n+        })\n+      );\n+    } catch {\n+      editor.dispatchEvent(new win.Event("input", { bubbles: true }));\n+    }\n+    this.traceGeminiVoice("voice-inserted", {\n+      kind: editor.isContentEditable ? "contenteditable-fallback" : editor.localName,\n+      textLength: text.length,\n+    });\n+    return true;\n+  }\n+\n+  startGeminiVoiceFallback() {\n+    if (this._geminiVoiceRecognition) {\n+      this.traceGeminiVoice("voice-fallback-stop", {});\n+      try {\n+        this._geminiVoiceRecognition.stop();\n+      } catch {}\n+      return;\n+    }\n+\n+    const win = this.contentWindow;\n+    const Recognition = win?.SpeechRecognition || win?.webkitSpeechRecognition;\n+    if (typeof Recognition !== "function") {\n+      this.traceGeminiVoice("voice-fallback-unavailable", {\n+        speechRecognition: typeof win?.SpeechRecognition,\n+        webkitSpeechRecognition: typeof win?.webkitSpeechRecognition,\n+      });\n+      return;\n+    }\n+\n+    let recognition;\n+    try {\n+      recognition = new Recognition();\n+      recognition.lang =\n+        win.document?.documentElement?.lang || win.navigator?.language || "zh-CN";\n+      recognition.continuous = false;\n+      recognition.interimResults = true;\n+      recognition.maxAlternatives = 1;\n+    } catch (error) {\n+      this.traceGeminiVoice("voice-fallback-constructor-error", { error: String(error) });\n+      return;\n+    }\n+\n+    this._geminiVoiceRecognition = recognition;\n+    this._geminiVoiceTranscript = "";\n+    recognition.addEventListener("start", () =>\n+      this.traceGeminiVoice("voice-fallback-started", {})\n+    );\n+    recognition.addEventListener("audiostart", () =>\n+      this.traceGeminiVoice("voice-fallback-audio-start", {})\n+    );\n+    recognition.addEventListener("speechstart", () =>\n+      this.traceGeminiVoice("voice-fallback-speech-start", {})\n+    );\n+    recognition.addEventListener("result", event => {\n+      const parts = [];\n+      for (let index = event.resultIndex ?? 0; index < event.results.length; index++) {\n+        const transcript = event.results[index]?.[0]?.transcript;\n+        if (transcript) {\n+          parts.push(transcript);\n+        }\n+      }\n+      if (parts.length) {\n+        this._geminiVoiceTranscript = parts.join("");\n+        this.traceGeminiVoice("voice-fallback-result", {\n+          textLength: this._geminiVoiceTranscript.length,\n+        });\n+      }\n+    });\n+    recognition.addEventListener("error", event => {\n+      this.traceGeminiVoice("voice-fallback-error", {\n+        error: event.error ?? null,\n+        message: event.message ?? null,\n+      });\n+    });\n+    recognition.addEventListener("end", () => {\n+      const transcript = this._geminiVoiceTranscript;\n+      this._geminiVoiceRecognition = null;\n+      this._geminiVoiceTranscript = "";\n+      this.traceGeminiVoice("voice-fallback-ended", { textLength: transcript.length });\n+      if (transcript) {\n+        this.insertGeminiTranscript(transcript);\n+      }\n+    });\n+\n+    this.traceGeminiVoice("voice-fallback-start", { lang: recognition.lang });\n+    try {\n+      recognition.start();\n+    } catch (error) {\n+      this._geminiVoiceRecognition = null;\n+      this.traceGeminiVoice("voice-fallback-start-error", { error: String(error) });\n+    }\n+  }\n+'''
actor_created_replacement = actor_created_replacement.replace("\n+", "\n")
if actor_created not in voice_child_text:
    fail("unable to locate GeckoViewContentChild actorCreated")
voice_child_text = voice_child_text.replace(
    actor_created, actor_created_replacement, 1
)

handle_event_switch = '''    switch (aEvent.type) {\n      case "pageshow": {\n'''
handle_event_replacement = '''    switch (aEvent.type) {\n      case "click": {\n        if (!this.isGeminiDocument()) {\n          break;\n        }\n+        const action = this.describeGeminiAction(aEvent);\n+        if (!action) {\n+          break;\n+        }\n+        this.traceGeminiVoice("voice-click", { label: action.label });\n+        if (!this.isGeminiMicrophoneAction(action.label)) {\n+          break;\n+        }\n+        aEvent.preventDefault();\n+        aEvent.stopImmediatePropagation();\n+        this.traceGeminiVoice("voice-mic-intercepted", { label: action.label });\n+        this.startGeminiVoiceFallback();\n+        break;\n+      }\n+      case "pageshow": {\n'''
handle_event_replacement = handle_event_replacement.replace("\n+", "\n")
if handle_event_switch not in voice_child_text:
    fail("unable to locate GeckoViewContentChild handleEvent switch")
voice_child_text = voice_child_text.replace(
    handle_event_switch, handle_event_replacement, 1
)
voice_child.write_text(voice_child_text)

# Keep diagnostics for ChatGPT voice controls.  The guest composer also exposes
# a distinct "Start dictation" action; unlike realtime Voice Mode this is only
# speech-to-text.  Route that exact action through the already-proven UIKit
# SpeechRecognition fallback so it does not fall into ChatGPT's getUserMedia
# path and bounce focus back to the keyboard.  True Voice Mode remains native.
voice_child_text = voice_child.read_text()
chatgpt_document_anchor = '''  isGeminiDocument() {
    try {
      return this.contentWindow?.location?.hostname === "gemini.google.com";
    } catch {
      return false;
    }
  }
'''
chatgpt_document_replacement = chatgpt_document_anchor + '''
  isChatGPTDocument() {
    try {
      return this.contentWindow?.location?.hostname === "chatgpt.com";
    } catch {
      return false;
    }
  }

  isChatGPTVoiceAction(label) {
    return /voice|speech|microphone|headphone|(^|[^a-z])mic([^a-z]|$)|语音|語音|麦克风|麥克風|耳机|耳機/i.test(
      label || ""
    );
  }

  isChatGPTDictationAction(label) {
    return /start dictation|dictation|听写|聽寫|语音输入|語音輸入/i.test(
      label || ""
    );
  }

  reportChatGPTVoiceState(stage) {
    if (!this.isChatGPTDocument()) {
      return;
    }
    const win = this.contentWindow;
    const doc = win?.document;
    if (!win || !doc) {
      return;
    }
    try {
      const labels = Array.from(doc.querySelectorAll("button,[role='button']"))
        .map(element =>
          [
            element.getAttribute?.("aria-label"),
            element.getAttribute?.("title"),
            element.getAttribute?.("data-testid"),
            element.innerText,
          ]
            .filter(value => typeof value === "string" && value.trim())
            .join(" | ")
            .trim()
        )
        .filter(Boolean);
      const interestingLabels = labels
        .filter(label =>
          /voice|speech|microphone|headphone|account|profile|settings|log in|sign up|login|语音|語音|麦克风|麥克風|账户|帳戶|个人|個人|设置|設定|登录|登入|注册|註冊/i.test(
            label
          )
        )
        .slice(0, 30)
        .map(label => label.slice(0, 240));
      const dialogs = Array.from(
        doc.querySelectorAll("[role='dialog'],[aria-modal='true']")
      )
        .slice(0, 8)
        .map(element => (element.innerText || element.textContent || "").trim().slice(0, 800));
      const busy = Array.from(
        doc.querySelectorAll("[aria-busy='true'],[role='progressbar']")
      ).slice(0, 12).length;
      const bodyText = (doc.body?.innerText || "").slice(0, 16000);
      const resources = (win.performance?.getEntriesByType("resource") || [])
        .map(entry => {
          try {
            const url = new URL(entry.name);
            return `${url.origin}${url.pathname}`;
          } catch {
            return "";
          }
        })
        .filter(value =>
          /voice|realtime|webrtc|audio|session|auth/i.test(value)
        )
        .slice(-30);
      this.traceGeminiVoice(stage, {
        documentLanguage: doc.documentElement?.lang ?? null,
        navigatorLanguage: win.navigator?.language ?? null,
        navigatorLanguages: Array.from(win.navigator?.languages || []).slice(0, 8),
        visibility: doc.visibilityState ?? null,
        loginGate: /log in|sign up|登录|登入|注册|註冊/i.test(bodyText),
        accountHint: /account|profile|settings|账户|帳戶|个人|個人|设置|設定/i.test(bodyText),
        busyCount: busy,
        interestingLabels,
        dialogs,
        resources,
      });
    } catch (error) {
      this.traceGeminiVoice(`${stage}-error`, { error: String(error) });
    }
  }
'''
if chatgpt_document_anchor not in voice_child_text:
    fail("unable to locate generated Gemini document helper for ChatGPT diagnostics")
voice_child_text = voice_child_text.replace(
    chatgpt_document_anchor, chatgpt_document_replacement, 1
)

chatgpt_click_anchor = '''      case "click": {
        if (!this.isGeminiDocument()) {
          break;
        }
        const action = this.describeGeminiAction(aEvent);
        if (!action) {
          break;
        }
        this.traceGeminiVoice("voice-click", { label: action.label });
'''
chatgpt_click_replacement = '''      case "click": {
        const action = this.describeGeminiAction(aEvent);
        if (this.isChatGPTDocument()) {
          if (!action) {
            break;
          }
          this.traceGeminiVoice("chatgpt-click", { label: action.label });
          if (this.isChatGPTDictationAction(action.label)) {
            aEvent.preventDefault();
            aEvent.stopImmediatePropagation();
            this._geminiVoiceButton = action.element;
            this.traceGeminiVoice("chatgpt-dictation-intercepted", {
              label: action.label,
            });
            this.startGeminiVoiceFallback();
            break;
          }
          if (this.isChatGPTVoiceAction(action.label)) {
            this.traceGeminiVoice("chatgpt-voice-click", { label: action.label });
            for (const delay of [0, 500, 2000, 6000]) {
              this.contentWindow?.setTimeout(
                () => this.reportChatGPTVoiceState(`chatgpt-voice-state-${delay}ms`),
                delay
              );
            }
          }
          break;
        }
        if (!this.isGeminiDocument()) {
          break;
        }
        if (!action) {
          break;
        }
        this.traceGeminiVoice("voice-click", { label: action.label });
'''
if chatgpt_click_anchor not in voice_child_text:
    fail("unable to locate generated click handler for ChatGPT diagnostics")
voice_child_text = voice_child_text.replace(
    chatgpt_click_anchor, chatgpt_click_replacement, 1
)

chatgpt_capability_anchor = '''    this.contentWindow?.setTimeout(() => this.reportGeminiVoiceCapabilities(), 0);
'''
chatgpt_capability_replacement = chatgpt_capability_anchor + '''    this.contentWindow?.setTimeout(
      () => this.reportChatGPTVoiceState("chatgpt-page-state"),
      1500
    );
'''
if chatgpt_capability_anchor not in voice_child_text:
    fail("unable to locate generated capability timer for ChatGPT diagnostics")
voice_child_text = voice_child_text.replace(
    chatgpt_capability_anchor, chatgpt_capability_replacement, 1
)
voice_child.write_text(voice_child_text)

# The Google Photos entry in Gemini opens the cross-origin OnePick iframe.  On
# the compact UIKit runtime that iframe currently reaches DOMContentLoaded but
# remains visually empty.  Prefer Gemini's own file-input upload path for this
# specific photo action so the selected image still enters the site's standard
# upload/change-event flow.  Temporarily constrain the existing input to
# image/*; the UIKit file picker recognizes that as a request for the native
# photo library, while the ordinary "upload file" action keeps its broad
# document picker behavior.
voice_child_text = voice_child.read_text()
voice_debounce_anchor = '''  startGeminiVoiceFallback() {
    if (this._geminiVoiceRecognition) {
      this.traceGeminiVoice("voice-fallback-stop", {});
      try {
        this._geminiVoiceRecognition.stop();
      } catch {}
      return;
    }
'''
voice_debounce_replacement = '''  startGeminiVoiceFallback() {
    if (this._geminiVoiceRecognition) {
      const activeMs = Math.max(
        0,
        Date.now() - (this._geminiVoiceStartedAt || 0)
      );
      this.traceGeminiVoice("voice-fallback-active-click-ignored", {
        activeMs,
      });
      return;
    }
'''
if voice_debounce_anchor not in voice_child_text:
    fail("unable to locate generated Gemini voice stop branch")
voice_child_text = voice_child_text.replace(
    voice_debounce_anchor, voice_debounce_replacement, 1
)

voice_started_anchor = '''    this._geminiVoiceRecognition = recognition;
    this._geminiVoiceTranscript = "";
'''
voice_started_replacement = voice_started_anchor + '''    this._geminiVoiceStartedAt = Date.now();
    this.setGeminiVoiceButtonActive(true);
    this._geminiVoiceStopTimer = win.setTimeout(() => {
      if (this._geminiVoiceRecognition !== recognition) {
        return;
      }
      this.traceGeminiVoice("voice-fallback-hard-timeout", {
        activeMs: Math.max(0, Date.now() - (this._geminiVoiceStartedAt || 0)),
      });
      try {
        recognition.stop();
      } catch {}
    }, 12000);
'''
if voice_started_anchor not in voice_child_text:
    fail("unable to locate generated Gemini voice start state")
voice_child_text = voice_child_text.replace(
    voice_started_anchor, voice_started_replacement, 1
)

voice_result_anchor = '''        this.traceGeminiVoice("voice-fallback-result", {
          textLength: this._geminiVoiceTranscript.length,
        });
'''
voice_result_replacement = voice_result_anchor + '''        if (this._geminiVoiceResultTimer) {
          win.clearTimeout(this._geminiVoiceResultTimer);
        }
        this._geminiVoiceResultTimer = win.setTimeout(() => {
          if (
            this._geminiVoiceRecognition !== recognition ||
            !this._geminiVoiceTranscript
          ) {
            return;
          }
          this.traceGeminiVoice("voice-fallback-result-idle-stop", {
            textLength: this._geminiVoiceTranscript.length,
            activeMs: Math.max(
              0,
              Date.now() - (this._geminiVoiceStartedAt || 0)
            ),
          });
          try {
            recognition.stop();
          } catch {}
        }, 2500);
'''
if voice_result_anchor not in voice_child_text:
    fail("unable to locate generated Gemini voice result handler")
voice_child_text = voice_child_text.replace(
    voice_result_anchor, voice_result_replacement, 1
)

voice_end_anchor = '''      this._geminiVoiceRecognition = null;
      this._geminiVoiceTranscript = "";
      this.traceGeminiVoice("voice-fallback-ended", { textLength: transcript.length });
'''
voice_end_replacement = '''      this._geminiVoiceRecognition = null;
      this._geminiVoiceTranscript = "";
      this._geminiVoiceStartedAt = 0;
      if (this._geminiVoiceStopTimer) {
        this.contentWindow?.clearTimeout(this._geminiVoiceStopTimer);
        this._geminiVoiceStopTimer = null;
      }
      if (this._geminiVoiceResultTimer) {
        this.contentWindow?.clearTimeout(this._geminiVoiceResultTimer);
        this._geminiVoiceResultTimer = null;
      }
      this.setGeminiVoiceButtonActive(false);
      this.traceGeminiVoice("voice-fallback-ended", { textLength: transcript.length });
'''
if voice_end_anchor not in voice_child_text:
    fail("unable to locate generated Gemini voice end state")
voice_child_text = voice_child_text.replace(
    voice_end_anchor, voice_end_replacement, 1
)

voice_start_error_anchor = '''    } catch (error) {
      this._geminiVoiceRecognition = null;
      this.traceGeminiVoice("voice-fallback-start-error", { error: String(error) });
'''
voice_start_error_replacement = '''    } catch (error) {
      this._geminiVoiceRecognition = null;
      this._geminiVoiceStartedAt = 0;
      if (this._geminiVoiceStopTimer) {
        this.contentWindow?.clearTimeout(this._geminiVoiceStopTimer);
        this._geminiVoiceStopTimer = null;
      }
      if (this._geminiVoiceResultTimer) {
        this.contentWindow?.clearTimeout(this._geminiVoiceResultTimer);
        this._geminiVoiceResultTimer = null;
      }
      this.setGeminiVoiceButtonActive(false);
      this.traceGeminiVoice("voice-fallback-start-error", { error: String(error) });
'''
if voice_start_error_anchor not in voice_child_text:
    fail("unable to locate generated Gemini voice start error state")
voice_child_text = voice_child_text.replace(
    voice_start_error_anchor, voice_start_error_replacement, 1
)

photo_method_anchor = '''  isGeminiMicrophoneAction(label) {
    return /microphone|voice input|voice search|speech|dictat|(^|[^a-z])mic([^a-z]|$)|麦克风|話筒|话筒|語音|语音|說話|说话/i.test(
      label || ""
    );
  }
'''
photo_method_replacement = photo_method_anchor + '''
  setGeminiVoiceButtonActive(active) {
    const button = this._geminiVoiceButton;
    if (!button) {
      return;
    }
    if (active) {
      if (this._geminiVoiceButtonOldStyle === undefined) {
        this._geminiVoiceButtonOldStyle = button.getAttribute("style");
        this._geminiVoiceButtonOldPressed = button.getAttribute("aria-pressed");
      }
      button.setAttribute("aria-pressed", "true");
      button.style.setProperty("background-color", "rgba(11, 87, 208, 0.18)", "important");
      button.style.setProperty("color", "rgb(11, 87, 208)", "important");
      button.style.setProperty(
        "box-shadow",
        "inset 0 0 0 2px rgba(11, 87, 208, 0.32)",
        "important"
      );
      return;
    }

    if (this._geminiVoiceButtonOldStyle === null) {
      button.removeAttribute("style");
    } else if (this._geminiVoiceButtonOldStyle !== undefined) {
      button.setAttribute("style", this._geminiVoiceButtonOldStyle);
    }
    if (this._geminiVoiceButtonOldPressed === null) {
      button.removeAttribute("aria-pressed");
    } else if (this._geminiVoiceButtonOldPressed !== undefined) {
      button.setAttribute("aria-pressed", this._geminiVoiceButtonOldPressed);
    }
    this._geminiVoiceButton = null;
    this._geminiVoiceButtonOldStyle = undefined;
    this._geminiVoiceButtonOldPressed = undefined;
  }

  isGeminiPhotoAction(action) {
    const element = action?.element;
    if (!element?.matches?.("button")) {
      return false;
    }
    const values = [
      element.getAttribute?.("aria-label"),
      element.getAttribute?.("title"),
      element.innerText,
      element.textContent,
    ]
      .filter(value => typeof value === "string" && value.trim())
      .map(value => value.trim());
    return values.some(value =>
      /^(google\\s*photos|google\\s*相册|相册|相簿)$/i.test(value)
    );
  }

  startGeminiPhotoFallback() {
    const win = this.contentWindow;
    const doc = win?.document;
    if (!win || !doc) {
      return false;
    }

    const inputs = Array.from(doc.querySelectorAll("input[type='file']"));
    const input =
      inputs.find(candidate => /image\\//i.test(candidate.accept || "")) ??
      inputs[0] ??
      null;
    this.traceGeminiVoice("photo-input-probe", {
      count: inputs.length,
      inputs: inputs.slice(0, 8).map(candidate => ({
        accept: candidate.accept || null,
        multiple: !!candidate.multiple,
        id: candidate.id || null,
        name: candidate.name || null,
      })),
    });
    if (!input) {
      this.traceGeminiVoice("photo-native-picker-missing-input", {});
      return false;
    }

    const oldAccept = input.getAttribute("accept");
    const oldMultiple = input.multiple;
    input.setAttribute("accept", "image/*");
    input.multiple = false;
    let pickerMethod = "click";
    try {
      if (typeof input.showPicker === "function") {
        pickerMethod = "showPicker";
        input.showPicker();
      } else {
        input.click();
      }
    } catch (error) {
      if (oldAccept === null) {
        input.removeAttribute("accept");
      } else {
        input.setAttribute("accept", oldAccept);
      }
      input.multiple = oldMultiple;
      this.traceGeminiVoice("photo-native-picker-error", {
        method: pickerMethod,
        error: String(error),
      });
      return false;
    }

    win.setTimeout(() => {
      if (oldAccept === null) {
        input.removeAttribute("accept");
      } else {
        input.setAttribute("accept", oldAccept);
      }
      input.multiple = oldMultiple;
    }, 1000);
    this.traceGeminiVoice("photo-native-picker-start", {
      method: pickerMethod,
      previousAccept: oldAccept,
      previousMultiple: oldMultiple,
    });
    return true;
  }
'''
if photo_method_anchor not in voice_child_text:
    fail("unable to locate generated Gemini microphone action helper")
voice_child_text = voice_child_text.replace(
    photo_method_anchor, photo_method_replacement, 1
)

photo_click_anchor = '''        this.traceGeminiVoice("voice-click", { label: action.label });
        if (!this.isGeminiMicrophoneAction(action.label)) {
          break;
        }
'''
photo_click_replacement = '''        this.traceGeminiVoice("voice-click", { label: action.label });
        if (this.isGeminiPhotoAction(action)) {
          if (this.startGeminiPhotoFallback()) {
            aEvent.preventDefault();
            aEvent.stopImmediatePropagation();
          }
          break;
        }
        if (!this.isGeminiMicrophoneAction(action.label)) {
          break;
        }
        this._geminiVoiceButton = action.element;
'''
if photo_click_anchor not in voice_child_text:
    fail("unable to locate generated Gemini click dispatch")
voice_child_text = voice_child_text.replace(
    photo_click_anchor, photo_click_replacement, 1
)
voice_child.write_text(voice_child_text)

voice_parent = root / "actors/GeckoViewContentParent.sys.mjs"
voice_parent_text = voice_parent.read_text()
parent_switch = '''    switch (aMsg.name) {\n      case "GeckoView:PinOnScreen": {\n'''
parent_replacement = '''    switch (aMsg.name) {\n      case "GeminiGecko:VoiceTrace": {\n        return this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", aMsg.data);\n      }\n+      case "GeckoView:PinOnScreen": {\n'''
parent_replacement = parent_replacement.replace("\n+", "\n")
if parent_switch not in voice_parent_text:
    fail("unable to locate GeckoViewContentParent receiveMessage switch")
voice_parent_text = voice_parent_text.replace(parent_switch, parent_replacement, 1)
voice_parent.write_text(voice_parent_text)

# Keep a host-visible trace around the final GeckoView navigation handoff.
# Unified iOS logs do not reliably surface chrome JS exceptions, so report the
# exact point reached (and whether the browser is remote) over the existing
# GeckoView event bridge.  This is intentionally staged-only diagnostics and
# does not alter the Firefox source checkout or XUL binary.
navigation = root / "modules/GeckoViewNavigation.sys.mjs"
nav_text = navigation.read_text()
load_case = '''      case "GeckoView:LoadUri": {\n        const {\n'''
load_case_replacement = '''      case "GeckoView:LoadUri": {\n        this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n          stage: "enter",\n          uri: aData?.uri ?? null,\n          remote: this.browser.isRemoteBrowser,\n          remoteType: this.browser.getAttribute("remoteType"),\n        });\n        const {\n'''
if load_case not in nav_text:
    fail("unable to locate GeckoViewNavigation LoadUri case")
nav_text = nav_text.replace(load_case, load_case_replacement, 1)

fixup_call = '''        this.browser.fixupAndLoadURIString(uri, {\n          loadFlags: navFlags,\n          referrerInfo,\n          triggeringPrincipal,\n          headers: additionalHeaders,\n          policyContainer,\n          textDirectiveUserActivation,\n          schemelessInput,\n          appLinkLaunchType,\n        });\n'''
fixup_replacement = '''        try {\n          this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n            stage: "before-fixup",\n            uri,\n            remote: this.browser.isRemoteBrowser,\n            remoteType: this.browser.getAttribute("remoteType"),\n          });\n          this.browser.fixupAndLoadURIString(uri, {\n            loadFlags: navFlags,\n            referrerInfo,\n            triggeringPrincipal,\n            headers: additionalHeaders,\n            policyContainer,\n            textDirectiveUserActivation,\n            schemelessInput,\n            appLinkLaunchType,\n          });\n          this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n            stage: "after-fixup",\n            uri,\n            remote: this.browser.isRemoteBrowser,\n            remoteType: this.browser.getAttribute("remoteType"),\n          });\n        } catch (error) {\n          this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {\n            stage: "fixup-error",\n            uri,\n            remote: this.browser.isRemoteBrowser,\n            remoteType: this.browser.getAttribute("remoteType"),\n            error: String(error),\n            stack: error?.stack ?? null,\n          });\n          throw error;\n        }\n'''
snapshot_diagnostics = '''          const snapshotWindow = this.browser.ownerGlobal;
          if (snapshotWindow?.setTimeout) {
            for (const delay of [250, 1000, 3000]) {
              snapshotWindow.setTimeout(() => {
              try {
                const doc = this.browser.contentDocument;
                const win = this.browser.contentWindow;
                const body = doc?.body ?? null;
                const html = doc?.documentElement ?? null;
                const style = body && win ? win.getComputedStyle(body) : null;
                const rect = this.browser.getBoundingClientRect();
                this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {
                  stage: `snapshot-${delay}`,
                  uri,
                  remote: this.browser.isRemoteBrowser,
                  remoteType: this.browser.getAttribute("remoteType"),
                  currentURI: this.browser.currentURI?.spec ?? null,
                  href: doc?.location?.href ?? null,
                  readyState: doc?.readyState ?? null,
                  title: doc?.title ?? null,
                  bodyChildren: body?.childElementCount ?? null,
                  bodyTextLength: body?.innerText?.length ?? null,
                  htmlWidth: html?.scrollWidth ?? null,
                  htmlHeight: html?.scrollHeight ?? null,
                  browserWidth: rect?.width ?? null,
                  browserHeight: rect?.height ?? null,
                  display: style?.display ?? null,
                  visibility: style?.visibility ?? null,
                  opacity: style?.opacity ?? null,
                  background: style?.backgroundColor ?? null,
                  docShellActive: this.browser.docShell?.isActive ?? null,
                  hidden: doc?.hidden ?? null,
                });
              } catch (snapshotError) {
                this.eventDispatcher.sendRequest("GeminiGecko:NavTrace", {
                  stage: `snapshot-${delay}-error`,
                  uri,
                  error: String(snapshotError),
                });
              }
              }, delay);
            }
          }
'''
fixup_replacement = fixup_replacement.replace(
    '''        } catch (error) {
''',
    snapshot_diagnostics + '''        } catch (error) {
''',
    1,
)
if fixup_call not in nav_text:
    fail("unable to locate GeckoViewNavigation fixupAndLoadURIString call")
nav_text = nav_text.replace(fixup_call, fixup_replacement, 1)
navigation.write_text(nav_text)

# The in-process UIKit GeckoView does not reliably emit LocationChange after
# the initial about:blank transition. GeckoViewProgress does observe every
# top-level load, so carry session-history state on PageStart/PageStop and let
# the host keep its back/forward controls in sync from those events.
progress = root / "modules/GeckoViewProgress.sys.mjs"
progress_text = progress.read_text()
page_start = '''    this.eventDispatcher.sendRequest("GeckoView:PageStart", {\n      uri: aUri,\n    });\n'''
page_start_replacement = '''    this.eventDispatcher.sendRequest("GeckoView:PageStart", {\n      uri: aUri,\n      canGoBack: this.browser.canGoBack,\n      canGoForward: this.browser.canGoForward,\n    });\n'''
if page_start not in progress_text:
    fail("unable to locate GeckoViewProgress PageStart payload")
progress_text = progress_text.replace(page_start, page_start_replacement, 1)

page_stop = '''    this.eventDispatcher.sendRequest("GeckoView:PageStop", {\n      success: aIsSuccess,\n    });\n'''
page_stop_replacement = '''    this.eventDispatcher.sendRequest("GeckoView:PageStop", {\n      success: aIsSuccess,\n      uri: this.browser.currentURI?.spec ?? null,\n      canGoBack: this.browser.canGoBack,\n      canGoForward: this.browser.canGoForward,\n    });\n'''
if page_stop not in progress_text:
    fail("unable to locate GeckoViewProgress PageStop payload")
progress_text = progress_text.replace(page_stop, page_stop_replacement, 1)
progress.write_text(progress_text)


# Keep only the XUL core custom-element loader, the browser element required by
# GeckoView, the traditional elements loaded by commonDialog, and the small
# modern element closure used by the network-error card.
classic_elements = {
    "arrowscrollbox.js",
    "dialog.js",
    "general.js",
    "button.js",
    "checkbox.js",
    "menu.js",
    "menupopup.js",
    "moz-input-box.js",
    "notificationbox.js",
    "panel.js",
    "popupnotification.js",
    "radio.js",
    "richlistbox.js",
    "autocomplete-popup.js",
    "autocomplete-richlistitem.js",
    "tabbox.js",
    "text.js",
    "toolbarbutton.js",
    "tree.js",
    "wizard.js",
    "browser-custom-element.mjs",
    "moz-button-group.mjs",
    "moz-button-group.css",
    "moz-button.mjs",
    "moz-button.css",
    "moz-label.mjs",
    "moz-label.css",
    "moz-support-link.mjs",
}
prune_tree("chrome/toolkit/content/global/elements", classic_elements, ())

global_files = {
    "xul.css",
    "customElements.js",
    "process-content.js",
    "widgets.css",
    "lit-utils.mjs",
    "commonDialog.xhtml",
    "commonDialog.js",
    "commonDialog.css",
    "adjustableTitle.js",
    "globalOverlay.js",
    "editMenuOverlay.js",
    "selectDialog.xhtml",
    "selectDialog.js",
    "selectDialog.css",
    "filepicker.properties",
    "contentAreaUtils.js",
    "aboutNetError.mjs",
    "aboutNetError.html",
    "aboutNetErrorHelpers.mjs",
    "net-error-card.mjs",
}
global_prefixes = ("elements/", "errors/", "neterror/", "httpsonlyerror/", "xml/", "vendor/", "third_party/")
prune_tree("chrome/toolkit/content/global", global_files, global_prefixes)

# Keep only the vendor closure still referenced by the retained network-error
# UI. React/Redux and D3 are Firefox product-UI dependencies and have no
# remaining consumers after the UIKit component trims. `lit.all.mjs` is kept
# for net-error-card/moz-button, and cfworker/json-schema remains required by
# JsonSchema.sys.mjs.
for rel in (
    "chrome/toolkit/content/global/vendor/Redux.sys.mjs",
    "chrome/toolkit/content/global/vendor/prop-types.js",
    "chrome/toolkit/content/global/vendor/react-dom.js",
    "chrome/toolkit/content/global/vendor/react-redux.js",
    "chrome/toolkit/content/global/vendor/react-transition-group.js",
    "chrome/toolkit/content/global/vendor/react.js",
    "chrome/toolkit/content/global/vendor/redux.js",
    "chrome/toolkit/content/global/third_party/d3",
):
    remove(rel)

# Remove product-UI art that has no reference anywhere in the retained staged
# runtime. Restrict this automatic pass to icons/illustrations; CSS, GeckoView,
# net-error and security resources are never candidates here. Basename/path
# matching is intentionally conservative so dynamically referenced shared art
# remains present whenever any retained text resource mentions it.
def prune_unreferenced_art(rel: str) -> None:
    base = root / rel
    if not base.is_dir():
        return

    texts: list[tuple[Path, str]] = []
    for candidate in root.rglob("*"):
        if not candidate.is_file():
            continue
        try:
            texts.append((candidate, candidate.read_text(errors="ignore")))
        except OSError:
            continue

    for path in sorted(base.rglob("*"), reverse=True):
        if not path.is_file():
            continue
        runtime_rel = path.relative_to(root).as_posix()
        art_rel = path.relative_to(base).as_posix()
        referenced = False
        for source, text in texts:
            if source == path:
                continue
            if path.name in text or runtime_rel in text or art_rel in text:
                referenced = True
                break
        if not referenced:
            path.unlink()

    for path in sorted((p for p in base.rglob("*") if p.is_dir()), reverse=True):
        try:
            path.rmdir()
        except OSError:
            pass


prune_unreferenced_art("chrome/toolkit/skin/classic/global/icons")
prune_unreferenced_art("chrome/toolkit/skin/classic/global/illustrations")

# Entire Firefox browser-management chrome packages are not used by the
# GeckoView host.  Their XPCOM/web-platform counterparts remain in XUL where
# required; this only removes UI resources.
for rel in (
    "chrome/toolkit/content/extensions",
    "chrome/toolkit/content/mozapps",
    "chrome/toolkit/content/passwordmgr",
):
    remove(rel)

# Keep core layout CSS and iOS caret resources but omit Nimbus experiments and
# address/credit-card autofill UI.  Password-form GeckoViewAutoFill is separate.
remove("chrome/toolkit/res/nimbus")
remove("chrome/toolkit/res/autofill")

# Spellcheck dictionaries are not required for Chinese IME/text input.
remove("dictionaries")

# Product/phase-two skin trees.  Retain global CSS, icons, illustrations and
# in-content styles used by network errors/common dialogs.
for rel in (
    "chrome/toolkit/skin/classic/mozapps",
    "chrome/toolkit/skin/classic/global/media",
    "chrome/toolkit/skin/classic/global/pictureinpicture",
    "chrome/toolkit/skin/classic/global/narrate",
    "chrome/toolkit/skin/classic/global/reader",
):
    remove(rel)

# Remove locales for browser UI packages no longer shipped.  Keep global,
# networking, NSS/PKI and password-manager strings for login/error fallbacks.
for rel in (
    "chrome/en-US/locale/en-US/devtools",
    "chrome/en-US/locale/en-US/mozapps",
    "chrome/en-US/locale/en-US/alerts",
    "chrome/en-US/locale/en-US/autoconfig",
    "chrome/en-US/locale/en-US/places",
):
    remove(rel)

for rel in (
    "localization/en-US/toolkit/about",
    "localization/en-US/toolkit/firefoxlabs",
    "localization/en-US/toolkit/printing",
    "localization/en-US/toolkit/pictureinpicture",
    "localization/en-US/toolkit/preferences",
    "localization/en-US/toolkit/updates",
    "localization/en-US/toolkit/payments",
    "localization/en-US/crashreporter",
    "localization/en-US/locales-preview",
):
    remove(rel)

# JS modules for deferred browser features.  Security remote settings,
# SafeBrowsing, downloads, GeckoView progress/navigation/prompt/permission and
# password-form handling are intentionally not listed here.
module_files = (
    "GeckoViewTab.sys.mjs",
    "GeckoViewWebExtension.sys.mjs",
    "ExtensionBrowsingData.sys.mjs",
    "GeckoViewTranslations.sys.mjs",
    "GeckoViewPageExtractor.sys.mjs",
    "GeckoViewMediaControl.sys.mjs",
    "UserCharacteristicsPageService.sys.mjs",
    "UpdateUtils.sys.mjs",
    "UpdateTimerManager.sys.mjs",
    "Region.sys.mjs",
    "PageThumbs.sys.mjs",
    "PageThumbUtils.sys.mjs",
    "PageThumbs.worker.js",
    "PageThumbsStorageService.sys.mjs",
    "BackgroundPageThumbs.sys.mjs",
    "GMPInstallManager.sys.mjs",
    "GMPUtils.sys.mjs",
    "GMPExtractor.worker.js",
    "InlineSpellChecker.sys.mjs",
    "Finder.sys.mjs",
    "FinderParent.sys.mjs",
    "FinderHighlighter.sys.mjs",
    "FinderIterator.sys.mjs",
    "WebRequest.sys.mjs",
    "WebRequestUpload.sys.mjs",
    "NetworkGeolocationProvider.sys.mjs",
    "PrivateAttributionService.sys.mjs",
    "media/PeerConnectionIdp.sys.mjs",
    "media/IdpSandbox.sys.mjs",
)
for rel in module_files:
    remove(f"modules/{rel}")

# Optional actors matching the GeckoView module blocks removed above.  Do not
# remove GeckoViewAutoFill: it is the password/login actor, not address autofill.
actor_prefixes = (
    "GeckoViewExperimentDelegate",
    "GeckoViewPrintDelegate",
    "MediaControlDelegate",
    "Printing",
    "BackgroundThumbnails",
    "Thumbnails",
    "FindBar",
    "Finder",
    "ExtFind",
    "InlineSpellChecker",
    "PictureInPicture",
    "UserCharacteristics",
)
actors = root / "actors"
if actors.is_dir():
    for path in actors.iterdir():
        if path.is_file() and path.name.startswith(actor_prefixes):
            path.unlink()


# Keep manifest registrations consistent with the files above.
root_manifest = root / "chrome.manifest"
root_lines = root_manifest.read_text().splitlines()
clean_root_lines: list[str] = []
for line in root_lines:
    if line.startswith("manifest "):
        target = line.split(None, 1)[1]
        if not (root / target).is_file():
            continue
    clean_root_lines.append(line)
root_manifest.write_text("\n".join(clean_root_lines) + "\n")

toolkit_manifest = root / "chrome/toolkit.manifest"
lines = toolkit_manifest.read_text().splitlines()
drop_prefixes = (
    "content extensions ",
    "content mozapps ",
    "content passwordmgr ",
    "override chrome://mozapps/",
    "resource autofill ",
    "resource nimbus ",
    "resource passwordmgr ",
    "skin help ",
    "skin mozapps ",
)
toolkit_manifest.write_text(
    "\n".join(line for line in lines if not line.startswith(drop_prefixes)) + "\n"
)

en_manifest = root / "chrome/en-US.manifest"
lines = en_manifest.read_text().splitlines()
drop_locale = ("locale alerts ", "locale autoconfig ", "locale devtools-shared ", "locale mozapps ", "locale places ")
en_manifest.write_text(
    "\n".join(line for line in lines if not line.startswith(drop_locale)) + "\n"
)

# Sanity assertions for the launch closure.
required = (
    "chrome.manifest",
    "chrome/toolkit.manifest",
    "chrome/geckoview/content/geckoview.xhtml",
    "chrome/geckoview/content/geckoview.js",
    "chrome/toolkit/content/global/customElements.js",
    "chrome/toolkit/content/global/process-content.js",
    "chrome/toolkit/content/global/elements/browser-custom-element.mjs",
    "modules/GeckoViewStartup.sys.mjs",
    "modules/GeckoViewNavigation.sys.mjs",
    "modules/GeckoViewProgress.sys.mjs",
    "modules/GeckoViewPrompt.sys.mjs",
    "modules/GeckoViewPermission.sys.mjs",
    "modules/psm/RemoteSecuritySettings.sys.mjs",
    "modules/SafeBrowsing.sys.mjs",
)
missing = [rel for rel in required if not (root / rel).is_file()]
if missing:
    fail("required runtime files removed: " + ", ".join(missing))

print(f"Slim Gecko runtime resources: {sum(1 for p in root.rglob('*') if p.is_file())} files")
