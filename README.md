# ChatWeb / DualAI

ChatWeb 是一个面向 iOS 13+ 的 UIKit 网页客户端，工程目标和 IPA 包名为
`DualAI`。当前版本的 **ChatGPT 与 Gemini 都统一使用项目自带的 Gecko
内核**，不再把其中一个服务留在系统 `WKWebView`。

当前 Gecko 基线：

```text
Firefox tag:    FIREFOX_153_0_4_RELEASE
Firefox commit: c178247e1dfea52241a6b18b18cf3a00f8da935c
Target:         arm64 / iOS 13+
Configuration:  Release + cross-language ThinLTO
Content model:  UIKit single-process Gecko
```

Gecko 端的完整源码修改集中在一份
[`GeckoPort/DualAI-Gecko.patch`](GeckoPort/DualAI-Gecko.patch) 中。App 日常构建
默认使用仓库内的压缩预编译内核
`GeckoPrebuilt/GeckoCore-ios-arm64.zip`，因此修改 Swift/UIKit 层时不需要重新
编译 Firefox/XUL。

当前测试版本为 `1.0.15 (98)`。Build 96 的 Gecko crash reason 已确认崩溃字段为
`OpenerPolicy`：UIKit 单进程网络路径绕过 `DocumentChannel` 后，仍把仅适用于专用
COOP/COEP remote type 和 browsing-context group 的 `require-corp` 组合策略写入
当前 context，第二次刷新发生策略切换时被 Gecko 的 `CanSet` 校验拒绝。Build 97
在 `MOZ_WIDGET_UIKIT` 下保留普通 `same-origin` COOP 和独立的 COEP 子资源限制，
但不再宣称当前单进程 context 可跨源隔离；其他平台保持 Firefox 原有行为。缓存
清理成功后会直接执行一次忽略缓存的刷新，不再采用先导航 `about:blank` 再恢复
URL 的临时规避流程。

Build 97 Release IPA 为 `36583075` B，SHA-256 为
`fc523523b35bb5994b58a0faf92e9f7b39731736f0222763cadb08393f909ebf`；
IPA 内 strip 并重签后的 XUL 为 `63448176` B。

Build 98 不删除新的网页能力，改用跨 C/C++ 与 Rust 的 ThinLTO 重新构建 XUL，
让最终链接器删除 UIKit embedding 不可达的 Rust C ABI 路径，并验证完整安装
体积能否从 Build 97 的 `70540268` B 降至约 65 MB。JIT/Wasm、DOM/CSS、
网络/TLS、Cookie/站点存储、Service Worker、WebGPU/WebGL、媒体解码、文件上传、
CJK 排版和 WebSpeech 均继续保留。16 GiB Mac 上的完整源码构建耗时 25 分 05 秒，
构建成功并产生 198 个既有/第三方 warning，swap-in 约 22 GB；`MOZ_LTO_RUST_CROSS`
确认为 `thin`。同条件 strip 后 XUL 为 `63306264` B，相对 Build 97 的
`63395592` B 只减少 `89328` B，因此单靠跨语言 ThinLTO 无法达到 65 MB。
Build 98 的 prebuilt 和 IPA 尚未导出；Build 97 的上段数据仍是当前发布基线。

## 当前结构

```text
DualAI/                         UIKit App、导航和生命周期
GeckoPrototype/                 App <-> Gecko bridge / engine adapter
GeckoPort/
  PATCHSET.lock                 Firefox revision + patch SHA-256
  DualAI-Gecko.patch            唯一 canonical Gecko source patch
  mozconfig.ios13-arm64         Gecko Release/arm64/iOS 13 配置
  apply_patches.sh              在锁定 Firefox commit 上应用 patch
  build_gecko.sh                编译 Gecko
GeckoPrebuilt/
  GeckoCore-ios-arm64.zip       可提交/分发的预编译内核压缩包
  MANIFEST.lock                 XUL hash、大小、目标和 Firefox revision
  Runtime/                      解压后的运行时，Git 忽略
  include/                      App 所需 Gecko consumer headers，Git 忽略
scripts/
  prepare_gecko_prebuilt.sh     从 zip 准备 Runtime/include
  export_gecko_prebuilt.sh      从已编译 Gecko 刷新预编译内核
  stage_gecko_runtime.sh        从 Gecko objdir 生成精简 runtime
  trim_gecko_runtime.py         Gecko runtime 产品层裁剪
  build_ipa.sh                  使用预编译内核构建/签名/验证 IPA
```

## 构建方式一：直接使用预编译 Gecko 出 IPA（推荐）

这是日常开发路径。**不会运行 `mach build`，也不需要
`build/firefox-src` 存在。**

