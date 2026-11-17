# 软件本体更新面板

设置 → **软件更新**，与插件商店独立。显示运行中的 `CFBundleShortVersionString` / `CFBundleVersion`；只有非应用包开发环境缺少版本字段时才使用源码版本。设置保留“通用”和“权限管理”，不改变既有外观、插件或授权配置。

## 行为

- 只在点击“检查更新”时请求正式发布信息。启动、打开设置、切换页签和重新激活应用都不自动联网；没有定时轮询或下载任务。
- 默认只显示应用名、当前版本、检查按钮和一行结果；不展示渠道、检查时间、重复版本信息或长篇提示。检查中可以取消；只有发现新版本才出现下载入口与默认折叠的“更新说明”。底部保留一个发布记录链接。
- 取消/关闭面板立即请求取消，在原请求实际结束前不允许再开检查，避免快速取消/重试积累任务；迟到的已取消结果不发布。
- 三段数字版本按数值比较。当前版本更高时显示“当前版本较新，无需更新”；相等时不提供更新；未知开发版本只提供发布记录。构建号用于显示，不作为同一发布版本的另一次更新。
- 只有正式版本更高且存在匹配当前 Mac 架构的本体资产时，才显示“前往下载”。按钮只在默认浏览器打开该版本的 GitHub 发布页，不直接下载、不申请权限、不退出或替换应用。
- 发布记录不存在、网络失败、请求受限、来源不匹配或信息过大有明确提示，可手动重试。错误不会变成“已是最新版”。

本面板**不验证安装包签名**，也不声称某个公开包已通过 Developer ID、公证、Gatekeeper 或真机验收。安装前由用户确认发布说明与签名。自动下载、安全退出、自替换、回滚安装器、预发布/源码更新渠道和插件更新均不属于本实现。

## 发布来源与包命名

使用 `HostInfo.repository` 对应的公共 GitHub 仓库，手动调用：

```text
GET https://api.github.com/repos/<owner>/<repo>/releases/latest
Accept: application/vnd.github+json
X-GitHub-Api-Version: 2022-11-28
```

使用独立 ephemeral URLSession，不携带认证、cookie、设备标识、插件列表或用户内容，不使用本机 `gh` 凭据；不跟随 HTTP 重定向，不改变 TLS 默认验证。返回地址必须仍是原 API 地址；发布页必须精确属于该仓库、对应数字版本标签。草稿和预发布明确拒绝。404 表示该渠道没有可读取的正式版本，不等于当前安装版是最新源码。

安装包元数据仅接受 `uploaded`、非空且下载 URL 精确匹配同一仓库/标签的资产。支持：

```text
Untitled-macOS-arm64-v1.2.3.zip
Untitled-macOS-x86_64-v1.2.3.zip
Untitled-macOS-universal-v1.2.3.zip
```

也支持 `.dmg`；不带 `v` 的合法 `1.2.3` 标签使用相应同名文件。`universal` 可用于两种架构。其它名称、其它仓库、旧身份包、插件 ZIP 或仅有源码的发布不显示为本体下载入口。这里检查的是资产声明，不是下载后的二进制签名或架构验证。

源码合并、Agent PR 自动交付和本机开发构建都不等于正式发布。发布者仍须按 [开发说明](DEVELOPMENT.md#发布次序) 固定源码、验证、签名/公证、生成并实际上传新版本资产；不移动旧标签或重写同版本 ZIP。发布渠道比本机开发版旧是正常且需要明确呈现的状态。

## 资源与验证

- 每个面板实例只持有一个检查任务；取消也必须完成清理才允许再检查。空闲不运行网络任务或定时器，关闭面板及对象释放会取消请求。
- 请求超时 20 秒，总资源超时 25 秒，不等待网络恢复，也不自动重试。
- 响应体最多 1 MiB，流式读入，未知长度也执行上限；解码前再次检查。最多 256 个资产；保留的说明最多 16 KiB UTF-8、标题最多 320 字节，并保持有效 UTF-8。说明按纯文本显示，不加载远程图片或执行嵌入内容。
- 回归使用 fake HTTP/checker，覆盖惰性、单请求、取消排空、迟到结果、错误、版本比较、禁止降级、架构/本体包筛选、来源拒绝、正文预算及离屏布局；不操作真实鼠标、焦点或音频。
- 可选公开渠道检查：`UNTITLED_HOST_UPDATE_NETWORK_TEST=1 swift test --no-parallel --filter publishedStableChannelCanBeReadWithoutDownloadingAnApplication`。只读取元数据，不下载应用；默认测试跳过联网。

响应字节预算不等于整个进程的内存峰值。受控负载下的完整应用 CPU、physical footprint、GPU、I/O 峰值与十轮真实设置窗口启闭回收尚未测，不凭编译、fake 测试或短时离屏渲染宣称性能合格。完整 Swift Package / Xcode / Release 构建结果与本机安装记录按本次实际 CI、交付回执另行说明。

参考：[GitHub latest release API](https://docs.github.com/en/rest/releases/releases#get-the-latest-release)、[API 请求次数限制](https://docs.github.com/en/rest/using-the-rest-api/rate-limits-for-the-rest-api)。
