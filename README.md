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

当前测试版本为 `1.0.15 (108)`。Build 96 的 Gecko crash reason 已确认崩溃字段为
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

Build 98 不删除新的网页能力，改用跨 C/C++ 与 Rust 的 ThinLTO，并启用 LLVM
MergeFunctions 合并机器码完全相同的函数。JIT/Wasm、DOM/CSS、
网络/TLS、Cookie/站点存储、Service Worker、WebGPU/WebGL、媒体解码、文件上传、
CJK 排版和 WebSpeech 均继续保留。16 GiB Mac 上的正式重建耗时 25 分 06 秒，
构建成功并产生 198 个既有/第三方 warning，swap-in 约 21.5 GB；
`MOZ_LTO_RUST_CROSS` 确认为 `thin`。同条件 strip 后 XUL 为 `63044120` B，
打包签名后为 `63185520` B。最终 IPA 为 `36490620` B，SHA-256 为
`24fca137f0a68284682b3cd091d29992f28d50d428daf08c9811de88e1650493`，
解包完整安装常规文件为 `70277613` B；相对 Build 97 只减少 `262655` B，
离十进制 65 MB 仍差 `5277613` B，因此保留全部上述能力时无法达到目标。

Build 99 验证了关闭 Rust 显式 SIMD 的尺寸实验，但结果是负优化：未 strip XUL
从 Build 98 的 `126211712` B 降到 `124865536` B，strip 并签名后却增至
`64058032` B；IPA 为 `36689043` B，SHA-256 为
`f282a7f448b9df6024baf0f0a612898b57555c349c3cbafa57722c6f1623e59e`，完整
安装常规文件增至 `71150125` B。因此正式配置继续启用 Rust SIMD，Build 99
不作为发布基线。该实验同时发现自动更新的 Rust stable 已使用 LLVM 22.1.6，
无法与 Firefox bootstrap 的 LLVM 21.1.8 进行 cross-language ThinLTO；源码
构建现锁定 Firefox 153 CI 使用的 Rust 1.94.1，以保证两侧 LLVM 版本一致。

随后用固定 Rust 1.94.1 恢复 Rust SIMD 并从源码重建，耗时 28 分 31 秒；未
strip XUL 为 `124869728` B，最终 IPA 为 `36692219` B，完整安装常规文件为
`71150107` B。它与关闭 SIMD 的 Build 99 安装体积仅差 18 B，也无法复现旧构建
缓存下 Build 98 的 `70277613` B。因此后续尺寸对比统一以固定工具链的
`71150107` B 为可复现基线，不能再把 Build 98 的偶然结果当作当前基线。

Graphite 阶段的中间尺寸基线在 UIKit 下关闭不可到达的 Graphite 字体整形和对应 wasm2c
沙箱，但继续保留 HarfBuzz/OpenType/CJK、Ogg/Expat/WOFF2 的 RLBox 隔离以及全部
媒体解码路径。固定 Rust 1.94.1 的完整 Release 源码构建耗时 26 分 00 秒，产生
198 个既有/第三方 warning；未 strip XUL 为 `121109424` B，IPA 内 strip 并签名
后为 `61935600` B。Release IPA 为 `35563547` B，SHA-256 为
`c0fc4385aebf91786fcbeaba1e34623cb4cd5083be8b3ad3f21a3230fff68187`，完整安装
常规文件为 `69027693` B，离十进制 65 MB 仍差 `4027693` B。该 XUL 已导出为
prebuilt，并通过 `make ipa` 验证预编译构建路径。

