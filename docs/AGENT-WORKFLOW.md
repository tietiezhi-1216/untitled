# Agent 合并与发布

默认流程为 **拉取主线并创建 worktree → 开发与验证 → 推送并经 PR 合并 → 验证合并提交 → 发布有变更的宿主或插件 → 清理并同步本地 main**。用户明确要求只改本地、暂停或不发布时，按其范围保留工作现场。

宿主原生改动（含随宿主编译的插件实现）仍需按 [本机安装与回退](DEVELOPMENT.md#本机安装与回退)验证 `/Applications/Untitled.app`。源码合并、公开发布和本机安装分别核对。

## 开发与交付

1. **拉取最新代码并创建 worktree。** 开始前先检查主目录状态，保留已有工作；执行 `git fetch origin`，以最新 `origin/main` 创建本任务唯一的 `agent/<task>` 分支和独立 worktree，兼容已有 `codex/<task>`。无论主目录是否干净都使用独立 worktree，不在主目录直接开发。记录本任务路径 / 分支、起始提交和 main 工作区位置。示例变量需换为本任务唯一值：

   ```bash
   set -e
   git fetch origin
   REPO_ROOT="$(git rev-parse --show-toplevel)"
   TASK_BRANCH='agent/my-task'
   TASK_WORKTREE="$(dirname "$REPO_ROOT")/untitled-my-task"
   git worktree add -b "$TASK_BRANCH" "$TASK_WORKTREE" origin/main
   ```

2. **只在本任务 worktree 开发。** 在其中修改、构建和运行必要验证；只提交本任务文件。准备 Markdown PR 说明，记录需求、行为、真实检查结果、风险和未验收项，不含个人路径或凭据。不要暂存主目录 / 其他任务的修改，也不 reset、clean 或 force-push。

3. **提交并等待交付。** 从实际检出 main 的工作区运行收尾命令。它调用现有 PR 提交脚本来推送当前任务分支、创建或复用 PR，以及按准确的 head SHA 登记自动合并。举例中的路径用本任务记录替换。

   ```bash
   python3 "$TASK_WORKTREE/scripts/deliver-agent-task.py" \
     --worktree "$TASK_WORKTREE" --body-file /path/to/pr-description.md
   ```

   PR 已建成时，使用 `--pr <编号>` 代替 `--body-file` 来恢复等待。默认等待 45 分钟，可用 `--wait-minutes` 调整。遇到 Draft、暂停标签、冲突、失败检查或发布阻塞时，命令报出相应的 PR 或 Actions 链接，并保留 worktree。新版本的正式发布只在明确满足相应渠道条件后进行。

4. **核对合并和独立发布。** 收尾命令要求 PR 已是 `MERGED`、目标为 main，且 GitHub 报告的合并提交已进入 `origin/main`。自动发布基于这一提交重新运行 CI，按宿主和插件自己的版本分别发包。收尾命令实际下载相应的独立 ZIP 和 `SHA256SUMS.txt`，核对标签提交与 SHA-256。流程、文档或目录条目的改动完成源码交付即可。宿主发行及签名配置见 [独立发布宿主与插件](DEVELOPMENT.md#独立发布宿主与插件)。

5. **清理任务 worktree 并同步 main。** 对直接由 Git 创建的任务 worktree，收尾命令检查两边的状态，在 Git common directory 下的 `untitled-delivery/` 保存交付记录与任务 `dist/`，再执行普通的 `git worktree remove` 和 `git pull --ff-only origin main`。待清理分支、HEAD、未提交数据或 main 快进条件有变化时，保留现场并报告。对 Codex 管理的 worktree，运行时加 `--keep-worktree`，由 Codex 归档任务附件，再在实际检出 main 的干净工作区快进并检查 `HEAD` 与 `origin/main` 一致。若有宿主发行，先完成本机安装和启动核对再清理。

## GitHub 兜底

`.github/workflows/agent-pr.yml` 在默认分支监听 `macOS CI` 的 requested / completed、PR 元数据事件，并每 10 分钟补偿一次。它可以为正常推送漏建的 Agent PR 补齐自动交付；不是仅靠 Agent 记住命令。

自动创建仅限：

- 同仓库 `agent/*` 或 `codex/*` 分支，推送者当前有 write / maintain / admin 权限；
- 事件的 workflow ID 和路径确为本仓库 `ci.yml`，head repository 与当前仓库一致；
- 分支当前 SHA 与事件一致，且相对 main 确有新提交；
- 目标为 main，不是 Draft，也未添加 `no-automerge`。

定时和 PR 元数据事件只协调已登记 `agent-automerge` 的 PR，不批量接管历史 PR、普通人工分支或 fork。不同事件被串行协调，重复事件不重复创建 PR。GitHub 并发事件可能合并等待队列；Agent 收尾脚本是主路径，定时协调补偿已登记 PR。

编排为等待中的 PR 登记 GitHub auto-merge；当当前 SHA 的既定 CI 全绿、无在途 / 失败检查、基线最新且 GitHub 判定 clean 时，用带精确 SHA 的普通 Squash 合并接口完成落地，避免只排队不合并。此接口仍由受保护 main 判定，要求 `verify`、分支最新、无冲突及所有其他配置的规则；不使用管理员或强制绕过。检查失败不自动重跑来掩盖；冲突原样保留。落后基线且本 head 的 CI 已成功、没有仍运行或失败检查时，使用带 `expected_head_sha` 的正常 update-branch 合入 main，再检查新 SHA；不 force-push 或丢弃本分支提交。新 head 会重新接受完整 CI。

## Token 与事件边界

- 编排使用短期 `GITHUB_TOKEN`，不新增 PAT、复制本机 OAuth token 或读取发布 / 签名秘密。read-scoped token 的仓库元数据可能省略管理级合并设置，不能把字段缺失误判为关闭，也不为此扩大到管理员权限；实际登记 / 合并 API 始终按服务端设置和保护规则判定。
- 编排的 write 权限只在独立 job。`workflow_run` / `pull_request_target` **只检出受保护 main 的 `.github/scripts`**；不检出 head / merge ref，不执行提交消息或分支字符串，不下载 PR 产物 / 缓存，不运行 PR 的脚本。
- 测试 CI 仍只有 `contents: read`。测试、打包和 Xcode 构建不会获得编排的 write token。
- GitHub 当前对 token 创建的 PR 可能将 CI 置于 approval-required。编排只批准已登记、受信任同仓库 PR 的准确 head 上、本仓库既定 CI workflow 的 `action_required` run；不批准 fork、部署 environment 或 PR review，不伪造检查。
- GitHub token 产生的 push 通常不会再触发 push 工作流。因此正常 update-branch 后显式 `workflow_dispatch` 只读 CI；该事件是 GitHub 明确支持的例外，新 run 绑定更新后的分支 SHA。普通 Agent 用本机 `gh` 建 PR 则正常触发 PR CI，无需此兜底。
- `Untitled release` 监听 main 的 push。PR 编排使用短期 token 完成受保护合并后，显式按准确的合并 SHA `workflow_dispatch`，定时协调也会为近期已登记且缺少发布 run 的合并补发事件。首轮上线前的提交可以按 SHA 手动发起。
- 发布流水线只接受受保护 main 第一父链上的提交。签名任务通过 `release` 环境读取凭据，独立的发布任务只在上传时使用写令牌。PR 检查和插件打包无签名凭据。发布重试验证已存在的标签和资产，继续自己的草稿或验证已公开的包。

官方事件说明：[触发工作流](https://docs.github.com/en/actions/how-tos/writing-workflows/choosing-when-your-workflow-runs/triggering-a-workflow)、[workflow_run 安全边界](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#workflow_run)。

## 仓库设置与暂停

需要启用仓库 Allow auto-merge、Squash merge，以及 Actions 创建 PR 的权限。保持默认 workflow token 只读，只有受信任编排 job 显式申请 `contents/pull-requests/actions: write`。GitHub 的“允许 Actions 创建及批准 PR”是同一设置，但本实现**不批准 PR review**。

main 的 PR、`verify`、strict up-to-date、管理员同样受保护、禁止 force-push / 删除的规则不放宽。

- **暂停单个任务**：设为 Draft 或加 `no-automerge`，会撤销已登记的 auto-merge；需要恢复时去除标签 / 退出 Draft。
- **只推送不自动管理**：使用非 Agent 命名空间并不调用收尾脚本。Agent 默认不得用此方式规避用户要求的自动交付。
- **检查失败 / 冲突**：由原任务修复自己的分支，正常推送；不自动改业务代码或联系其他 Agent。
- **关闭整个机制**：禁用 `Agent PR automation` workflow，并关闭仓库 auto-merge；不必删除 main 保护。
- **观察与恢复**：看 `Agent PR automation` 日志、PR 标签与 `autoMergeRequest`；必要时手动运行该 workflow 重新协调。不能仅凭脚本退出成功就宣称 PR 已合并。

## 验证

```bash
node --test .github/scripts/agent-pr.test.cjs
python3 -m unittest discover -s Tests/Automation
```

离线测试覆盖受保护 PR 合并、发布触发补偿、独立版本、公开下载校验，以及 Git worktree 的安全清理和 main 快进。凭据配置完成后，用真实的宿主版本核对签名、公开下载和本机安装。
