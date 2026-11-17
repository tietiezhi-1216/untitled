# Untitled 开发说明

项目只面向 macOS。Swift Package 与 Xcode 共用源码；应用、package、module、target、scheme 与可执行文件统一为 `Untitled`，Xcode 工程为 `Untitled.xcodeproj`。插件贡献见 [CONTRIBUTING](../CONTRIBUTING.md)。


### 原生界面与 Liquid Glass

主窗口采用 `hiddenTitleBar` 与全尺寸内容，不显示独立的标题条或工具栏，保留原生红黄绿按钮。左侧顶部预留 60 pt 窗口按钮区域，按钮距左侧与顶部各 18 pt，按钮间距 8 pt，搜索框从预留区下方开始；原生按钮宿主仅覆盖左侧，避免挡住正文控件。按钮保留 AppKit 原生对象及激活状态：未激活窗口显示灰色，激活后由系统显示红黄绿，不用自绘圆点模拟。顶部空白区和页面头部可拖动窗口。

侧边栏固定为 224 pt，始终显示且不可拖动调整；主窗口仍支持正常调整尺寸。右侧内容统一使用 28 pt 水平边距。安装、搜索、添加操作等控件在各页面上方保持可见。

插件商店采用 App Store 风格的左侧搜索与分类导航，右侧为两列展示区。页面上方显示标题、蓝色「商店 / 已安装」分段切换和筛选菜单，下方每个插件用图标、名称、分类、作者和胶囊形获取按钮组成条目头部，再展示 1.6:1 宣传大图。列间距 26 pt，行间距 34 pt，窗口变宽仍保持两列；最小 880 pt 主窗口下也保留双列。图片与文案声明来自通用注册数据，界面不按插件 ID 编排。宣传图全部通过 Codex 内置图像工具生成，来源与提示词见 Resources/StoreArtwork/README.md。

窗口采用低透色的中性材质：深色模式以石墨黑为底，浅色模式使用对应的浅灰色，侧栏与正文只有轻微明暗差。原生 `underWindowBackground` 背景保留少量桌面层次，避免壁纸颜色大幅染色。玻璃效果集中在搜索与操作控件；Xcode 26+（或包含 macOS 26+ SDK 的命令行工具）构建时使用官方 `glassEffect`、`.glass` / `.glassProminent`，配合收敛的圆角、选中态细边缘和蓝色重点操作。开启系统“减少透明度”或增加对比度时提高背景遮罩的不透明度。macOS 14–15 或旧 SDK 构建保留兼容样式。