Graphite 基线之后的一轮工作树继续移除了 UIKit 不使用的 Glean JavaScript 指标/
ping 名称查询表，并将仅供 Firefox 桌面动态指标注册使用的 JOG 改为空实现；同时在
iOS Release 中关闭 Gecko 内存 profiler、Rust profiler marker 和实时音频回调追踪。
这些修改不关闭 Web API 性能计时，不影响 WebRender 使用的原生 Rust metrics，也不
改变 JIT/Wasm、Service Worker、Safe Browsing、HSTS、RLBox、Cookie/站点存储、
WebGL/WebGPU 和媒体解码能力。最新一次增量 Release 构建耗时 6 分 22 秒且无 warning，
未 strip XUL 为 `119336024` B，临时 strip 并签名后为 `60818560` B；按 Graphite
IPA 的其余文件不变估算，完整安装常规文件为 `67910653` B，离十进制 65 MB 仍差
`2910653` B。该数字只是中间实验结果：当前正式
`GeckoPrebuilt/GeckoCore-ios-arm64.zip` 和 `dist/DualAI.ipa` 仍是上一段的 Graphite
基线，尚未用此工作树重新导出，不能把旧 IPA 当作这一轮裁剪的验证产物。

下一轮 UIKit 尺寸实验关闭 AVIF 图片和通用媒体模块的软件 AV1 解码，并从 XUL
链接输入中移除 dav1d；PNG/JPEG/GIF/WebP、H.264/HEVC/VP8/VP9、音频解码及
Apple VideoToolbox 路径不变，AOM 的 AV1 MIME/OBU/`av1C` 格式解析也继续保留。
Firefox 153 当前在 iOS 分支不会注册 supplemental AV1 硬解，所以这项取舍意味着
AVIF 图片不再显示，且没有系统 AV1 硬解的设备无法再播放 AV1 视频。增量 Release
构建耗时 5 分 17 秒，出现 10 条 Apple VideoToolbox SDK 可用性既有 warning；
未 strip XUL 为 `118296488` B，strip 并签名后为 `60112256` B，raw XUL 中已无
dav1d/AVIF 解码符号。按同一基线估算，完整安装常规文件为 `67204349` B，离十进制
65 MB 仍差 `2204349` B。`libgkcodecs.dylib` 仍为 `2073976` B，说明本轮尚未消除
其中由 libaom 软件解码导出保留的代码；正式 prebuilt 与 IPA 同样尚未刷新。

作为下一候选项，UIKit 工作树还暂时排除了 Firefox 153 新增的 Rust
content-classifier/adblock 规则引擎，但继续保留经典 URL Classifier、Safe Browsing
数据库/更新器及其频道拦截流程。该实验的 Release 重建耗时 9 分 33 秒，未 strip
XUL 为 `118005696` B，strip 并签名后为 `59964192` B；完整安装估算为
`67056285` B，仍超十进制 65 MB `2056285` B。相对上一项只减少 `148064` B，
功能收益比很低，当时仅作为未提交实验。为达到本轮 65 MB 目标，下面的最终测试
配置暂时保留了这项取舍；后续若继续从其他不可达代码取得空间，应优先恢复这一层
隐私分类能力。

为达到 62-65 MB 的第一版测试配置曾从 UIKit 内核排除 Rust SWGL 软件光栅器和
C++ SWGL compositor，只保留极小的 `wr_swgl_*` ABI 失败桩；硬件 WebRender、
EAGL GLES3/GLES2、WebGL 和 Apple VideoToolbox 保持启用，WebGPU 则从最终 UIKit
构建排除。ffvpx 只编译音频实现，libaom/dav1d 软件 AV1 与 AVIF 不再进入 UIKit
产物，libvpx 的 VP8/VP9 解码仍保留。iOS 默认不会启用
`gfx.webrender.program-binary-disk`，因此该构建也
不再链接其 shader 序列化/磁盘读写实现和仅供开发诊断的 `wr-capture` 文件导出；
这不关闭进程内 shader/program cache 或正常 shader 编译。

