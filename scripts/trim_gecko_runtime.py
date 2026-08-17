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
content.write_text(content_text)

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
snapshot_diagnostics = '''          for (const delay of [250, 1000, 3000]) {
            this.browser.ownerGlobal.setTimeout(() => {
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