设计依据：[Apple Liquid Glass 采用指南](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)、[材质规范](https://developer.apple.com/design/human-interface-guidelines/materials)。

### 软件本体更新

设置中的“软件更新”与插件商店独立，显示运行版本/构建号、手动检查正式发布版、更新说明与兼容本体包的下载页入口。没有自动轮询、后台下载或自替换安装；发布来源、资源预算及限制见 [软件更新](HOST-UPDATES.md)。

### 构建

```bash
swift build
swift test --no-parallel
python3 scripts/prepare-plugin-resources.py --check
./scripts/build-app.sh release
python3 scripts/package-plugins.py --tag v0.13.0
# 仅在 Release 资产实际发布后，追加 --write-catalog 更新在线商店
```

AppKit 窗口焦点测试请显式串行运行 `swift test --no-parallel`，避免多个界面测试互相抢夺 key window。若 Swift 6.4 命令行工具报告找不到 `TestingMacros`，可显式传入随工具链安装的插件路径（完整 Xcode 通常无需此选项）：

```bash
swift test --no-parallel \
  -Xswiftc -load-plugin-library \
  -Xswiftc /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib
```

构建结果位于 `dist/debug/Untitled.app` 或 `dist/release/Untitled.app`，使用当前 Mac 的架构。命令行与 Xcode 均不启用 App Sandbox，保留系统隐私授权。图标由 `scripts/build-icon.sh` 从选定的裂变原图生成，随应用打包。

内置插件展示信息来自 `Sources/Untitled/Resources/BundledPlugins.json`，Swift Package、命令行应用包与 Xcode 都包含同一资源。修改插件清单后运行 `python3 scripts/prepare-plugin-resources.py`；图像生成与内嵌方式见 [插件协议](../Plugins/README.md#商店展示图标与文档0120)。构建脚本与 CI 会检查资源是否同步。这份资源不安装插件、不改变已发布 ZIP、商店版本与 SHA-256。

公式贴图使用随应用打包的 [KaTeX](../Resources/KaTeX/LICENSE)。静态 WebP 与 WebP 动图编码使用 [libwebp](../Tools/WebPEncoder/LICENSE)：`build-app.sh` 会构建并签名随包的 `img2webp`，首次构建下载固定版本源包并验证 SHA-256，用户运行发行版无需安装 Homebrew 或编码工具。相关许可保留在资源与工具目录。仅运行 Swift Package 可开发基本能力；完整发行功能应使用 `build-app.sh` 生成应用包。

本地智能擦除模型通过截图设置显式下载，下载量为 187 MiB，独立存储在应用支持目录；不包含在主应用或插件 ZIP 内。采用 [LaMa Core ML](https://huggingface.co/mlboydaisuke/LaMa-CoreML)，遵循 Apache-2.0，安装器固定模型版本并校验 SHA-256。图像推理在本机完成，无需云端账号。

为了在后续更新中保留 macOS 对应用身份的识别，建议使用固定的代码签名证书。先将证书及配对私钥导入本机钥匙串，再查看可用身份：

```bash
security find-identity -v -p codesigning
printf '%s\n' '证书的40位SHA-1' > .signing-identity
./scripts/build-app.sh release
```

`.signing-identity` 是仅用于本机的配置，不提交到仓库，也不包含私钥或密码。`scripts/run.sh` 同样读取此配置。配置了证书后，构建会启用 Hardened Runtime、摄像头与麦克风访问 entitlement 和安全时间戳，并在签名校验成功后替换旧构建；证书或私钥不可用时会直接报错，不会退回临时签名。

也可以用环境变量 `UNTITLED_SIGNING_IDENTITY` 覆盖本机配置。未配置身份时保留临时签名，适用于 CI 和首次试用；显式设置为 `-` 也可使用临时签名。临时签名在代码变化后可能无法沿用先前的系统授权。从临时签名切换为证书签名时，需要重新确认系统权限。公开分发仍需使用 Developer ID Application 证书并完成 Apple 公证；此脚本不自动提交公证。

如果切换签名后，系统设置中开关已开启，应用却仍显示未授权，旧记录可能仍绑定临时签名的代码哈希。可先退出应用，仅重置本应用对应的权限，例如 `tccutil reset ScreenCapture com.untitled.app`，再打开当前签名版本，从应用的权限管理重新请求并由用户允许；系统提示时选择退出并重新打开。辅助功能和输入监控对应 `Accessibility`、`ListenEvent`，仅在相应权限出现同样问题时分别处理。无需重置其他软件或所有权限。[Apple 的代码签名说明](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)介绍了系统如何用指定要求识别更新后的应用。

Xcode 开发入口：

```bash
open Untitled.xcodeproj
```

选择 `Untitled` scheme 和 `My Mac` 后按 `⌘R`。Xcode Target 与命令行构建统一采用非 App Sandbox 配置，保留 Hardened Runtime 与摄像头/麦克风 entitlement；系统受保护操作仍需用户授权。`.signing-identity` 只作用于终端构建，Xcode 中需另外配置同一签名身份。正式分发需配置自己的签名和公证。

Swift Package 与 Xcode 工程共用 `Sources/Untitled`。新增宿主源码时，请同时将文件添加到 Xcode target；测试通过 Swift Package 执行。GitHub Actions 验证测试、插件打包和 Xcode 构建。

发布完成后，可额外执行真实 GitHub 下载与安装检查：

```bash
UNTITLED_NETWORK_TEST=1 swift test --filter downloadFromPublishedGitHubCatalog
```

## 目录

```text
Sources/Untitled/
├── App/         # 窗口、菜单栏和统一外观
├── Capture/     # 截图、编辑、贴图、滚动拼接、录制、OCR、文档导出与本地模型
├── Models/      # 应用外观设置
├── Plugins/     # 插件规范、目录、ZIP 安装和配置存储
├── Sharing/     # 双 Mac TLS 配对、键鼠接力与按需虚拟麦克风同步
├── SpeechInput/ # 豆包游客双通道 ASR、麦克风、范围校验与非激活听写浮条
├── Runtime/     # 通用动作执行与 Carbon 全局热键
└── Views/       # 原生商店、插件配置、录制器与设置
Plugins/         # 所有插件源码及统一商店目录
Tests/           # 安装、校验、热键、布局、图像处理、拼接、识别和媒体导出检查
Resources/       # Info.plist、权限声明、应用图标与本地公式渲染资源
Tools/           # 随包的 WebP 编码器与独立 HAL 虚拟麦克风源码/安装器
scripts/         # 本地构建与插件打包
```

## 数据与兼容标识

当前开发版使用 `com.untitled.app` 作为 Bundle ID、偏好与应用支持目录命名空间；内置插件使用 `com.untitled.*`，Keychain 与音频驱动也使用新身份。历史数据迁移、冲突备份、系统重新授权及双机升级要求见 [IDENTITY-MIGRATION.md](IDENTITY-MIGRATION.md)。应用支持目录不在仓库内。普通 `swift run` 不会生成图标和 helper，完整体验使用 `scripts/run.sh`。品牌资源见 [BRANDING.md](BRANDING.md)。

## 验证范围

每个插件都按 [性能规范](PERFORMANCE.md) 检查资源消耗。高开销路径记录正常、上限、持续运行、取消和反复启停下的基线、峰值与回收，使用对应分析工具定位问题；不以功能测试代替性能测量。

0.12.0 图文商店在 Mac18,5 / 16 GiB / macOS 27.2 的 Release 应用上记录了 3 次空闲样本，间隔 3 秒：RSS 均为 80,064 KiB（约 78.2 MiB），`ps` CPU 报告值均为 0.0%，累计 CPU 时间保持 0:00.49。图片加载、分类、搜索、最小宽度双列与深浅色布局采用原生视图渲染验证；宣传图缓存通过 24 次不同键的真实 JPEG 解码检查，始终不超过 12 MiB / 16 项，预取消请求不解码。页面在消失时清空持有的图片，解码由单一 actor 串行完成。相关协议、兼容、权限和布局共 52 项检查完成（其中联网安装默认跳过，随后单独开启并通过）。本机更新后，原有三个插件的操作、快捷键、启停状态与初始化标识的指纹一致。上述快照不代表进程峰值、GPU / I/O 峰值或多轮真实窗口启闭后的长期回收；这些指标未测，完整 Xcode 构建仍未在本机执行。高分辨率生成原图只保留在仓库，不随应用加载，素材与完整提示词见 [StoreArtwork](../Resources/StoreArtwork/README.md)。

0.11.0 商店初版网格布局在 Mac18,5 / arm64 / 16 GiB / macOS 27.2 上使用 Release 构建做了空闲快照：商店加载完成后按 3 秒间隔取得 3 次 `ps` 样本，RSS 均为 74,016 KiB（约 72.3 MiB），CPU 报告值均为 0.0%，累计 CPU 时间保持 0:00.49。该快照是整应用的短时观察，不能归因到单个插件或代表峰值与长时趋势。深浅色 655 / 815 / 1055 pt 内容区、长作者名称截断、两列以上布局及 README 阅读采用实际 NSHostingView 渲染验证；后续单列版在相同三种内容区宽度完成布局检查，确认顶部控件同排、插件一行一个及长作者截断；单列版性能指标未重测。旧配置的操作与启停指纹在本机更新后保持一致。商店公开目录的联网下载与隔离安装检查通过。未测项：十轮真实详情启闭的 Release 回收趋势、GPU 与 I/O 峰值，以及录音、录屏和双 Mac 键鼠业务路径的本次性能回归。完整 Xcode target 编译在本机缺少 Xcode，新增源码与资源已同步 target 并通过工程 plist 检查。

没有完整 Xcode 的机器可以执行 Swift Package 构建、测试、ICNS 与 plist 检查，但不能声称已通过 Xcode target 编译。双 Mac 键鼠、驱动、录音和真实媒体质量按相应插件说明验收，不以单机自动测试替代。

## 发布次序

先固定源码提交，完成测试、Release 构建、插件包与完整 Xcode CI，再从同一个提交生成应用 ZIP。确认包中版本、架构、图标、许可证和签名，生成 SHA-256；发布资产不能混入 `dist/plugins/` 中旧版本的历史 ZIP。

正式分发使用 Developer ID 与 Apple 公证，公证后将票据 staple 到应用再生成最终 ZIP。公证使用独立的 notarytool 认证配置，签名证书不能代替该认证。缺少公证或完整真机验收的版本可以作为明确标注限制的预览版发布，不宣称已通过 Gatekeeper 或全部性能验收。

先上传本版本对应的应用与插件资产并验证实际下载，再更新 `Plugins/catalog.json` 和 main，最后验证商店目录的真实下载与安装。标签指向构建提交，目录更新单独提交；不移动旧标签或替换已发布的同版本资产。发布说明列出验证范围、签名 / 公证状态、架构与已知限制。