### 1. 环境

需要完整 Xcode，默认路径为：

```text
/Applications/Xcode.app/Contents/Developer
```

仓库中需要存在：

```text
GeckoPrebuilt/GeckoCore-ios-arm64.zip
GeckoPrebuilt/MANIFEST.lock
```

### 2. 解压/准备预编译内核

```bash
bash scripts/prepare_gecko_prebuilt.sh
```

第一次会生成：

```text
GeckoPrebuilt/Runtime/
GeckoPrebuilt/include/
```

之后如果展开目录仍有效，会直接复用，不重复解压。Xcode 工程直接链接：

```text
GeckoPrebuilt/Runtime/XUL
```

并从：

```text
GeckoPrebuilt/include
```

读取 consumer headers，所以 App 构建不再依赖 Firefox objdir。

如需确认构建确实来自压缩包而不是工作区中先前展开的副本，可先移走或删除
Git 忽略的 `GeckoPrebuilt/Runtime` 与 `GeckoPrebuilt/include`，再执行上述准备
命令。脚本会从 zip 重新展开，并校验内置 manifest 和 arm64 XUL。

### 3. 生成 IPA

```bash
make ipa
```

等价于：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/build_ipa.sh
```

输出固定为：

```text
dist/DualAI.ipa
```

脚本会：

1. 准备预编译 Gecko（已有展开目录时几乎立即完成）；
2. Release/arm64 构建 `DualAI.app`；
3. 将 Gecko XUL、dylib 和 runtime resources 放进 App；
4. 只对 IPA staging 副本 strip，不修改原始 Gecko 编译产物；
5. 对内嵌 Mach-O 和 App 做 ad-hoc 签名；
6. 给 App 保留 TrollStore JIT 路径所需的 `get-task-allow`；
7. 验证 Payload、arm64、签名和最终 IPA 大小。

默认大小上限为 50 MiB。调试时如需临时放宽构建门槛可设置
`MAX_IPA_MIB`，但正式产物仍应重新压回 50 MiB 以下。

普通 App 开发还可使用：

```bash
make debug
make release
make static-check
```

`debug` / `release` 同样只使用预编译 Gecko。

这条路径的最小可复现命令是：

```bash
bash scripts/prepare_gecko_prebuilt.sh
bash scripts/static_check.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/build_ipa.sh
```

---

## 构建方式二：从 Firefox 源码编 Gecko，再出 IPA

只有修改 `DualAI-Gecko.patch`、Gecko C++/ObjC++、SpiderMonkey、网络栈、
UIKit widget 或 runtime 裁剪时才需要走这条路径。

**不会自动清理现有 objdir。** Gecko 编译耗时很长，所以后续 App 构建应先
导出新的预编译内核，再回到“构建方式一”。

### 1. 准备锁定 Firefox 源码

源码目录约定为：

```text
build/firefox-src
```

为避免下载 Firefox 的完整历史，推荐直接从 Mozilla GitHub 镜像浅克隆锁定
release tag：

```bash
git clone \
  --depth 1 \
  --single-branch \
  --branch FIREFOX_153_0_4_RELEASE \
  --filter=blob:none \
  https://github.com/mozilla-firefox/firefox.git \
  build/firefox-src
```

这会保留当前 tag 的完整工作树，但不下载其他分支和完整提交历史；
`--filter=blob:none` 还会让 Git 仅按 checkout 需要获取文件对象。克隆后必须核对：

```bash
test "$(git -C build/firefox-src rev-parse HEAD)" = \
  c178247e1dfea52241a6b18b18cf3a00f8da935c
git -C build/firefox-src rev-parse --is-shallow-repository
```

第二条命令应输出 `true`。

### 2. 准备 Mozilla 私有工具链

如果是新机器，或已经清理过 `~/.mozbuild`，必须先下载 Firefox 锁定的
clang/lld、Node、sccache 等构建工具。只准备用户级工具链、不修改 Homebrew
或系统配置的命令为：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  build/firefox-src/mach bootstrap \
    --application-choice browser \
    --no-system-changes
```

跳过这一步时，`mach configure` 可能退回 `/usr/bin/clang`，随后报
`Failed to find an adequate linker`。工具链会保存在 `~/.mozbuild`，清理该目录
后需要重新 bootstrap。

### 3. 应用 canonical patch

应用 DualAI 唯一 Gecko patch：

```bash
bash GeckoPort/apply_patches.sh build/firefox-src
```

这里要求 Firefox checkout 在应用 patch 前是干净的。如果工作区已经是已应用
canonical patch 的增量开发树，不要重复执行 `apply_patches.sh`；先用
`git -C build/firefox-src diff HEAD --binary` 与 canonical patch 核对，再直接
增量构建。

