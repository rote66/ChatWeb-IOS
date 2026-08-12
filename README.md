# ChatWeb

ChatWeb 是一个 Swift + UIKit 网页客户端。应用目标名和 IPA 内的包名为 `DualAI`，桌面显示名为 `ChatWeb`。它不调用任何 AI API：ChatGPT 和 Gemini 均使用常驻的 `WKWebView`。

应用只提供一个 ChatGPT WebView 和一个 Gemini WebView，不提供多账号、多身份或配置切换。账号和登录完全由对应网站及系统 WebKit 管理，仓库中没有账号、Cookie 或凭据。

## 功能

- 顶部 `GPT / Gemini` 分段直接切换；各 WebView 在首次进入对应服务时创建，之后常驻并保留当前页面、滚动位置和导航栈。
- ChatGPT 固定加载 `https://chatgpt.com/`，使用 `WKWebsiteDataStore.default()` 保存登录。
- Gemini 固定加载官方入口 `https://gemini.google.com/app`，同样使用 `WKWebsiteDataStore.default()`，但拥有独立的 WebView 页面状态。
- 工具栏的人像按钮按当前服务直接打开 ChatGPT 或 Google 官方登录页。
- iOS 14–15 会为两个官方首页的“登录”点击安装最小导航兼容脚本，只执行官方登录页跳转；脚本不读取 Cookie、凭据、认证参数或网页内容到 App。
- ChatGPT 支持后退、前进、刷新、首页、分享、Safari 打开、网页弹窗和新窗口；`about:blank`、`target=_blank`、`window.open/close` 使用独立子 WebView 处理。
- 标准网页文件输入由 WebKit 调用系统文件、照片和相机选择界面。
- iOS 14.5+ 使用 `WKDownload`，下载后可预览、分享或存储到“文件”。
- iOS 15+ 对可信 ChatGPT 来源的相机/麦克风请求逐次确认，并继续遵守 iOS 系统权限。
- 离线、加载失败、登录受限、下载降级和 WebContent 进程终止均有明确状态。
- “清除 ChatGPT 网站数据”需要两次确认，只清理默认 WebKit 中匹配 ChatGPT/OpenAI 的记录，不影响 Safari。

## 构建

需要完整 Xcode。当前工程的 Deployment Target 为 iOS 14.0，Release 产物限定 arm64。

```bash
make debug
make release
make test SIMULATOR_NAME='iPhone 17 Pro'
make static-check
make ipa
```

如果系统没有将 Xcode 设为活动开发目录，这些入口仍会显式使用 `/Applications/Xcode.app/Contents/Developer`。`make ipa` 会：

1. 用 `xcodebuild` 构建 iphoneos Release、arm64、无开发签名的 `DualAI.app`。
2. 复制为 `Payload/DualAI.app` 并执行临时 ad-hoc 签名。
3. 生成 `dist/DualAI.ipa`。
4. 解包验证 `.app`、可执行文件、`Info.plist` 和 arm64 架构。

脚本不会嵌入开发证书、个人 Provisioning Profile 或自定义 entitlement。

## 安装

生成的 `dist/DualAI.ipa` 是标准系统 WebKit 版本。可通过当前设备上支持 ad-hoc IPA 的安装方式安装；项目本身不捆绑安装器、越狱组件或漏洞利用。

## 版本兼容

| 系统 | 行为 |
| --- | --- |
| iOS 15.x | App 主功能、`WKDownload`、媒体权限回调和普通上传可用；ChatGPT 与 Gemini 首页登录按钮均使用官方登录页导航兼容；Gemini 页面脚本仍可能不兼容旧 WebKit。 |
| iOS 16+ | App 功能完整；网站实际可用性仍由 ChatGPT、Gemini 与系统 WebKit 的当前兼容策略决定。 |
| iOS 14.5–14.x | 支持 `WKDownload` 和普通上传；不承诺网页语音、摄像头、实时 WebRTC。 |
| iOS 14.0–14.4 | 文本聊天和普通上传兼容；下载或媒体能力不可靠时提示转 Safari。 |

Blob 下载默认明确降级。应用不会为 Blob 注入读取认证信息的脚本，也不会读取 Cookie 来自行重放下载请求。

Google 或其他登录提供方可能拒绝嵌入式 WebView。ChatWeb 会显示原因并提供 Safari 降级入口，但 Safari 登录不会被转移回 WKWebView。此限制不通过 Cookie、User-Agent、证书设置或私有 API 绕过。

Gemini WebView 与 ChatGPT WebView 同时常驻，切换服务不会主动重新加载。App 被终止、系统因内存回收网页进程或网站自身刷新时，仍可能从最后一个经过过滤的安全 Gemini URL 重新加载。应用不读取或转移 Safari 数据。

iOS 15 的 WKWebView 由系统提供，App 无法自行升级。若 Gemini 仍只渲染 Google 登录按钮和空白区域，说明网站应用脚本没有在该系统 WebKit 中完成运行；可以使用工具栏 Safari 按钮降级，但不能用 User-Agent、代理、Cookie 注入或私有 API 修复第三方网站兼容性。

## 数据与安全

- 不使用 OpenAI、ChatGPT、Gemini 或 Google AI API。
- 不使用代理、远端浏览器、网页转发服务或 TLS 绕过。
- 不读取、导出、备份、注入或迁移 Cookie。
- 不捕获密码、Token、Authorization Header、验证码或网页正文。
- 日志只记录失败主机名和错误码，不记录完整 URL、查询参数或正文。
- 只保存上次服务和经过过滤的 ChatGPT/Gemini 安全 URL；OAuth 回调、登出路径、认证站点及非白名单查询参数不会保存。
- 未知第三方顶层网页使用 `SFSafariViewController`；Gemini WebView 仅允许 `gemini.google.com` 和明确的 `accounts.google.com` 登录页留在内部。

## 验证状态

已自动验证：

- Xcode 26.6 / iOS 26.5 SDK 的 arm64 Debug iphoneos 构建。
- Xcode 26.6 / iOS 26.5 SDK 的 arm64 Release iphoneos 构建。
- 编译命令目标为 `arm64-apple-ios14.0`，验证 iOS 14 可用性标注。
- NavigationPolicy/项目单元测试 11/11 通过，0 failed、0 skipped，覆盖 ChatGPT 与 Gemini 的域名、登录和安全 URL 规则。
- `Info.plist` 相机、照片、麦克风用途说明和 `MinimumOSVersion=14.0`。
- Cookie、User-Agent、TLS 绕过、私有 API 和危险 entitlement 标记静态检查。
- `dist/DualAI.ipa` 的 Payload 结构、arm64、iOS 14.0 和 ad-hoc 签名。
- iOS 26.5 模拟器启动冒烟：Gemini 在内嵌 WKWebView 中完整显示首页，不出现兼容弹窗或 Safari 模态栏，顶部切换与底部工具栏无重叠。

尚未自动验证：iOS 15 真机上的 Gemini 登录、页面性能、温度、耗电和 WebContent 长时间稳定性。