UIKit 的 ffvpx encoder 模块已经关闭，最终 XUL 只导入 Opus 解码 API；
`libgkcodecs.dylib` 因此不再导出无调用者的 Opus 单流/多流 encoder，从 raw
`823704` B 降到 `650008` B，strip 并签名后为 `497344` B。Opus/Vorbis/Ogg
播放和 VP8/VP9 解码仍保留，但该构建不提供基于 ffvpx/Opus 的网页媒体录制编码。
最后一次只重链 gkcodecs/XUL 的无 SWGL Release 构建耗时 4 分 57 秒，compiler
warning 为 0；raw XUL 为 `116551240` B，IPA 内 strip 并签名后为 `58978800` B，
`omni.ja` 为 `2005783` B。最终 IPA 为 `33721594` B，SHA-256 为
`e06cb10cdf9e85a92b322f64ff98f1c34ebf9f6d649409289b2ae880333b34fd`；解包
完整安装常规文件为 `64967850` B，低于十进制 65 MB `32150` B。该配置仍包含
上一段所述的 content-classifier 取舍；经典 URL Classifier、Safe Browsing 和
远程安全状态数据未移除。

无 SWGL 版本在 iOS 15.5 上出现启动后页面不加载、卡住并退出。系统生成的
`stacks` IPS 明确记录 `0x8badf00d`、`WatchdogEvent: scene-update` 和 10 秒前台
scene 更新超时，`memoryPressure=false`，并非 Jetsam；累计 CPU 主要集中在
MainThread、Compositor 和 Renderer。为做最小对照，当前测试配置只恢复完整的 Rust
SWGL、`sw_compositor` feature、C++ SWGL compositor 和 Native SWGL 实现；program
binary 磁盘缓存、`wr-capture`、content-classifier 和媒体精简均保持不变。

补齐 Native SWGL 后的最终 Release 重链耗时 4 分 59 秒且报告 0 compiler warning；
raw XUL 为 `117922048` B，IPA 内 strip 并签名后为 `59914704` B。当前 IPA 为
`34168515` B，SHA-256 为
`b7b0d993f0ca5dc33df5a955311258a16edb2b10debb2575f82dfc9103bd25cf`；解包
完整安装常规文件为 `65903754` B，超过十进制 65 MB `903754` B。该版本以恢复
iOS 15.5 软件渲染回退并验证 watchdog 回归为优先目标，暂不把 65 MB 作为已达成
状态。

Build 100 尝试修复恢复 SWGL 后发现的两个回归。UIKit 单进程真实 HTTPS 页面没有
`PageStart`、`LocationChange` 和 `PageStop`，导致顶部加载条不出现或刷新后停在起点；
该版改为监听当前 docshell，但真机日志证明 docshell 同样没有转发这条直接 channel
导航，因此这项加载条修复未生效，Build 101 已撤回该监听改动。WebSpeech 崩溃已由
同版本未 strip XUL 精确定位到 `SpeechRecognition.cpp:402`：
`SFSpeechRecognizer` 在 `endAudio()` 后仍可返回最后一条 partial result，通用状态机
却在 `STATE_WAITING_FOR_RESULT` 对该事件执行 `MOZ_CRASH()`；UIKit 路径现将它作为
有效 intermediate result 分发，并继续等待 final result。

本轮增量 Release 构建耗时 5 分 03 秒且报告 0 compiler warning；raw XUL 仍为
`117922048` B，SHA-256 为
`f8791ce32517ceb4527633b6067a9688ad46e3795e9b87d1f2ec1c5a488f047a`，IPA 内 strip
并签名后仍为 `59914704` B。Build 100 IPA 为 `34168685` B，SHA-256 为
`93b4019dc73d767cab6546400fe711861d26393685e209e08ec0bd56fea4c71d`；解包完整安装
常规文件为 `65904037` B，超过十进制 65 MB `904037` B。本轮目标是加载进度和语音
稳定性修复，没有新增尺寸裁剪。