`apply_patches.sh` 会同时验证：

- Firefox `HEAD` 是否等于锁定 commit；
- Firefox 工作区是否干净；
- `DualAI-Gecko.patch` SHA-256 是否匹配 `PATCHSET.lock`；
- patch 是否能完整应用。

### 4. 编译 Gecko

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
GECKO_BUILD_JOBS=4 \
bash GeckoPort/build_gecko.sh build/firefox-src
```

2026-08-24 在 16 GiB Mac 上从空 `objdir`、空 `~/.mozbuild` 实测旧的普通
ThinLTO 配置（4 jobs、未启用 SCCache）：

- `mach build`：32 分 09 秒，成功完成 Release + ThinLTO；
- Firefox 浅克隆工作树：约 5.6 GB，其中 `.git` 约 1.1 GB；
- 构建完成后的 `obj-gemini-gecko-ios-arm64`：约 19 GB；
- bootstrap 后的 `~/.mozbuild` 工具链：约 3.2 GB；
- 导出 prebuilt：约 32 秒；从 prebuilt 全新构建/签名 IPA：约 19 秒。

源码克隆和 bootstrap 的下载时间取决于网络，不包含在 32 分 09 秒内。本次完整
源码树（含 objdir）最终约 25 GB；构建曾产生较多 swap I/O，16 GiB 内存机器不要
提高默认的 4 jobs，也应预留额外磁盘空间给链接临时文件。

Build 90 的 Release-only 日志裁剪不删除网页功能模块：JIT/Wasm、DOM/CSS、
网络/TLS、存储、Service Worker、WebGPU/WebGL、媒体解码、上传和 WebSpeech 均
保留。未 strip XUL 从 `134656928` B 降到 `132475632` B；按 IPA 相同的
`strip -S -x -N` 与 16 KiB 签名页处理后，从 `66060672` B 降到
`64270848` B（`64.271 MB` / `61.293 MiB`）。代价是 Release XUL 不能再通过
`MOZ_LOG` 环境变量采集 Gecko 内部模块日志；需要排障时应使用 Debug Gecko。

Build 91 继续使用 Release + ThinLTO，并增加锁定 Firefox 153 已验证的
`--disable-webdriver`、`--disable-ctypes` 和 `--disable-webspeechtestbackend`。
UIKit 源码 overlay 同时不再编译没有随包词典的 Hunspell 后端，并从 RLBox 输入
列表移除 Hunspell；Graphite、Ogg、Expat、WOFF2 沙箱继续保留。未 strip XUL 从
`132475632` B 降到 `130855480` B，IPA 内 strip/签名后的 XUL 从 `64270848` B
降到 `63448176` B。Build 91 IPA 为 `36578297` B，解包常规文件为
`70539691` B。网页不可访问的 js-ctypes、远程 WebDriver 和测试假语音后端不再
提供；正式 WebSpeech、编辑器/IME、JIT/Wasm、网络/TLS、存储、媒体和上传保留。

Build 92 不增加新的功能裁剪。Gecko iOS 的显式全局缓存清理现在同时驱逐普通
与 pinned HTTP 缓存，并通过 `asyncGetDiskConsumption` 等待 cache I/O 队列完成
后才向 UIKit 回报成功。未 strip XUL 为 `130855568` B；IPA 内
strip/签名后的 XUL 仍为 `63448176` B。普通 HTTP 磁盘缓存默认关闭 Smart Size，
硬上限为 32768 KiB；pinned 条目可绕过该容量限制，但现在也会被用户主动清理。

默认 objdir：

```text
build/firefox-src/obj-gemini-gecko-ios-arm64
```

核心产物：

```text
build/firefox-src/obj-gemini-gecko-ios-arm64/dist/bin/XUL
```

`build_gecko.sh` 默认只允许一个 Gecko build tree 同时运行，以避免残留
`mach/make/cargo/clang/ld64` 进程把机器内存和 swap 打满。`GECKO_BUILD_JOBS`
可以调节并行度。

### 5. 把已编译 Gecko 导出为预编译内核

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
bash scripts/export_gecko_prebuilt.sh
```

该命令会：

1. 从 objdir install manifest 重新生成精简 runtime；
2. 保留当前项目需要的 GeckoView/启动/网络/存储等资源；
3. 导出 App 编译实际需要的 3 个 Gecko consumer headers；
4. 更新 `GeckoPrebuilt/MANIFEST.lock`；
5. 更新 `GeckoPrebuilt/GeckoCore-ios-arm64.zip`；
6. 同时保留展开后的 `Runtime/` 和 `include/` 供当前工作区立即使用。

