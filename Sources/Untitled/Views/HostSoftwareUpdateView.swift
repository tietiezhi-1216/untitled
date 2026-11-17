import SwiftUI

struct HostSoftwareUpdateView: View {
    @ObservedObject var update: HostSoftwareUpdate

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle")
                    .font(.system(size: 32, weight: .light)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("软件更新").font(.title2.weight(.semibold))
                    Text("Untitled 软件本体 · 正式发布渠道").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if update.isChecking {
                    ProgressView().controlSize(.small)
                    Button("取消") { update.cancel() }.disabled(update.isCancelling)
                } else {
                    Button("检查更新") { update.check() }
                        .accessibilityIdentifier("host.update.check")
                }
            }
            HStack {
                LabeledContent("当前版本", value: update.installed.display)
                    .accessibilityIdentifier("host.update.currentVersion")
                Spacer(minLength: 20)
                if let date = update.checkedAt {
                    Text("上次成功 \(date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if update.isChecking {
                        status(update.isCancelling ? "正在取消检查…" : "正在检查正式发布版…", symbol: "arrow.triangle.2.circlepath")
                    } else if let message = update.message {
                        status(message, symbol: "exclamationmark.triangle", warning: true)
                    } else if let report = update.report {
                        switch report {
                        case .unpublished:
                            status("此渠道尚无可读取的正式版本。", symbol: "shippingbox")
                        case .release(let release):
                            releaseContent(release)
                        }
                    } else {
                        status("点击“检查更新”获取最新正式版信息。", symbol: "info.circle")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.trailing, 2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(alignment: .top, spacing: 16) {
                Text("仅手动检查；本页不会下载或安装。插件更新请前往商店。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Link("所有发布记录", destination: HostInfo.repository.appendingPathComponent("releases"))
                    .font(.caption)
            }
        }
        .padding(24)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("host.softwareUpdate")
        .onDisappear { update.cancel() }
    }

    @ViewBuilder private func releaseContent(_ release: HostSoftwareRelease) -> some View {
        switch release.compare(to: update.installed) {
        case .newer:
            status("发现新版本 \(release.version)", symbol: "arrow.down.circle")
        case .current:
            status("当前已是正式渠道最新版本。", symbol: "checkmark.circle")
        case .ahead:
            status("当前版本领先正式发布渠道，无需降级。", symbol: "checkmark.circle")
        case .unknown:
            status("无法比较当前构建版本，请查看发布记录。", symbol: "info.circle")
        }
        HStack {
            Text("最新正式版 \(release.version)").font(.callout.weight(.medium))
            Spacer()
            if let date = release.publishedAt {
                Text(date.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
        }
        if let page = release.downloadPage(for: update.installed) {
            HStack {
                Link(destination: page) { Label("前往下载", systemImage: "arrow.up.right") }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("host.update.downloadPage")
                Text("在浏览器打开发布页").font(.caption).foregroundStyle(.secondary)
            }
            Text("本页未验证安装包签名，请在安装前确认发布说明与签名。")
                .font(.caption).foregroundStyle(.secondary)
        } else if release.compare(to: update.installed) == .newer {
            Text("此正式版尚无适用于当前 Mac 的本体安装包。")
                .font(.callout).foregroundStyle(.secondary)
        }
        if !release.notes.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("更新说明").font(.callout.weight(.semibold))
                if !release.title.isEmpty, release.title != release.version, release.title != "v" + release.version {
                    Text(verbatim: release.title).font(.callout.weight(.medium))
                }
                Text(verbatim: release.notes).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if release.notesTruncated {
                    Text("发布说明较长，此处仅显示开头；完整内容请查看发布记录。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func status(_ text: String, symbol: String, warning: Bool = false) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .foregroundStyle(warning ? Color.orange : Color.primary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("host.update.status")
    }
}