Build 101 尝试改用 GeckoView 已有的内容 actor 生命周期事件恢复 UIKit 单进程加载
进度，但真机日志证明父进程内容 docshell 没有把 `DOMContentLoaded`、
`MozAfterPaint` 和 `pageshow` 送达该 JSWindowActor；因此顶部只显示 UIKit 在发送
加载命令时设置的 `0.05`，没有真实进度更新或完成事件。Bridge 同时忽略初始化
`about:blank` 的人工 `PageStart/PageStop`，避免它在真实加载前把顶部进度条提前隐藏。
语音路径保留 Build 100 的迟到 partial-result 防崩处理，
并取消等待较高输入峰值后才创建 `SFSpeechRecognizer` 的门槛，从第一段 PCM 就启动
识别，避免安静设备上短句开头被丢弃。真机 Build 100 日志已确认按钮点击后 17 ms
内进入 Speech 初始化、麦克风权限为已授权且 RemoteIO 正常启动，问题不是触摸事件
丢失或权限拒绝。

Build 101 Gecko 增量 Release 构建耗时 5 分 11 秒且报告 0 compiler warning；raw
XUL 为 `117922048` B，SHA-256 为
`c992803524a0f446e04c8c94a465fab8d9f0a55dc3f725fc435d1cf03704d5b6`；IPA 内
strip 并签名后的 XUL 为 `59914704` B，SHA-256 为
`078de06e5513c4d2f23d2ab1d6cf324fbcc551ed51f0998a4509f32f125de63c`。
Build 101 IPA 为 `34168250` B，SHA-256 为
`f8c87e4b573b6fb771f0e098ae27dbac8c71be4df97947ccb30c73f768123b09`；解包完整安装
常规文件为 `65903922` B，超过十进制 65 MB `903922` B。本轮只修复加载进度和语音
交互，没有新增尺寸裁剪。

Build 102 修复 listener 绑定时机：GeckoView browser 启动时先创建 remote placeholder，
随后才切换为 UIKit `remote=0` 的父进程内容 docshell；之前的 web-progress listener
仍留在已丢弃的 placeholder 上。现在 `DidChangeBrowserRemoteness` 触发
`onInitBrowser()` 后会把 progress 和 navigation listener 重新绑定到新 docshell；
同时在非远程 `<browser>` 上直接捕获真实 `DOMContentLoaded`、`MozAfterPaint` 和
`pageshow` 作为第二条真实生命周期路径，不使用定时器模拟进度。新版本增加
`progress-attach` 与 `progress-content-*` 日志，后续真机日志可直接确认绑定来源和
每个内容事件。Gecko 增量 Release 构建耗时 5 分 01 秒且报告 0 compiler warning；
raw XUL 为 `117922048` B，SHA-256 为
`0311e124a48b3801034a968a706c887c1a1525dbf2ecdfd881704cb5a27482a1`；IPA 内
strip 并签名后的 XUL 为 `59914704` B，SHA-256 为
`b1e3c0eb0140c90c48afeae30a77b90c8ae07694cf830165c94409f343a2ff52`。
Build 102 IPA 为 `34168993` B，SHA-256 为
`bbb0c9cdfe7333edcbb2ff6ff93351519e33f84eec412bf373ef0171ff588845`；解包完整安装
常规文件为 `65904595` B，超过十进制 65 MB `904595` B。

Build 102 真机日志仍只有初始化 `about:blank` 的人工 `PageStart`、
`LocationChange` 和 `PageStop`；Gemini、ChatGPT 以及两次刷新均成功进入
`remote=0` 的导航代码，但没有任何真实页面进度事件，也没有预期的
`progress-attach` 或 `progress-content-*`。这证明进度模块在 `_fireInitialLoad()`
之后、监听器完成绑定之前就停止初始化；原实现先绑定 web-progress，再注册 DOM
生命周期监听，前一步任意异常都会使两条真实进度路径同时失效，顶部最终只剩 UIKit
发送加载命令时设置的起点值。

Build 103 将真实 `DOMContentLoaded`、`load`、`MozAfterPaint` 和 `pageshow`
监听提前注册，并把 browser-status-filter 创建、filter listener 绑定、docshell 绑定和
`<browser>` 回退全部改为彼此隔离的容错步骤。docshell 绑定失败时会继续尝试
`browser.addProgressListener`，不会再中断整个模块；DOM 原始事件会记录 URI 和是否为
顶层文档，只有真实生命周期事件才推进到 15/55/80/100 并结束进度，不加入定时器模拟。
新增的 `progress-enable`、`progress-filter-*`、`progress-attach-*`、
`progress-dom-*` 和 `progress-content-*` 日志可直接确定真机事件停在哪一步。

