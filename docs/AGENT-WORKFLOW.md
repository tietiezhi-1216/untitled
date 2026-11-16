# Agent 自动 PR 与合并

默认交付：**Agent 验证并提交 → 推送功能分支 → 创建 PR → 必需检查 → 自动 Squash 合入 main**。用户明确要求只改本地、不推送、Draft 或暂停自动合并时例外。

这只是源码交付，不自动发布 Release、覆盖已发布资产、安装应用 / 驱动或执行真实输入、录音等验收。

## Agent 收尾

1. 从最新 `origin/main` 创建独立 `agent/<task>` 分支，兼容已有 `codex/<task>`；有其他工作时使用独立 worktree。只提交本任务文件，不 reset、clean、force-push 或顺带提交用户修改。
2. 完成相应验证，准备 Markdown PR 说明：需求、行为、真实检查结果、风险和未验收项，不含个人路径或凭据。
3. 提交后在干净 worktree 运行：

   ```bash
   python3 scripts/submit-agent-pr.py --body-file /path/to/pr-description.md
   ```

   脚本使用本机已有 GitHub CLI 登录，核对 origin，推送当前分支，幂等创建 / 复用 PR，加 `agent-automerge` 标签，并用当前 head SHA 登记 `--auto --squash`。不会自动 commit、直接推 main、批准 review、复制凭据到 CI 或绕过检查。若 GitHub 兜底刚好建了同一个 PR，会复用它。
4. 等待并查询实际结果，例如 `gh pr view <URL> --json state,mergedAt,statusCheckRollup,mergeStateStatus`。必须真正 `MERGED` 才报告已合并；检查失败或冲突时修复自己的分支并正常推送，不能只凭排队状态结束交付。

## GitHub 兜底

`.github/workflows/agent-pr.yml` 在默认分支监听 `macOS CI` 的 requested / completed、PR 元数据事件，并每 10 分钟补偿一次。它可以为正常推送漏建的 Agent PR 补齐自动交付；不是仅靠 Agent 记住命令。

自动创建仅限：

- 同仓库 `agent/*` 或 `codex/*` 分支，推送者当前有 write / maintain / admin 权限；
- 事件的 workflow ID 和路径确为本仓库 `ci.yml`，head repository 与当前仓库一致；
- 分支当前 SHA 与事件一致，且相对 main 确有新提交；
- 目标为 main，不是 Draft，也未添加 `no-automerge`。

定时和 PR 元数据事件只协调已登记 `agent-automerge` 的 PR，不批量接管历史 PR、普通人工分支或 fork。不同事件被串行协调，重复事件不重复创建 PR。GitHub 并发事件可能合并等待队列；Agent 收尾脚本是主路径，定时协调补偿已登记 PR。

编排只请求 GitHub 的 auto-merge，最终由受保护 main 判定，仍要求 `verify`、分支最新、无冲突及所有其他配置的规则。检查失败不自动重跑来掩盖；冲突原样保留。落后基线且本 head 的 CI 已成功、没有仍运行或失败检查时，使用带 `expected_head_sha` 的正常 update-branch 合入 main，再检查新 SHA；不 force-push 或丢弃本分支提交。新 head 会重新接受完整 CI。

## Token 与事件边界

- 编排使用短期 `GITHUB_TOKEN`，不新增 PAT、复制本机 OAuth token 或读取发布 / 签名秘密。
- 编排的 write 权限只在独立 job。`workflow_run` / `pull_request_target` **只检出受保护 main 的 `.github/scripts`**；不检出 head / merge ref，不执行提交消息或分支字符串，不下载 PR 产物 / 缓存，不运行 PR 的脚本。
- 测试 CI 仍只有 `contents: read`。测试、打包和 Xcode 构建不会获得编排的 write token。
- GitHub 当前对 token 创建的 PR 可能将 CI 置于 approval-required。编排只批准已登记、受信任同仓库 PR 的准确 head 上、本仓库既定 CI workflow 的 `action_required` run；不批准 fork、部署 environment 或 PR review，不伪造检查。
- GitHub token 产生的 push 通常不会再触发 push 工作流。因此正常 update-branch 后显式 `workflow_dispatch` 只读 CI；该事件是 GitHub 明确支持的例外，新 run 绑定更新后的分支 SHA。普通 Agent 用本机 `gh` 建 PR 则正常触发 PR CI，无需此兜底。
- 没有自动发布工作流；不要把自动合并误称为自动发布。未来若增加部署，必须另外验证 token 产生的 main 事件是否触发，不能假设递归事件都会运行。

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
