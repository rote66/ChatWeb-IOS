# ChatWeb / DualAI

ChatWeb 是一个面向 iOS 13+ 的 UIKit 网页客户端，工程目标和 IPA 包名为
`DualAI`。当前版本的 **ChatGPT 与 Gemini 都统一使用项目自带的 Gecko
内核**，不再把其中一个服务留在系统 `WKWebView`。

当前 Gecko 基线：

```text
Firefox tag:    FIREFOX_153_0_4_RELEASE
Firefox commit: c178247e1dfea52241a6b18b18cf3a00f8da935c
Target:         arm64 / iOS 13+
Configuration:  Release + ThinLTO
Content model:  UIKit single-process Gecko
```

Gecko 端的完整源码修改集中在一份
[`GeckoPort/DualAI-Gecko.patch`](GeckoPort/DualAI-Gecko.patch) 中。App 日常构建
默认使用仓库内的压缩预编译内核
`GeckoPrebuilt/GeckoCore-ios-arm64.zip`，因此修改 Swift/UIKit 层时不需要重新
编译 Firefox/XUL。

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

获取 Firefox 源码后切到 `GeckoPort/PATCHSET.lock` 记录的 commit：

```bash
git -C build/firefox-src checkout \
  c178247e1dfea52241a6b18b18cf3a00f8da935c
```

应用 DualAI 唯一 Gecko patch：

```bash
bash GeckoPort/apply_patches.sh build/firefox-src
```

`apply_patches.sh` 会同时验证：

- Firefox `HEAD` 是否等于锁定 commit；
- Firefox 工作区是否干净；
- `DualAI-Gecko.patch` SHA-256 是否匹配 `PATCHSET.lock`；
- patch 是否能完整应用。

### 2. 编译 Gecko

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
GECKO_BUILD_JOBS=4 \
bash GeckoPort/build_gecko.sh build/firefox-src
```

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

### 3. 把已编译 Gecko 导出为预编译内核

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

### 4. 使用刚导出的内核生成 IPA

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

当前预编译核心对应 Build 48 时的 Gecko runtime：

```text
XUL bytes:     181495872
XUL SHA256:    01eb153b43552ba7b9f8942e7f2a3e665770dca975565222e767d346817f0c8a
Runtime files: 745
```

## 运行模型与 JIT

当前 iOS 15 路线使用 UIKit single-process Gecko。现代 iOS 的
BrowserEngineKit 扩展进程架构不适用于目标 iOS 15.5，因此内容、网络和
GeckoView session 都针对单进程路径进行了适配。

SpiderMonkey JIT 保留。目标真机使用 TrollStore 的 JIT 启动路径；App
打包只加入 `get-task-allow`，不会加入 `platform-application`、
`dynamic-codesigning`、`allow-jit` 或 `com.apple.private.*` entitlement。

## 当前功能状态

- ChatGPT / Gemini：统一 Gecko 内核与独立 profile/session。
- HTTPS 页面、登录、流式内容、Storage/Cookie：已进入真实 Gecko 路径。
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