Build 103 Gecko 增量 Release 构建耗时 5 分 05 秒且报告 0 compiler warning；raw
XUL 为 `117922048` B，SHA-256 为
`9d5f2970c5fd115d236fab5dd40dcf7062a087897faa704aaae3561283ff6340`；IPA 内
strip 并签名后的 XUL 为 `59914704` B，SHA-256 为
`18c8ccb8e0dfba6902428e448e4c214a8928e17ba6f2182079cbd573631c5ed5`。
精简 `omni.ja` 为 `2007046` B。Build 103 IPA 为 `34169481` B，SHA-256 为
`4f20cccd599e1d3e06d8431d236f4d6f679ade55f6f7ab223a572f7d3b799332`；解包
完整安装常规文件为 `65905018` B，超过十进制 65 MB `905018` B。对应 prebuilt
zip 为 `45142697` B，SHA-256 为
`66b634dd33e93488f5969f6be473c3a8b870417e621ab4ec09ddd6e07c6db1cf`；canonical
patch SHA-256 为
`b6324788aaea173a74aaac8a4b1ee7e3ce4b4ac27a858010e97888fa3d44b89c`。

Build 103 真机日志把中断点进一步收窄：两个 session 都依次出现
`progress-init-browser`、`progress-attach-skipped` 和 `progress-enable`，但没有紧随其后的
任何 DOM listener、filter 或 attach 记录。`onEnable()` 在 enable trace 后首先构造
`ProgressTracker`，其中会访问 Glean page-load 指标并读取 progressbar pref；UIKit
精简内核不提供完整遥测运行时，因此 tracker 构造异常才是模块一直停在人工
`about:blank` 事件之后的实际原因，之前继续调整 docshell 监听无法触及这个故障点。

Build 104 将三个 Glean stopwatch 改为独立的可降级计时器：指标创建或后续
start/finish/cancel 失败只产生 `progress-telemetry-*` 诊断，不再阻断页面进度；
`page_load.progressbar_completion` 缺失时使用 GeckoView 的兼容默认值 2，站点来源
telemetry 同样隔离。真实 `DOMContentLoaded`、`load`、`MozAfterPaint` 和 `pageshow`
现在同时监听 `<browser>` 与父进程 `contentWindow`，跨 remoteness 切换会重新绑定，
并记录 `progress-trackers-created` 后的完整初始化序列。终止事件按 URI 去重，避免
`load` 和 `pageshow` 为同一页面重复开始、结束进度。

Build 104 Gecko 增量 Release 构建耗时 5 分 05 秒且报告 0 compiler warning；raw
XUL 为 `117922048` B，SHA-256 为
`1aea8d9d75f358601d19d8992fcedb8db739c5947a3b5448847e2ad37dfe21d6`；IPA 内
strip 并签名后的 XUL 为 `59914704` B，SHA-256 为
`44a0a94b7b27a8ef7e88264511f13148a3bdffbad6b328f322caeb05877ae250`。
精简 `omni.ja` 为 `2007398` B。Build 104 IPA 为 `34169850` B，SHA-256 为
`fb83bad88603c4b13e80d8b9317048b5e15148d815d852353c945c2dae7fa594`；解包
完整安装常规文件为 `65905370` B，超过十进制 65 MB `905370` B。对应 prebuilt
zip 为 `45143059` B，SHA-256 为
`187e816a202a2646a74a52b5053f0306084d0ccc9b4932fcf54a8d32c0a94a83`；canonical
patch SHA-256 为
`a42b5ff2722604271f48b440281a7665d9808b58305001d485a003f4d0411ad1`。

