# Untitled · Agent 开发约定

Untitled 是由用户通过 agents 持续定制的原生 macOS 软件。功能以可选择、可安装、可共享和可二次开发的插件提供；宿主承担插件安装、界面组合、配置、权限和生命周期。需求没有预设的功能类别限制。

## 入口

- 插件开发、调试与打包：先读 [.agents/skills/untitled-plugin-development/SKILL.md](.agents/skills/untitled-plugin-development/SKILL.md)。这是随仓库分发的项目 skill。
- [Plugins/README.md](Plugins/README.md)：清单、UI 槽位、provider、默认动作和包格式。
- [CONTRIBUTING.md](CONTRIBUTING.md)：接收插件、独立分发、许可证和二次开发规则。
- [docs/PERMISSIONS.md](docs/PERMISSIONS.md)：权限及完全接管的实现要求。
- [docs/PERFORMANCE.md](docs/PERFORMANCE.md)：每个插件的性能预算、内存 / CPU / GPU / I/O 排查与回归验证。
- [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)：构建、签名、界面约定及平台验证。

## 技术边界

- 只支持 macOS。Swift 6、SwiftUI / AppKit，部署最低 macOS 14；较新 API 保留相应 availability 检查。开发和打包使用所选工具链的 macOS 26 或更新的 SDK，并校验产物实际链接的版本。不增加其他系统适配层。
- 清单在 `Plugins/<slug>/`；通用清单模型在 `Sources/UntitledPluginSDK/`，宿主存储和系统接口在 `Sources/Untitled/`，内置模块只在 `Sources/Untitled/App/PluginComposition.swift` 组装。
- 原生插件的源码、资源和专用工具归 `Plugins/<slug>/`。插件注册自己的视图、动作、状态与生命周期；宿主只做通用调度和系统能力授权，不按插件 ID 硬编码页面、操作或启停逻辑。见 [宿主与插件边界](docs/PLUGIN-BOUNDARY.md)。
- 当前 ZIP 是声明式包，仅允许根目录 `manifest.json`、`README.md`、`LICENSE`。新增原生能力随宿主编译。任意代码加载、agent 执行器及完全接管是独立的运行时工作，未实现时不得宣称可用。
- 命令行与 Xcode 构建均不启用 App Sandbox，保留系统授权与 Hardened Runtime。系统能力通过统一 driver 和绑定插件身份的客户端接入。
- 原生 provider 同进程运行；权限声明是宿主接口约束，不是对恶意原生代码的隔离沙盒。共享与独立分发不代表自动获得系统权限。

## 实现与兼容

- 开始前看 `git status --short`。保留已有未提交改动，不用 reset、clean 或整文件回退覆盖其他工作。
- 产品、Swift package、应用 target / scheme 和可执行文件统一为 `Untitled`，内部 Swift 模块用 `Untitled` 前缀，仓库名 `untitled`，工程 `Untitled.xcodeproj`。应用命名空间 `com.untitled.app`，内置插件 `com.untitled.*`，环境变量 `UNTITLED_*`；不新增旧命名别名。历史身份仅用于显式的数据迁移与驱动清理，规则见 [迁移说明](docs/IDENTITY-MIGRATION.md)。
- 新插件使用自己的命名空间；fork 独立分发时换插件 ID，保留作者与许可。版本、模板 ID、命令 ID 稳定，升级不重置用户配置。
- 安装、启用、打开界面不自动启动采集、远端控制、安装 helper 或申请整套权限。长任务可取消；禁用、卸载和退出释放自身热键、监听、连接与任务。
- Swift 6 的 actor 和 Sendable 问题按真实所有权解决，不靠普遍添加 `@unchecked Sendable` 或忽略错误。
- 密钥放 Keychain；源码、清单、包和日志不含个人路径、配对信息或用户内容。错误提供恢复路径，输出与配置有原子替换或等效的失败保护。
- Xcode 直接链接同一 Swift Package 组合产品；新增 App 源码放入其所属 target，不在 Xcode 重复加入。独立实验输入法 target 仍需同步工程。新增字段、动作、权限同步 Swift 校验、JSON Schema、说明和相关验证。
- 每个插件都检查空闲与停用后的开销；高内存、模型、图像、音视频、批处理等路径先定义输入、并发、缓存和队列预算，测量基线、峰值与释放后的多轮趋势。无界增长、停用后持续工作等回归先修复；未测指标明确标注，不凭编译或单元测试宣称性能合格。具体工具与复现记录见性能规范。

## 分支、自动 PR、合并与发布