**不会删除：**

```text
build/firefox-src
build/firefox-src/obj-gemini-gecko-ios-arm64
build/GeckoRuntimeClean
```

因此后续仍可增量修改 Gecko。

### 6. 使用刚导出的内核生成 IPA

```bash
make ipa
```

从这里开始已经回到预编译内核路径，不会再次编译 Gecko。

完整串行流程也可写成：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer make gecko-core
make ipa
```

其中 `gecko-core` = `gecko-build` + `gecko-export`；它假定 Firefox source 已经
位于锁定 commit 并应用了 canonical patch。

从一份全新的 Firefox checkout 开始时，完整流程为：

```bash
git clone \
  --depth 1 \
  --single-branch \
  --branch FIREFOX_153_0_4_RELEASE \
  --filter=blob:none \
  https://github.com/mozilla-firefox/firefox.git \
  build/firefox-src
test "$(git -C build/firefox-src rev-parse HEAD)" = \
  c178247e1dfea52241a6b18b18cf3a00f8da935c
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  build/firefox-src/mach bootstrap \
    --application-choice browser \
    --no-system-changes
bash GeckoPort/apply_patches.sh build/firefox-src
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
GECKO_BUILD_JOBS=4 \
  bash GeckoPort/build_gecko.sh build/firefox-src
cmp GeckoPort/DualAI-Gecko.patch \
  <(git -C build/firefox-src diff HEAD --binary --full-index)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/export_gecko_prebuilt.sh