Build 104 真机日志确认真实进度链已经恢复，但暴露了完成后的状态机错误。ChatGPT 在
`00:51:20.524` 收到顶层 `load`，随即发送 100% 和 `PageStop`；96 ms 后页面持续
绘制产生新的 `MozAfterPaint`，fallback 在没有活动 tracker 时错误地把任意内容事件
都当成新导航，又发送一次 `PageStart` 并推进到 first-paint 的 80%。这轮伪导航没有
第二个 `load`，因此顶部再次出现并永久停住；Gemini 日志出现了相同序列。重复的
browser/content-window/actor paint 也造成大量无意义诊断输出。

Build 105 收紧内容事件状态机：`MozAfterPaint` 只能推进已存在且 URI 匹配的加载，
永远不能创建 fallback；只有 `DOMContentLoaded` 可以补建正常 fallback，`load` 或
`pageshow` 仅在缺少 start 时执行一次立即完成兜底。完成后的同 URI paint 直接忽略，
同一加载的 first-paint 只记录一次，从而保留真实的 15/55/80/100 进度序列，同时杜绝
真实 `PageStop` 后重新跑到 80% 的第二轮进度。

Build 105 Gecko 增量 Release 构建耗时 5 分 04 秒且报告 0 compiler warning；raw
XUL 为 `117922048` B，SHA-256 为
`e149ea0e5d27216e3965c420698952e3743f23cd3360844f459b347ab3b8290c`；IPA 内
strip 并签名后的 XUL 为 `59914704` B，SHA-256 为
`406e804e215ed0a63e9eb337a146b05feb6cb3e741a93ae595ba7e468514eb1d`。
精简 `omni.ja` 为 `2007489` B。Build 105 IPA 为 `34169956` B，SHA-256 为
`2ba7f59365e9a5970a1274da68d1155fece7343735a1716e76cd58520489da26`；解包
完整安装常规文件为 `65905461` B，超过十进制 65 MB `905461` B。对应 prebuilt
zip 为 `45142665` B，SHA-256 为
`ac6a45bd9bd51352ceba45b9774e17c3d6ad59924df52eeeb2ed69a5f9e67963`；canonical
patch SHA-256 为
`c7566f57ecf4eecd4534c084894445a12a73d142978d439b30fafd99d010b875`。

Build 106 修复运行中切换用户代理后的不完整页面：旧流程对 ChatGPT 和 Gemini
先后发送 `GeckoView:UpdateSettings` 后，在同一 UIKit action 回调里立即并发执行
`LOAD_FLAGS_BYPASS_CACHE` reload；真机日志显示 UA 已生效，但 ChatGPT 的首次刷新
没有完成，随后手动普通刷新才恢复。新流程先原子地更新两边设置并持久化，在下一次
主线程事件循环再让两页走与刷新按钮相同的标准 reload，保留当前 URL、历史、Cookie
和 session，同时避免双 session 的绕缓存导航竞争。本轮不修改 Gecko 源码，raw XUL、
canonical patch、lock、prebuilt 及 manifest 均继续沿用 Build 105。使用 prebuilt 的
Release 构建已通过，包内 XUL 仍为 `59914704` B，SHA-256 仍为
`406e804e215ed0a63e9eb337a146b05feb6cb3e741a93ae595ba7e468514eb1d`；Build 106 IPA
为 `34170258` B，SHA-256 为
`960d6eb2c3ef4d8e29323ee707308dcb3993c434947d24763840fc795a0beb10`，解包完整安装
常规文件为 `65905461` B。