- 默认交付流程为 **拉取最新主线并创建独立 worktree → 开发、验证及提交 → 推送并经受保护 PR 合并 → 验证合并提交 → 分别发布受影响的宿主与插件并验证下载 → 清理工作区和同步本地 main**。这是正常开发任务的持续授权。用户要求只改本地、不发布、Draft 或暂停时，按其范围保留现场。
- 每项任务先 `git fetch origin`，再从最新 `origin/main` 创建独立 worktree 和 `agent/<task>` 分支，兼容已有 `codex/<task>`；无论主工作区是否干净，都不直接在主工作区开发。记录本任务 worktree 路径、分支及 main 工作区位置。不暂存或提交其他任务文件，不直接推送 main、force-push、关闭保护或使用管理员绕过。
- 完成必要验证并提交本任务改动后，从 main 工作区运行 `python3 <任务worktree>/scripts/deliver-agent-task.py --worktree <任务worktree> --body-file <PR说明.md>`。说明实际行为、验证及未验收项。收尾命令使用本机 `gh` 登录推送、创建 PR、登记受保护自动合并，随后验证合并和发布，保存记录并清理。已有 PR 用 `--pr` 恢复。Codex 管理的 worktree 加 `--keep-worktree`，交付验证完成后用 Codex 归档任务附件并同步 main。
- GitHub 对同仓库、有写权限作者的 Agent 分支提供自动 PR 兜底；只处理已登记的 PR，不接管旧 PR 或 fork。CI 只读运行；有写权限的编排工作流只运行受保护 `main` 的代码，不检出或执行 PR 代码。
- `verify` 等必需检查通过且无冲突才会合并；基线落后时正常合入 `main` 后重跑检查。失败不伪造成功，冲突不强合。需要暂停时设为 Draft 或添加 `no-automerge` 标签。
- 自动合并后核对 PR 确为 `MERGED`、目标为 main，记录合并提交并确认它已进入最新 `origin/main`。仅推送、排队或 CI 通过不能报告“已合并”；Squash 后也不能仅凭原功能提交是否为 main 祖先判断交付。失败或冲突时保留 worktree，报告阻塞，不进入清理。
- 按 [独立发布流程](docs/DEVELOPMENT.md#独立发布宿主与插件)选择通过只读 CI 的受保护 main 提交。自动发版由双机验收后的仓库设置启用。宿主使用 Developer ID 签名，正式版另完成 Apple 公证。宿主用 `v<宿主版本>` 和应用 ZIP。插件用自己的版本及 ZIP，独立仓库用自己的标签，同仓插件用 `plugin-<slug>-v<版本>`。宿主内编译的能力需要对应的宿主版本，声明式包改动才递增插件版本。公开预览和正式签名公证版须标明渠道。
- 核对对应 Release 已公开、资产可下载且 SHA-256 一致后，再检查本任务 worktree 干净并移动需保留的产物、验收记录。从 worktree 外安全移除本任务创建的 worktree。发布或清理阻塞时保留现场并说明原因。
- 清理后在干净、确实检出 main 的工作区执行 `git pull --ff-only origin main`，核对本地 main 与最新 `origin/main` 一致。main 已在其他 worktree 检出时在该处同步。原主目录有并行改动时保留现场。交付分别核对源码、发布资产、本机安装及真机验证。
- 配置、权限、事件安全边界和恢复流程见 [Agent 自动交付](docs/AGENT-WORKFLOW.md)。

## 本机应用交付

- 修改宿主原生代码或随宿主编译的插件功能，或用户明确要求更新已安装的宿主时，在相关验证通过后默认替换本机 `/Applications/Untitled.app`，从该路径重启并核对正在运行的是新构建。`dist/` 是构建暂存，不以生成包、打开副本或合并源码代替安装。纯文档、仅声明式插件改动，以及用户明确要求不安装或只做预览时，不自动替换宿主。
- 按 [本机安装与回退](docs/DEVELOPMENT.md#本机安装与回退)核对路径、应用身份、版本和签名，保留完整旧包，正常退出后可回退地替换。不强退，不清除用户数据或权限。若不能沿用现有签名，先说明影响并取得用户确认，不静默用临时签名覆盖证书签名的应用；安装受阻时保留旧版并报告。
- 本机安装由开发机执行。公开发布及插件目录更新依据独立发布流程。驱动安装和需要实际输入的功能由用户验收。交付记录源码合并、Release 链接、安装版本和运行路径。

## 验证与发布

```bash
swift build
swift test --no-parallel
./scripts/build-app.sh debug
python3 scripts/package-plugins.py --tag v0.10.0
```

焦点测试串行运行，临时目录隔离配置，fake driver 隔离系统权限。按改动做必要验证；不为文案或低影响可逆变更编写镜像测试。只在相关改动、失败或未解决疑虑存在时扩大检查范围。

修改 `Resources/Brand/AppIcon.png` 后执行 `scripts/build-icon.sh`，同步 Xcode 使用的 `Resources/AppIcon.icns`。选定图形是黑白「裂变」，来源见 [品牌说明](docs/BRANDING.md)。

版本采用三段数字。插件 ZIP 打包默认只写 `dist/`，可选择单个插件和独立仓库。对应资产实际发布后才更新在线目录；相同版本 ZIP 和 SHA-256 不重写。报告真实完成的检查，不把编译通过当成真机跨设备验收通过。
