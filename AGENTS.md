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

- 只支持 macOS。Swift 6、SwiftUI / AppKit，部署最低 macOS 14；较新 API 保留相应 availability 检查。源码使用 macOS 26+ SDK，不增加其他系统适配层。
- 清单在 `Plugins/<slug>/`；通用协议与存储在 `Sources/Untitled/Plugins/`，系统接口在 `Runtime/`，组合入口在 `App/PluginComposition.swift`。
- 现有 `Capture/`、`Sharing/` 是原生能力模块。新业务使用自己的模块与 provider；通用渲染器只访问注册表，不按插件 ID 硬编码页面。
- 当前 ZIP 是声明式包，仅允许根目录 `manifest.json`、`README.md`、`LICENSE`。新增原生能力随宿主编译。任意代码加载、agent 执行器及完全接管是独立的运行时工作，未实现时不得宣称可用。
- 命令行与 Xcode 构建均不启用 App Sandbox，保留系统授权与 Hardened Runtime。系统能力通过统一 driver 和绑定插件身份的客户端接入。
- 原生 provider 同进程运行；权限声明是宿主接口约束，不是对恶意原生代码的隔离沙盒。共享与独立分发不代表自动获得系统权限。

## 实现与兼容

- 开始前看 `git status --short`。保留已有未提交改动，不用 reset、clean 或整文件回退覆盖其他工作。
- 产品、Swift package / module / target / scheme 和可执行文件统一为 `Untitled`，仓库名 `untitled`，工程 `Untitled.xcodeproj`。应用命名空间 `com.untitled.app`，内置插件 `com.untitled.*`，环境变量 `UNTITLED_*`；不新增旧命名别名。历史身份仅用于显式的数据迁移与驱动清理，规则见 [迁移说明](docs/IDENTITY-MIGRATION.md)。
- 新插件使用自己的命名空间；fork 独立分发时换插件 ID，保留作者与许可。版本、模板 ID、命令 ID 稳定，升级不重置用户配置。
- 安装、启用、打开界面不自动启动采集、远端控制、安装 helper 或申请整套权限。长任务可取消；禁用、卸载和退出释放自身热键、监听、连接与任务。
- Swift 6 的 actor 和 Sendable 问题按真实所有权解决，不靠普遍添加 `@unchecked Sendable` 或忽略错误。
- 密钥放 Keychain；源码、清单、包和日志不含个人路径、配对信息或用户内容。错误提供恢复路径，输出与配置有原子替换或等效的失败保护。
- 新 Swift 文件同时加入 Xcode target。新增字段、动作、权限同步 Swift 校验、JSON Schema、说明和相关验证。
- 每个插件都检查空闲与停用后的开销；高内存、模型、图像、音视频、批处理等路径先定义输入、并发、缓存和队列预算，测量基线、峰值与释放后的多轮趋势。无界增长、停用后持续工作等回归先修复；未测指标明确标注，不凭编译或单元测试宣称性能合格。具体工具与复现记录见性能规范。

## 分支、自动 PR 与合并

- 默认开发规范是完整的五步闭环：**① 从 GitHub 拉取最新代码并创建独立 worktree → ② 只在该 worktree 开发与验证 → ③ 提交 PR 自动合并 → ④ 验证确已合并 → ⑤ 清理本任务 worktree 并同步本地 main**。无需用户逐次要求提交、合并或清理；用户明确要求“只改本地 / 不推送”、Draft 或暂停时例外，此时保留工作现场。
- 每项任务先 `git fetch origin`，再从最新 `origin/main` 创建独立 worktree 和 `agent/<task>` 分支，兼容已有 `codex/<task>`；无论主工作区是否干净，都不直接在主工作区开发。记录本任务 worktree 路径、分支及 main 工作区位置。不暂存或提交其他任务文件，不直接推送 main、force-push、关闭保护或使用管理员绕过。
- 完成必要验证并提交本任务改动后，执行 `python3 scripts/submit-agent-pr.py --body-file <PR说明.md>`。说明实际行为、验证及未验收项；脚本使用本机已有 `gh` 登录，幂等推送、创建 PR、登记受保护的自动合并，不上传个人凭据到 CI。该脚本只完成提交与登记，后续仍必须确认合并、清理和同步。
- GitHub 对同仓库、有写权限作者的 Agent 分支提供自动 PR 兜底；只处理已登记的 PR，不接管旧 PR 或 fork。CI 只读运行；有写权限的编排工作流只运行受保护 `main` 的代码，不检出或执行 PR 代码。
- `verify` 等必需检查通过且无冲突才会合并；基线落后时正常合入 `main` 后重跑检查。失败不伪造成功，冲突不强合。需要暂停时设为 Draft 或添加 `no-automerge` 标签。
- 自动合并后核对 PR 确为 `MERGED`、目标为 main，记录合并提交并确认它已进入最新 `origin/main`。仅推送、排队或 CI 通过不能报告“已合并”；Squash 后也不能仅凭原功能提交是否为 main 祖先判断交付。失败或冲突时保留 worktree，报告阻塞，不进入清理。
- 确认已合并后，先检查本任务 worktree 无未提交 / 未跟踪内容，并将需要保留的构建产物、验收记录等移至安全位置；再从 worktree 外执行普通 `git worktree remove <本任务路径>`。只清理本任务创建的 worktree，不删除主工作区、main 工作区或其他任务目录，不使用 `--force`、`reset`、`clean` 或全局 prune 掩盖脏状态。
- 清理后在干净、确实检出 main 的工作区执行 `git pull --ff-only origin main`，核对本地 main 与最新 `origin/main` 一致。main 已在其他 worktree 检出时在该处同步；原主目录有并行改动时不切换或覆盖它。清理 / 同步受阻要保留现场并报告，不能提前宣称五步交付已完成。自动源码合并不等于发布、安装、真机验收或性能合格。
- 配置、权限、事件安全边界和恢复流程见 [Agent 自动交付](docs/AGENT-WORKFLOW.md)。

## 验证与发布

```bash
swift build
swift test --no-parallel
./scripts/build-app.sh debug
python3 scripts/package-plugins.py --tag v0.10.0
```

焦点测试串行运行，临时目录隔离配置，fake driver 隔离系统权限。按改动做必要验证；不为文案或低影响可逆变更编写镜像测试。只在相关改动、失败或未解决疑虑存在时扩大检查范围。

本机交付：每次开发更新完成并通过相关验证后，立即构建并替换 `/Applications/Untitled.app`，正常退出旧进程后从安装位置重新启动；这是用户的持续授权，无需每次询问，不要只留下 `dist/` 构建。沿用现有签名身份，保留用户配置、插件、密钥及系统授权记录；替换前校验签名，采用暂存与可回退的替换方式。构建、签名或正常退出失败时保留原应用并说明阻塞，不强杀进程、不绕过保存保护。本机更新不等同于发布，仍须如实说明验证范围。

修改 `Resources/Brand/AppIcon.png` 后执行 `scripts/build-icon.sh`，同步 Xcode 使用的 `Resources/AppIcon.icns`。选定图形是黑白「裂变」，来源见 [品牌说明](docs/BRANDING.md)。

版本采用三段数字。打包默认只写 `dist/`，可选择单个插件和独立仓库。对应资产实际发布后才更新在线目录；相同版本 ZIP 和 SHA-256 不重写。报告真实完成的检查，不把编译通过当成真机跨设备验收通过。