Build 107 保留 SpiderMonkey Baseline Interpreter/JIT、标准 WebAssembly、SWGL、
Intl/CJK、TLS/NSS、HTTP/2、Cookie/LocalStorage/IndexedDB、Service Worker/Cache
API、Fetch/Streams/WebSocket/WebCrypto、文件上传、核心图片解码和 UIKit WebSpeech。
UIKit 下不再进入 Ion 优化层，并通过 `--wasm-no-experimental` 关闭实验性 Wasm
提案；普通 JS、Baseline JIT 和标准 Wasm 仍可用。NSS 改用由 XUL 与 bundled
softoken/freebl 实际导入生成的 UIKit 导出表，不再构建未随 App 分发的 NSS CLI；
动态 HSTS 学习仍保留，内置 preload 表缩为 ChatGPT/OpenAI/Google 根域。TLS session
token 在 UIKit 下以带版本标记的原始记录写入，仍可读取旧 Brotli 记录，从而只移除
无写入消费者的 Brotli encoder。URLPattern 的独立 Rust `regex` 依赖曾做隔离重建，
但 strip/签名后仅相差 32 B，证明 ThinLTO/共享依赖已消除可回收部分，因此没有保留
该实验分叉。

Build 107 正式增量重链耗时 4 分 58 秒且报告 `0 compiler warnings`；raw XUL 为
`114365680` B，strip 后为 `57123608` B，16 KiB 页签名后为 `57253456` B。
prebuilt zip 为 `42906330` B，SHA-256 为
`f98fb459863519b59e4125bafa0eea9927c4c9b50268a00d50b9c9c4b00760f7`；IPA 为
`32164661` B，SHA-256 为
`1afe6a4aa45333af6d215e69b700f91e9266a97fc89d78ba98c2107548e256fb`；解包完整安装
常规文件为 `62948997` B。相对 Build 106，常规文件减少 `2956464` B，但仍高于
十进制 60 MB `2948997` B。按此前真机“App 大小”比同版常规文件高约 5 MB 的实测
差值，这版仍可能显示约 67.9 MB；该数值必须以真机安装为准，不能由 IPA 压缩率推断。
继续逼近真机 65 MB 已没有接近 3 MB 的无损单项：需要另行接受并回归 WebGL、标准
Wasm 或其他网页能力取舍。SWGL 不能再次移除，其缺失已在 iOS 15.5 触发启动
watchdog。

Build 108 在 UIKit 专用构建中继续排除网页无法实际使用的 Web Serial、未接入原生
支付 UI 的 Payment Request，以及 ChatGPT/Gemini 当前不依赖的 WebTransport DOM、
WebIDL 和对应顶层 IPC actor；普通 Firefox 平台保持原有能力。通用 TLS、HTTP/2、
Fetch、Streams、WebSocket 和 Necko 网络实现不变，Service Worker、Cache API、站点
存储、标准 Wasm、Baseline JIT、SWGL 与 UIKit WebSpeech 也继续保留。最终增量
Release 构建成功；raw XUL 为 `113365840` B，strip 后为 `56761784` B，按 16 KiB
页签名后为 `56890928` B。相对 Build 107 的最终签名 XUL 再减少 `362528` B；其中
Web Serial 与 Payment Request 减少 `247200` B，WebTransport DOM/IPC 再减少
`115328` B。`XUL.list` 已不含 `dom/webtransport`，五个 embedding/JIT 导出和 iOS
13.0 最低版本仍通过检查。prebuilt zip 为 `42644934` B，SHA-256 为
`e2beb94e438c9713d1412bfcf8e957364b57a94ff0af01ab53b1dac109e5a9ba`；Build 108
IPA 为 `31997046` B，SHA-256 为
`a1e5d41bfc53af37a198979d6727737a8273eda2d5211d7710a6ad5decf21714`，解包完整
安装常规文件为 `62586468` B，比 Build 107 再减少 `362529` B。canonical patch
SHA-256 为
`de99c889227a4dc809cb7df47e4059ae8e4b69acf20266defb999a8847737d8c`。

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

Firefox 153 的 Taskcluster 配置锁定 Rust 1.94.1；它使用 LLVM 21.1.8，与上述
bootstrap 下载的 Mozilla clang/lld 一致。不要让构建直接跟随会自动升级的
`stable`。安装固定工具链及 iOS target：

```bash
rustup toolchain install 1.94.1 \
  --profile minimal \
  --target aarch64-apple-darwin,aarch64-apple-ios
```