bash scripts/static_check.sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash scripts/build_ipa.sh
```

源码、canonical patch 和 prebuilt 必须作为同一组更新：Firefox `git diff HEAD`
应与 `DualAI-Gecko.patch` 完全一致，patch SHA-256 应匹配 `PATCHSET.lock`，objdir
XUL 的 SHA-256 应匹配 `GeckoPrebuilt/MANIFEST.lock` 和 zip 内的 XUL。

---

## 修改 Gecko patch

`GeckoPort/DualAI-Gecko.patch` 是唯一源码真相，不再维护 Reference/Project
多级 patch 队列。

在 `build/firefox-src` 中修改并验证后：

```bash
bash GeckoPort/regenerate_patch.sh build/firefox-src
```

脚本会重建 canonical patch，并打印新的 SHA-256。将它写回：

```text
GeckoPort/PATCHSET.lock
```

中的：

```text
CANONICAL_PATCH_SHA256=...
```

之后建议在锁定 commit 的新 worktree/checkout 中执行：

```bash
git apply --check GeckoPort/DualAI-Gecko.patch
```

再重新编译并执行 `scripts/export_gecko_prebuilt.sh`。

## 预编译内核一致性

`GeckoPrebuilt/MANIFEST.lock` 记录：

- Firefox tag / commit；
- target 和最低 iOS；
- XUL SHA-256；
- XUL 原始大小；
- runtime 文件数。

压缩包包含 `Runtime/`、`include/` 和同一份 `MANIFEST.lock`。
`prepare_gecko_prebuilt.sh` 会校验结构、manifest 和 XUL arm64 架构。

Build 97 使用的 Gecko runtime 最终以
`GeckoPrebuilt/MANIFEST.lock` 为准：

```text
XUL bytes:     130855568
XUL SHA256:    0edc149a606bc373402f68ac1d285ecd057224ac5b93db140edbd0db806b5337
Runtime files: 12
```

Build 98 完成 IPA 真机验证后才会用新的跨语言 ThinLTO 产物刷新该 manifest、
prebuilt zip 和本节尺寸/hash；在此之前，从 prebuilt 构建仍明确对应上面的
Build 97 runtime。

## 运行模型与 JIT

当前 iOS 15 路线使用 UIKit single-process Gecko。现代 iOS 的
BrowserEngineKit 扩展进程架构不适用于目标 iOS 15.5，因此内容、网络和
GeckoView session 都针对单进程路径进行了适配。

SpiderMonkey JIT 保留。目标真机使用 TrollStore 的 JIT 启动路径；App
打包只加入 `get-task-allow`，不会加入 `platform-application`、
`dynamic-codesigning`、`allow-jit` 或 `com.apple.private.*` entitlement。

## 当前功能状态

- ChatGPT / Gemini：统一使用一个进程级 Gecko profile；两个页面各自拥有独立
  GeckoView session。设置中的“共用登录 Cookie”默认开启；关闭后通过固定
  `sessionContextId` 隔离 Cookie、站点存储和权限，修改在完全重启 App 后生效。
- HTTPS 页面、登录、流式内容、Storage/Cookie：已进入真实 Gecko 路径。
- 数据备份：可导出密码加密的单个 `.dualaibackup` 文件，包含逻辑 Cookie、
  持久站点数据和 App 设置，并排除 `cache2`、`startupCache` 等可重建缓存；
  导入后在下一次 Gecko 启动前恢复。服务端已撤销或过期的登录令牌不能靠本地
  备份重新激活。分享完成或取消后会删除 `tmp` 中的导出文件；App 下次启动或
  再次导出时也会补删异常退出遗留的 DualAI 临时备份。
- 缓存：Smart Size 默认关闭，普通 HTTP 磁盘缓存默认硬上限为 32768 KiB。
  “清理缓存”会全局清除普通与 pinned `cache2` 条目，等待 Gecko 确认磁盘回收
  完成，并另行清理当前服务的 IndexedDB/Cache API 等离线数据；成功后当前页面
  会直接忽略缓存刷新，不会先导航到 `about:blank`，也不会主动清除 Cookie。
  当前唯一活动目录为 Application Support 下的
  `GeminiGeckoProfile`，其中 `cache2` 空目录和索引壳会由 Gecko 保留并继续
  复用。早期测试版可能在 `Library/Application Support`、`Library` 或
  `Library/Caches` 遗留 `GeckoProfile/profile`、
  `GeckoProfile/profile/profile`，也可能遗留 `ChatGPTGeckoProfile`。这些旧目录
  已经不再引用，App 启动时也不会扫描或删除。关闭“共用登录 Cookie”时，
  GPT/Gemini 仍通过当前 `GeminiGeckoProfile` 内不同的 `sessionContextId` 隔离
  Cookie、站点存储和权限，不依赖这些旧目录。
- 用户代理：设置中可全局切换默认 iPhone Gecko、Android Firefox（Reynard
  兼容）、macOS Firefox、Windows Firefox 和 iOS Firefox（FxiOS/Safari）五个
  档位。UA、`navigator.platform`、`navigator.appVersion`、`navigator.oscpu` 与
  mobile/desktop viewport 会成组切换，已打开的 GPT/Gemini 页面随即重新加载。
- 网站权限：可按当前服务和当前 `sessionContextId` 重置麦克风、摄像头、位置、
  通知、自动播放等权限决定；不会删除 Cookie、登录状态或站点数据。
- 网页文字：可全局选择 `80%`、`100%`、`120%`、`140%`、`160%`，通过
  Gecko `BrowsingContext.textZoom` 只缩放网页文字，默认 `100%`。
- 媒体：自动播放可选择“阻止有声（默认）”“允许”或“阻止所有”；另有独立
  开关决定 GPT/Gemini 页面非活动或 App 进入后台时是否暂停媒体，默认开启。
- 隐私保护：标准（默认）启用跟踪保护并分区第三方 Cookie；兼容关闭跟踪保护
  并接受第三方 Cookie；严格启用严格跟踪列表并阻止第三方 Cookie。该设置与
  “GPT/Gemini 共用登录 Cookie”相互独立。
- ChatGPT 退出：`/auth/logout` 在当前单进程 docshell 中触发安全脱离页面、清理
  当前 context Cookie 并回到首页，避免在退出脚本仍运行时直接清 Cookie。
- 前进/后退：由 Gecko `PageStart/PageStop` 同步历史状态。
- 文件上传：GeckoView `FilePickerDelegate` -> UIKit `UIDocumentPickerViewController`。
- 麦克风/摄像头权限：Gecko media permission bridge 已接通；完整实时通话仍受
  当前 `--disable-webrtc` 构建策略影响。
- iOS 15 单进程网络：关闭 Firefox iOS 默认 Socket Process，网络保留在主进程。
- runtime：移除 Firefox 产品层、PDF.js、DevTools UI、Reader、ML、绝大部分
  FxA 等非 AI 网页必需内容，同时保留 DOM/CSS、Fetch、WebSocket、TLS、
  storage、Canvas、APZ/touch、上传和 GeckoView 基础设施。

## 真机日志

开发阶段建议只抓 DualAI：

```bash
idevicesyslog -p DualAI --no-colors > log.log
```

`log.log` 已被 Git 忽略。

## License / upstream

Gecko/Firefox 及其修改遵循对应 Mozilla 源文件和 MPL-2.0 要求。项目的 iOS
port 工作参考并审计过 Reynard 的 Gecko iOS 修改；锁定的参考 commit 记录在
`GeckoPort/PATCHSET.lock`。DualAI 不包含 Reynard 浏览器 UI，也不依赖其浏览器
shell 运行。
