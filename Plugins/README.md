# 插件开发协议 v2

本仓库接收各种用途的插件，清单放在 `Plugins/<plugin>/`；插件也可以有独立源码仓库与 GitHub Release。首页商店读取 `Plugins/catalog.json` 并核对 SHA-256，用户也可以直接安装离线 ZIP。包根目录仅允许 `manifest.json`、`README.md`、`LICENSE`。

开发流程见[项目 skill](../.agents/skills/untitled-plugin-development/SKILL.md)，共享与二次开发要求见[贡献规范](../CONTRIBUTING.md)，高权限和完全接管的实现边界见[权限规范](../docs/PERMISSIONS.md)。

0.4.0 起，插件声明自己的界面布局。宿主提供槽位、组件注册、命令分发、面板路由、安装与存储；不根据插件 ID 或动作类型决定 v2 插件的页面。参考完整的[截图清单](screenshot/manifest.json)、[快捷键清单](global-shortcuts/manifest.json)及 [JSON Schema](manifest-schema.json)。

每个插件都需遵循[性能规范](../docs/PERFORMANCE.md)，说明资源开销与停止后的清理；高内存或高计算负载功能需定义预算并记录可复现的基线、峰值和回收结果。不能将宿主整体占用直接当作单个插件的占用。

## 清单