`GeckoPort/build_gecko.sh` 默认通过 `GECKO_RUST_TOOLCHAIN=1.94.1` 选择这套
工具链，在每次 build 前重新 configure，并在工具链或 `aarch64-apple-ios`
target 缺失时立即退出。脚本还会在 objdir 记录 Rust/LLVM 指纹；指纹变化时只
清理 Cargo 的 target/host `release` 目录，保留 C/C++ 对象，防止 Make 静默
复用其他 Rust 版本生成的 `libgkrust.a`。可用下面的命令核对 LLVM 版本；
输出应包含 `release: 1.94.1` 和
`LLVM version: 21.1.8`：

```bash
rustup run 1.94.1 rustc --version --verbose
```

Rust 1.97.1 已切换到 LLVM 22.1.6；若与 Mozilla LLVM 21.1.8 混用
cross-language ThinLTO，最终链接 XUL 会报 `Unknown attribute kind`，不能作为
可复现源码构建工具链。

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

当前体积目标配置在 UIKit 下固定使用 HarfBuzz/OpenType 字体整形，不再保留
Graphite shaping；普通 OpenType、WOFF/WOFF2 和 CJK 排版不受影响，少数依赖
Graphite 智能字体规则的网页字体会按 HarfBuzz/OpenType 规则回退。Graphite 不再
生成不可到达的 wasm2c 沙箱副本；仍会参与网页处理的 Ogg、Expat、WOFF2 解析器
继续使用 RLBox 隔离。JIT/Wasm、UTF-8 与旧编码探测、Cookie/站点存储、HTTP
认证、上传下载、媒体与 WebSpeech 路径继续保留。

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
`prepare_gecko_prebuilt.sh` 会校验结构、内外 manifest、XUL SHA-256/大小、runtime
文件数和 XUL arm64 架构；已展开目录不匹配时会自动从 zip 重建，不能静默复用旧核。

当前 Gecko runtime 最终以
`GeckoPrebuilt/MANIFEST.lock` 为准：

```text
XUL bytes:     113365840
XUL SHA256:    b63b97b06c682b4e3fc00bcc13d015a1c787ff566cd5ee182b774f5cc655e64b
Runtime files: 12
```

对应 prebuilt zip 为 `42644934` B，SHA-256 为
`e2beb94e438c9713d1412bfcf8e957364b57a94ff0af01ab53b1dac109e5a9ba`。从 prebuilt
构建与上面的完整源码构建均使用同一份 XUL manifest；源码构建还会从
`GeckoPort/mozconfig.ios13-arm64`
读取 cross-language ThinLTO、safe ICF 和 MergeFunctions 参数。

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

内嵌引擎基于 Mozilla 的
[`FIREFOX_153_0_4_RELEASE`](https://github.com/mozilla-firefox/firefox/tree/FIREFOX_153_0_4_RELEASE)，
Gecko/Firefox 源文件及其修改继续遵循文件内声明和
[`MPL-2.0`](https://www.mozilla.org/MPL/2.0/) 要求。

最初的 `aarch64-apple-ios` target、UIKit widget、进程/bootstrap、GeckoView
embedding 和 SpiderMonkey JIT 内存适配，部分改编或参考了
[`minh-ton/reynard-browser`](https://github.com/minh-ton/reynard-browser) 的
MPL-2.0 Gecko patches；审计基线固定在
[`a0794ff252c5c52040bb4f7419dba110233d4102`](https://github.com/minh-ton/reynard-browser/commit/a0794ff252c5c52040bb4f7419dba110233d4102)，
并记录于 [`GeckoPort/PATCHSET.lock`](GeckoPort/PATCHSET.lock)。当前
`DualAI-Gecko.patch` 是在该基础上继续修改后、相对锁定 Firefox commit 生成的
完整 canonical delta，并不等同于 Reynard 原 patch 集。DualAI 未复制或链接
GPL-3.0 的 Reynard 浏览器 UI/shell，也不依赖它运行。
