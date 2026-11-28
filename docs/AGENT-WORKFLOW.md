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

3. **提交 PR 并登记自动合并。** 提交后在干净的任务 worktree 运行：

   ```bash
   python3 scripts/submit-agent-pr.py --body-file /path/to/pr-description.md
   ```

   脚本使用本机已有 GitHub CLI 登录，核对 origin，推送当前分支，幂等创建 / 复用 PR，加 `agent-automerge` 标签，并用当前 head SHA 登记 `--auto --squash`。若 GitHub 兜底刚好建了同一个 PR，会复用它。完成本步后继续验证合并及发布。

4. **验证确已合并。** 等待并查询实际结果，例如 `gh pr view <URL> --json state,mergedAt,mergeCommit,baseRefName,headRefName,statusCheckRollup`。确认正确仓库 / 任务分支的 PR 为 `MERGED`、目标为 main，记录 `mergedAt` 和合并提交；再 `git fetch origin`，确认合并提交是 `origin/main` 的祖先。仅推送、排队或 CI 通过不能报告“已合并”；Squash 后原功能提交不一定是 main 祖先，不能以此误判。检查失败或冲突时修复自己的分支并正常推送，保留 worktree，不提前清理。

5. **分别发布变更。** 按 [独立发布宿主与插件](DEVELOPMENT.md#独立发布宿主与插件)核对发行基线、版本和资产。通过 GitHub CLI 发布后，检查实际下载与 SHA-256。涉及插件商店时，待相应 ZIP 可验证再走目录 PR。因 CI、签名或版本冲突受阻时保留候选包和现场。

6. **清理本任务 worktree，并拉取最新 main。** 从 `git worktree list --porcelain` 核对待清理路径 / 分支确属本任务，检查工作区干净并保存构建产物和验收记录。从任务 worktree 外执行普通删除，然后在干净、确实检出 main 的工作区同步。

   ```bash
   set -e
   # 四个变量均来自本任务记录；MAIN_WORKTREE 不是任意主目录。
   : "${REPO_ROOT:?}" "${TASK_WORKTREE:?}" "${TASK_BRANCH:?}" "${MAIN_WORKTREE:?}"
   cd "$REPO_ROOT"
   test "$TASK_WORKTREE" != "$REPO_ROOT"
   test "$TASK_WORKTREE" != "$MAIN_WORKTREE"
   test "$TASK_BRANCH" != main
   test "$(git -C "$TASK_WORKTREE" branch --show-current)" = "$TASK_BRANCH"
   test -z "$(git -C "$TASK_WORKTREE" status --porcelain)"
   test "$(git -C "$MAIN_WORKTREE" branch --show-current)" = main
   test -z "$(git -C "$MAIN_WORKTREE" status --porcelain)"
   git worktree remove "$TASK_WORKTREE"
   git -C "$MAIN_WORKTREE" pull --ff-only origin main
   git -C "$MAIN_WORKTREE" rev-parse HEAD origin/main
   ```

   最后确认任务目录已移除、worktree 列表中已无该项，且本地 main 与最新 `origin/main` 一致。main 已在其他 worktree 检出时在该处同步。保留主工作区、其他任务目录及未提交改动。清理失败或 main 分叉时保留现场并报告阻塞。

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
- 发布由交付任务在核对源码合并、构建验证和签名后使用本机 GitHub CLI 执行。PR 编排和测试 CI 的令牌不负责发布或签名。

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

离线测试注入 fake GitHub / gh / git，不调用真实写接口。覆盖受信任作者、fork / 旧 SHA / 冒名 workflow 拒绝、幂等、Draft / opt-out、冲突、失败 CI、带 SHA 的更新与 CI 重新触发。首次启用还应以真实 PR 验证创建、必需 CI 和自动合并，不能把 fake 测试当作已上线。
