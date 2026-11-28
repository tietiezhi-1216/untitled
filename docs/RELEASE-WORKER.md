# Untitled 签发机与跨设备安装

其他 Mac 只需要已签发的 `Untitled.app`，不需要安装证书或复制系统权限。当前流程先人工选定提交、生成公证包，在另一台 Mac 验证覆盖更新；**没有自动发布任务，也没有应用内更新器**。

## 权限和签名分别存在哪里

- 屏幕录制、辅助功能、输入监控、麦克风等系统授权由 macOS 的 TCC 管理。常见数据库位置是 `~/Library/Application Support/com.apple.TCC/TCC.db` 和 `/Library/Application Support/com.apple.TCC/TCC.db`。它们是受保护的本机系统数据，不随应用打包，不支持复制到另一台 Mac 继承授权。由每台 Mac 的使用者按需授权。
- `Resources/Untitled-DeveloperID.entitlements` 是构建时嵌入签名的能力声明，不是用户已授权的记录。它随源码管理，不需要单独复制到客户端。
- `.signing-identity` 只记录签名证书的 SHA-1 指纹；配对私钥和公证凭据在签发账号的钥匙串里。客户端不需要其中任何一个。

在同一台设备上，覆盖安装时保持 Bundle ID `com.untitled.app` 与签名指定要求（designated requirement）不变，macOS 通常会沿用该设备已有记录。签发工具拒绝签名身份改变的包，但不能代替真机验收；系统撤销或重新确认授权时，遵循系统提示。

## 普通开发设备

在任一 Mac 拉取源码、编译和测试，未配证书可用临时签名。临时包用来开发和普通调试，**不要把它覆盖到稳定签名的 `/Applications/Untitled.app`**，也不要同时运行两份同一 Bundle ID 的应用。需验证录屏、键鼠或其他系统权限时，提交修改，通过托管 CI 并合入受保护的 `main`，再安装签发包。收到 ZIP 后校验 `SHA256SUMS.txt`，用 Finder 解压，正常退出旧版后覆盖 `/Applications/Untitled.app` 并从该路径重新打开。更新时保留配置、Keychain 和权限数据库，不运行 `tccutil reset`。

## 在签发机上出第一个验收包

1. 继续让 GitHub 托管 CI 跑分支与 PR。**不要**把有发布私钥的 Mac 注册为公开仓库的 runner。签发机使用专用 macOS 账号和钥匙串；将审阅过的 `scripts/release-worker.py` 及同目录的 `scripts/check-app-sdk.sh` 固定在独立工具目录，不在构建时从候选提交刷新签发控制脚本。构建只针对已经人工审阅的提交；干净检出不等于恶意代码隔离。
2. 签发账号准备最新 macOS SDK、有效的 Developer ID Application 身份、对应指纹文件和 GitHub CLI。首次使用 Apple 公证，在该账号终端交互配置一个本地钥匙串 profile，不用 `--sync`，不要把密钥提交到仓库或发给开发设备：

   ```bash
   xcrun notarytool store-credentials untitled-notary
   xcrun notarytool history --keychain-profile untitled-notary >/dev/null
   ```

3. 选择已审阅、通过托管 CI 的完整 `main` 提交 SHA。若合并是自动化触发且没有启动 `main` CI，在 GitHub 上对 `main` 手动运行 **macOS CI** 后再试。选择最近一个已分发的 Developer ID 签名包作参考；源提交的构建号须更高，显示版本不能回退。

   ```bash
   python3 scripts/release-worker.py check "$SHA"
   python3 scripts/release-worker.py package "$SHA" \
     --reference-app /Applications/Untitled.app \
     --signing-identity-file .signing-identity \
     --notary-profile untitled-notary \
     --output "$HOME/Library/Application Support/UntitledSigning/previews"
   ```

   `check` 只读 GitHub。`package` 单独检出该 SHA，用本机 SDK 构建并核对 SDK、版本、指定要求和证书；只有公证通过、staple 成功且最终 ZIP 解压后验签与分发检查通过，才原子生成 `preview-v<版本>-b<构建号>/`（ZIP、SHA-256、提交和 CI 记录）。不覆盖已存在的包，不修改 `/Applications` 或在线插件目录。
4. 首轮可直接把验收 ZIP 和校验文件传到另一台 Mac。也可以给 `package` 加 `--draft-repo <owner>/<repo>`，把合格产物上传到独立的私有 GitHub 仓库的 **Release 草稿**。仓库须已有初始提交，令牌写入范围只授予该仓库；验收人须有草稿访问权限。源仓库是公开的，公开仓库的 Pre-release 不是私有渠道。上传失败保留本地已校验的包，检查服务器是否产生了草稿后手动续传，不能覆盖已有资产。私有验收仓库的标签仅用于定位资产；源代码 SHA 由 `release.json` 记录。
5. 在测试 Mac 安装参考版、按需授予权限并实际使用功能；覆盖签发的新包后再测相同功能，确认没有额外授权、配置未丢失。签名和公证相同不等于已经通过这项验收。有 Intel Mac 时还需准备并验证对应架构的包（本机默认只构建 `arm64`）。

## 验收后再打开自动化

下一步才给签发机加受信任的拉取任务。现有 `main` 走受保护合并和 CI，但目前没有强制人工批准，不能把「自动合并」直接当成「批准在持有私钥的 Mac 执行」。启用自动预览前，先落实人工审查签发边界（例如要求独立审查后才能合入 `main`）。保留人工验收门槛，失败时不推进分发。发布频道稳定之后再接入 Sparkle；客户端校验更新签名，不内置 GitHub 私有访问令牌，测试频道需用户主动选择。