| 字段 | 用途 |
| --- | --- |
| `schemaVersion` | 新插件使用 `2`；`1` 包通过兼容适配器继续使用 |
| `id` | 唯一标识，小写字母、数字、点和连字符 |
| `name` / `summary` / `author` | 商店和插件信息 |
| `version` / `minimumHostVersion` | 三段数字；v2 最低宿主为 `0.4.0` |
| `repository` | 插件真实的 HTTPS GitHub 源码仓库；同仓库插件使用 `https://github.com/tietiezhi-1216/untitled` |
| `actions` | 允许使用的动作能力，无重复项 |
| `templates` | 用户添加操作时的模板，包含 `id`、`title`、`action` |
| `permissions` | 0.5.0+ 插件显式声明所需权限；无需权限时为 `[]` |
| `ui` | 界面协议：`version: 1`、可选 SF Symbol `icon`、`slots` 和 `panels` |
| `styles` | 0.13.51+ 可选的版本化样式数据；仅能使用该插件已声明动作对应的注册样式，例如 [`doubao.hud`](doubao-speech-input/README.md#独立更新浮条样式) |
| `icon` | 0.11.0+ 商店、侧栏和页头共用的图标：`symbol`、`tint` 与可选内嵌 PNG |

支持动作：`openApplication`、`openURL`、`runShortcut`、`showMainWindow`、`captureRegion`、`captureWindow`、`captureScreen`、`captureScrolling`、`captureRecording`、`pinSelection`、`togglePins`、`captureHistory`。安装、注册界面或加载清单不会执行这些动作；显式声明的默认操作会在安装时注册快捷键。

0.13.1+ 支持 `pinSelection`，由截图选区窗口处理已配置的贴图键。其他截图全局快捷键以非独占方式注册。宿主内同一组合键只能绑定一个启用的操作。两个应用以非独占方式注册同一键位时都可能响应，独占注册方可能先收到按键。让出键位后可通过「暂停截图快捷键 → 恢复截图快捷键」重新注册。

0.9.0+ 另支持 `sharePeripherals`、`switchPeripheralControl`、`stopPeripheralSharing`，由独立 `SharingPluginUIProvider` 注册 `sharing.dashboard` / `sharing.status` 组件和 `sharing.toggle` / `sharing.switch` / `sharing.stop` 命令。参阅[外设共享清单](peripheral-sharing/manifest.json)与[双机使用说明](peripheral-sharing/README.md)。原生服务按插件身份惰性创建、通过自身的宿主权限客户端检查权限；安装或启用不启动共享，禁用、卸载或退出立即释放。虚拟音频驱动独立于声明式 ZIP，安装只能由本机用户明确执行。

0.13.51+ 支持原生[无线麦](wireless-microphone/README.md)。`shareWirelessMicrophone` 能力注册 `wirelessMicrophone.dashboard` 组件和 `wirelessMicrophone.toggle` 命令。无线麦使用独立配对，发送端通过插件身份检查麦克风权限，接收端由用户显式安装虚拟音频驱动。

0.9.8+ 支持原生[豆包语音输入](doubao-speech-input/README.md)：`toggleDoubaoDictation`、`holdDoubaoDictation`、`cancelDoubaoDictation`，以及 `doubao.dictation` / `doubao.preferences` 组件、`doubao.toggle` / `doubao.cancel` 命令。清单使用最低宿主 0.9.8；切换与按住两种操作各自使用通用默认模板，普通按键与独立修饰键按各自通道分派按下 / 松开事件，重绑、停用会结束未松开的动作。安装或渲染界面不录音、不联网；实际采集与实时输入通过绑定插件身份的麦克风 / 辅助功能权限客户端检查。禁用、升级、卸载和退出停止本插件的设备、连接、任务与非激活浮条。ZIP 不携带动态原生代码。

0.13.38 / 语音输入 1.2.9 起，无需预先聚焦输入框即可开始。实时草稿只更新非激活气泡；收到定稿后才定位此刻的可编辑输入框并尝试插入一次，没有安全目标或未获写入确认则复制完整定稿。取消或没有定稿不动剪贴板，不安装 / 切换输入法。未改选的设备、命令绑定和历史不迁移；默认在本机保留最近 100 条定稿，可调上限或清空。

## 商店展示、图标与文档（0.12.0+）

商店采用 App Store 风格：左侧提供搜索、插件商店和「我的插件」快捷入口，不另设已安装页，右侧为两列图文卡片。每张卡片上方显示图标、名称、作者和「获取 / 打开 / 更新」按钮，下方展示宣传图。点击图标、名称或宣传图打开 README 与信息详情；没有评分与下载量来源时不显示虚构数值。筛选菜单提供排序、仅未安装、刷新与 ZIP 导入，安装和打开不自动采集或申请系统权限。

名称直接表达用途，完整能力、权限、兼容限制和使用步骤写入 README。内置名称为「快捷键」「语音输入」「截图」「键鼠共享」「无线麦」；插件 ID、操作 ID 与用户配置保持稳定。

```json
"icon": {"symbol": "waveform", "tint": "#D77A36", "png": "<base64 PNG>"},
"storefront": {
  "category": "语音与文本",
  "categorySymbol": "waveform",
  "headline": "说出来，\n就成文字",
  "caption": "快捷键实时听写；识别历史可复制",
  "jpeg": "<base64 JPEG>"
}
```

`icon` 的 `symbol` 为 1–80 字的 SF Symbol 名称，`tint` 为 `#RRGGBB`；`png` 可省略以使用运行时符号回退。图标图片必须为 32–256 像素的正方形静态 PNG，文件不超过 64 KiB；清单整体不超过 256 KiB。`ui.icon` 继续作为旧版符号回退。

`storefront` 为可选展示声明，需要最低宿主 0.12.0。`category`（1–24 字）和 `categorySymbol`（SF Symbol）保留用于兼容现有清单；商店不按分类展示或搜索。`headline` 为 1–60 字，`caption` 最多 120 字，由原生界面绘制。可选 `jpeg` 为内嵌的静态横向 JPEG，最大 96 KiB，宽 400–1200、高 256–800 像素、总像素不超过 960,000。目录可携带同样的 `icon` 与 `storefront`；整个目录下载上限为 2 MiB。未声明宣传图时用图标和中性底色回退，不进行远程图片请求。

当前四个内置插件的图片全部使用 Codex 内置图像工具生成，原图、实际提示词和缩略流程见 [StoreArtwork](../Resources/StoreArtwork/README.md)。更新图片时先生成并保存选中原图，再制作缩略资源；不以代码绘制图片替代生成图片。运行 `python3 scripts/prepare-plugin-resources.py --embed-artwork` 将 `Icon.png`、`Preview.jpg` 内嵌到清单，再运行 `--check` 检查同步。ZIP 根目录仍只包含 `manifest.json`、`README.md`、`LICENSE`。独立插件使用同样声明，无需中央仓库或特定插件 ID。

README 使用 UTF-8 Markdown，最大 128 KiB，包含用途、步骤、权限、网络与数据、兼容边界和许可证。原生阅读器支持标题、段落、列表、代码块、表格和链接；超大表格以等宽文本完整显示。它不执行 HTML、脚本或自动加载远程图片。安装时原子保存该包的 README，可离线阅读；未安装或旧配置缺少说明时，从相应目录包下载、校验并补读。独立插件建议使用完整 HTTPS 链接。

`Sources/Untitled/Resources/BundledPlugins.json` 从清单生成，提供内置插件的名称、简介和图片兼容展示，不安装插件或改写版本、动作、授权、热键及启停状态。它只匹配相同 ID、源码仓库及不高于宿主声明版本的插件；实际 README 始终来自被查看的包。

资源预算：图标缓存最多 64 项、成本预算 4 MiB；宣传图由独立 actor 串行解码，最长边 832 像素，显式 FIFO 缓存最多 16 项且总成本不超过 12 MiB。可见卡片按需读取，离开可视区域取消加载并清空页面图片；缓存以外同一时刻仅解码一张图。最多缓存 8 份 README、每份不超过 128 KiB。高分辨率生成原图不进入应用包，不创建空闲轮询或图片动画时钟。缓存边界与取消检查不等同于整应用的总内存或长期 GPU 验收，实测及未测范围见开发说明。

## 通用槽位

每个槽位是有序数组，省略或空数组即不显示；只有根布局 `content` 必须非空。数组顺序就是显示顺序。

| 槽位 | 位置 |
| --- | --- |
| `header.leading` / `header.trailing` | 页面顶部左右两侧 |
| `toolbar.leading` / `toolbar.trailing` | 内容上方的左右操作区 |
| `content` | 主内容，组件可自行处理滚动、网格、表单和编辑器 |
| `footer.leading` / `footer.trailing` | 页面底部两侧 |
| `menuBar` | 系统菜单栏里的插件子菜单 |

**宿主内容边界（0.9.7+）**：软件本体为插件主内容提供左右各 28 pt、上下各 16 pt 的固定留白，内容与页面标题、工具栏、页脚对齐。宿主显式限定可用尺寸并裁剪越界绘制，插件的固定尺寸或偏移不能把面板画进外侧留白。组件只负责内部卡片/行间距，无需再补整页边距。标签页和内嵌面板继承已有边界，不重复叠加；独立 sheet/popover 会建立自己的边界，调整窗口大小后仍有效。宿主注册的原生组件可在单组件根布局中使用外侧留白放置圆头滚动条，正文仍保留自己的边距。截图历史和商店首页共用内收的样式，有溢出时滑块常显。原生组件若兼顾独立使用，可读取 `EnvironmentValues.pluginContentHasInsets` 避免重复留白；清单不提供取消宿主边界的开关。

插件可以自行选择标题、图标、启停、更多、简介、设置按钮的位置。宿主组件不会自动插入；不声明就不显示。应用级设置始终在侧边栏底部和 macOS 应用菜单中，不占用插件槽位。

**插件操作栏（0.13.2+）**：根布局的 `header.trailing` 使用统一的 32 pt 圆形图标按钮。声明式 `button` 与 `menu` 用 `symbol`（或命令提供的图标），名称保留作提示和辅助功能标签；菜单中的条目仍显示名称。0.13.16+ 由宿主在按钮下方显示悬停标签（包括不可用的命令按钮），打开菜单、点击或移出时收起，不占用版面。原生自定义组件、正文、嵌套面板和普通 `toolbar.*` 槽位不变。`host.more` 排在操作栏末尾并提供启停；旧清单同时声明两者时不再渲染右上角的独立开关。若只声明了 `host.enabled`，右上角会提供可启停的管理菜单。

每个元素必须有全局唯一 `id` 和一种 `kind`：

| `kind` | 声明 |
| --- | --- |
| `component` | `component: "命名空间.组件"` |
| `button` | `command` 或 `panel` 二选一，可加 `title`、`symbol`、`style` |
| `menu` | `title` 与 `items`，内部支持按钮与子菜单 |
| `panel` | 在 `content` 内嵌一个已定义的 `panel` |
| `tabs` | 在 `content` 放置分段页面切换，`panels` 为面板 ID 数组；`style: "plain"` 在 0.13.4+ 使用紧凑的左对齐分段控件 |

命令按钮默认使用命令提供的动态名称和图标，例如录屏中的“停止录屏”。`title` / `symbol` 可覆盖默认值；仅图标的面板按钮省略 `title`。`style` 可选 `plain`、`standard`（默认）、`prominent`。菜单栏只支持命令按钮和菜单。

`ui.panels` 中每个面板有 `id`、`title`，并选择 `component` 或 `slots` 二选一。面板内也能组合上述槽位（不含 `menuBar`）；可选 `width` 320–1200、`height` 240–900，默认 660 × 560。面板按钮的 `presentation` 支持：

- `sheet`：打开插件内的设置或配置弹窗，默认方式。
- `popover`：锚定按钮的浮层。
- `inline`：切换已有分段页，或在主内容打开面板并提供返回。

例如，插件可以自行把设置按钮放在顶部，把操作列表放进内容区：

```json
{
  "version": 1,
  "icon": "puzzlepiece.extension",
  "slots": {
    "header.leading": [{"id": "title", "kind": "component", "component": "host.identity"}],
    "header.trailing": [{"id": "configure", "kind": "button", "symbol": "gearshape", "panel": "preferences", "presentation": "sheet"}],
    "toolbar.trailing": [{"id": "add", "kind": "component", "component": "host.addCommand"}],
    "content": [{"id": "list", "kind": "component", "component": "host.commands"}]
  },
  "panels": [{"id": "preferences", "title": "插件配置", "component": "host.commands"}]
}
```

安装前会校验槽位、全局唯一 ID、注册引用、能力要求、面板循环及深度。最多 160 个元素、24 个面板、12 个分段页，菜单嵌套最多 3 层；内嵌面板最多 8 层，每个面板展开后的内容最多 1024 项。清单上限 256 KB，ZIP 上限 2 MB。未知组件/命令或未声明所需动作时拒绝安装并保留已有配置。

## 组件与命令注册

原生模块实现 `PluginUIProvider`，在应用组合入口 `App/PluginComposition.swift` 注册。渲染器只访问注册表；新增原生界面不需要给 `ContentView` 添加插件分支。

```swift
struct ExampleProvider: PluginUIProvider {
    func register(in registry: PluginUIRegistry) {
        registry.component("example.panel", requiredActions: [.showMainWindow]) { context in
            AnyView(ExampleView(pluginID: context.pluginID))
        }
        registry.command("example.show", requiredActions: [.showMainWindow], presentation: { _ in
            .init(title: "打开面板", symbol: "macwindow")
        }) { context in
            context.store.showMainWindow()
        }
    }
}
```

`PluginUIContext` 提供插件 ID、当前配置、宿主服务和面板导航。组件获得同一 `PluginStore` 环境对象；命令运行时再次检查插件启停、声明的能力和动态可用状态。命令可提供 `updates` publisher，让录屏状态等在所有槽位及菜单栏中同步刷新。设置面板在插件停用后仍可打开，执行命令会被禁用。

| 内置组件 | 用途 / 所需动作 |
| --- | --- |
| `host.icon` / `host.identity` | 插件图标、名称和版本 |
| `host.enabled` / `host.more` / `host.info` | 启停、权限与能力和源码/卸载菜单、插件详情 |
| `host.commandHeading` / `host.addCommand` / `host.commands` / `host.commandStatus` | 操作标题、添加、列表、状态提示 |
| `host.compactCommands` | 紧凑操作列表（0.13.4+）；点击一行编辑，执行与删除位于右键菜单 |
| `capture.history` / `capture.status` | 截图历史、数量；需要 `captureHistory` |
| `capture.preferences` | 截图设置；需要 `captureRegion` |
| `capture.options` / `capture.localShortcuts` | 截图通用设置、编辑与贴图快捷键（0.13.5+）；需要 `captureRegion` |

命令：`host.openPlugin`；`capture.region`、`capture.window`、`capture.screen`、`capture.scrollVertical`、`capture.scrollHorizontal`、`capture.record`、`capture.pinSelection`、`capture.togglePins`、`capture.history`、`capture.importImage`。分别需要相应截图动作；导入需要 `captureRegion`。

当前 ZIP 是声明式扩展包，可自由组合已注册的原生能力与界面。新增原生能力由 `Plugins/<slug>/Sources/` 自己实现，在组合入口登记组件、命令及生命周期；Swift Package 和 Xcode 将信任的内置模块编入应用。本版不动态加载 Swift 二进制、JavaScript 或 Shell。v1 包只在兼容适配器中生成旧版布局，v2 原样采用清单中的布局。见 [宿主与插件边界](../docs/PLUGIN-BOUNDARY.md)。

## 文件、剪贴板与本地通知（0.13.53+）

清单使用 `minimumHostVersion: "0.13.53"` 或更高版本。声明所需的 `actions` 后，可选择在本插件的槽位放置对应命令或组件。

| 动作 | 插件入口 | 行为 |
| --- | --- | --- |
| `revealFile` | `native.revealFile` 命令或自定义操作 | 选择文件或文件夹，在 Finder 定位 |
| `shareFile` | `native.shareFile` 命令或自定义操作 | 选择文件，打开 macOS 的分享选单 |
| `readClipboardText` | `native.readClipboardText` 组件或原生调用 | 读取最多 16 KiB 的纯文本并交给插件 |
| `copyText` | `native.copyText` 组件或自定义操作 | 将指定的纯文本写入剪贴板，最多 16 KiB |
| `sendNotification` | `native.sendNotification` 组件或自定义操作 | 发送一条本地通知，须声明 `system.notifications` 和用途 |

原生 provider 通过 `context.nativeCapabilities` 取得绑定插件身份的客户端。客户端在调用时检查清单、插件启停和该能力的本地开关。通知发送前还会查询 macOS 授权。文件命令运行时由用户在系统窗口选择。复制和通知操作的内容由用户配置，通知快捷操作使用标题。读取剪贴板的结果由组件或 provider 接收。

用户从插件的「更多 → 权限与能力」或左侧插件条目的右键菜单进入设置。该页展示当前插件的声明、权限用途和授权状态。文件、剪贴板与通知能力各有本地开关，开关随插件配置存储。

## 宿主权限服务（0.5.0+）

系统权限由 macOS 授予主应用。插件清单声明用途，宿主在插件的「权限与能力」中提供状态、授权和跳转系统设置的入口。原生 provider 通过宿主权限客户端检查权限。

```json
"permissions": [
  {"id": "system.screenRecording", "reason": "截图和录屏"},
  {"id": "system.camera", "reason": "录屏摄像头画中画", "optional": true}
]
```

显式声明需要 `minimumHostVersion: "0.5.0"` 或更高；此版本及以上的插件必须包含 `permissions`。最多 32 项，ID 无重复，每项用途 1–240 字。`optional` 表示按功能选项使用，默认 false；所有权限仍然在实际操作时检查，不会因为安装或启用插件就请求授权。旧包通过原生能力的兼容声明继续使用。

当前宿主管理：`system.screenRecording`、`system.accessibility`、`system.inputMonitoring`、`system.camera`、`system.microphone`、`system.notifications`。普通全局键盘快捷键采用 Carbon 注册，不需要输入监控或辅助功能授权。全局鼠标侧键使用单独的鼠标事件监听，需要宿主的辅助功能授权，不要求开启键盘优先模式。

宿主 0.13.3+ 可由用户从菜单栏 Untitled →「快捷键」→「优先使用插件快捷键…」明确开启优先模式；0.12.1–0.13.2 的入口在应用通用设置。这是独立的宿主命令触发模式，使用辅助功能授权的 active event tap，不修改清单、默认绑定或插件权限，也不向插件提供原始输入。匹配时尝试阻止下游响应；安全输入及其他过滤器可能限制优先级。按键重绑、录制、停用和退出均清理逻辑动作，共享交接/控制期间普通快捷键让行，失败显示回退状态。权限边界与预算见[宿主优先模式](../docs/PERMISSIONS.md#宿主快捷键优先模式0121)。

插件只调用绑定到自身身份的客户端：

```swift
try context.permissions.require([.camera])
// 主应用验证插件是否启用、是否声明该权限，以及当前系统状态。
// 缺少权限时打开当前插件的权限与能力，并抛出 HostPermissionError。
```

缺少权限时不会直接弹出系统授权框。主应用显示请求来源和状态，具体用途可通过信息按钮查看，用户点击「授权」才调用系统请求 API；拒绝或受限制时通过系统设置处理。授权后用户重新执行操作，不自动启动录屏或设备。不要捕获错误后继续读取受保护数据；宿主命令入口会统一处理权限错误。

业务选项（麦克风录制、画中画、按键显示等）保留在插件设置中；开启选项不会立刻请求系统权限。自动滚动在实际开启时请求辅助功能，手动滚动不需要。录屏停止操作不因权限被撤销而受阻。

`HostPermissionCenter` 接收 `HostPermissionDriver` 注册，驱动提供描述、状态查询、系统请求和设置跳转。新增系统能力由宿主注册驱动并检查必要的 Info.plist / entitlement；无需修改插件面板或统一权限管理界面。状态不持久化为“已授权”，返回应用或点击刷新时重新查询系统。未知、未声明或已停用插件的请求不会触发系统授权。

系统权限由 macOS 最终确认和撤销，主应用不修改 TCC 数据库。屏幕录制、辅助功能和输入监控的 preflight 只提供是否已授权，界面使用「未授权」而不推断是否曾拒绝。摄像头与麦克风采用系统的精确授权状态。参阅 Apple 的 [媒体授权状态](https://developer.apple.com/documentation/avfoundation/avcapturedevice/authorizationstatus(for:))、[辅助功能信任检查](https://developer.apple.com/documentation/applicationservices/1459186-axisprocesstrustedwithoptions)、[输入监控请求](https://developer.apple.com/documentation/coregraphics/cgrequestlisteneventaccess())。

## 发布

```bash
python3 scripts/package-plugins.py --tag v0.10.0
# 同仓插件使用独立标签，独立仓库也可以使用自己的版本标签
python3 scripts/package-plugins.py --tag plugin-my-plugin-v1.0.0 --plugin my-plugin
python3 scripts/package-plugins.py --tag v1.0.0 --plugin my-plugin --repository alice/my-plugin
```

脚本默认只生成本地 ZIP 和 catalog，不上传、不修改在线目录。`--plugin` 可重复使用，支持插件目录或仓库内 slug；仓库外目录必须带自己的 README 与 LICENSE。优先采用插件自己的 LICENSE，仓库内未提供时才继承根 MIT。

上传 ZIP 到对应 Release，资产实际可下载后再更新 main 的商店目录。统一全量打包可追加 `--write-catalog`；局部和独立仓库打包禁止覆盖中央目录。中央目录也可人工收录独立 GitHub Release，必须核对 ID、版本及 SHA-256。不要替换已发布的同版本资产；修改清单、说明或许可导致包变化时递增插件版本并重新生成校验值。历史目录引用旧仓库名的 Release 保持原校验值，依赖 GitHub 仓库改名重定向继续下载。

本地配置位于 `~/Library/Application Support/com.untitled.app/Plugins/<id>.json`。升级替换清单并保留用户操作与启停状态；禁用释放快捷键，卸载删除该插件配置。配置不会随源码发布。


### 默认动作（宿主 0.6.0+）

模板可选声明 `installByDefault: true` 和 `defaultHotKey: {"keyCode":18,"modifiers":4096,"key":"1"}`。键码使用 macOS 虚拟键码，修饰键使用 Carbon 位掩码；原有组合键格式与标识不变。默认动作不能要求用户先填写目标，同一清单的默认绑定不能重复。旧格式默认动作要求 `minimumHostVersion` 至少为 `0.6.0`。

**0.13.29+**：所有插件的全局操作默认可绑定普通单键（例如 Space、F8、A）、组合键（包括仅加 ⇧）或鼠标侧键。键盘示例：`{"keyCode":100,"modifiers":0,"key":"F8"}`；第一枚侧键：`{"mouseButton":3,"modifiers":0}`，第二枚为 4，也可加修饰键。侧键编号使用系统 button number 3–31，不包括左、右、中键。**0.13.31+** 另支持独立右 ⌘（`{"keyCode":54,"modifiers":0,"key":"右 ⌘"}`，属于 `singleKey`，随包预设时最低宿主也须为 0.13.31）。**0.13.32+** 支持独立右 ⌃（`{"keyCode":62,"modifiers":0,"key":"右 ⌃"}`）。按住类动作单独持键约 0.2 秒才启动，其他动作单独松开时触发；组合键始终放行。语音 1.2.4 将右 ⌘作为「按住说话」的默认键，其他操作可改为右 ⌃。独立修饰键只订阅修饰键状态变化，不读取组合键中的字符；其余独立修饰键或硬件媒体功能不是普通键盘按键；系统保留或鼠标驱动改写的输入未必能到达应用。键盘和鼠标不共用冲突标识。按住/松开由操作决定，录制器收到匹配的松开才完成绑定。

插件可以在 v2 清单顶层声明 `"shortcutInputs":["keyCombination"]` 等白名单；取值为 `singleKey`、`keyCombination`、`mouseButton`，省略即全部允许，空数组仅停用快捷键而不禁止手动运行。声明白名单或随包预设新类型需要最低宿主 **0.13.29**；用户在新版中给既有插件重绑不必升级插件。更严格的插件升级不会删除原绑定，而会停止注册并在操作旁显示原因。原生 provider 也可验证命令的业务约束。

宿主安装或升级时按模板 ID 初始化一次；已编辑、清空、停用或删除的默认操作在后续升级中保持原样。旧配置会按动作匹配到模板，保留原操作 ID。冲突时不会覆盖其他操作，新动作不绑定并显示提示。`host.restoreDefaultCommands` 命令显式恢复默认模板，保留其他自建操作。此机制对所有插件通用。

截图新增组件 `capture.pins` 和命令 `capture.delayed`、`capture.copy`、`capture.repeatRegion`、`capture.restorePin`、`capture.cycleGroup`、`capture.closePins`、`capture.hideOtherPins`、`capture.clickThrough`、`capture.pinFiles`、`capture.toggleHotKeys`。它们仍由清单选择槽位，主应用不指定插件的面板布局。
