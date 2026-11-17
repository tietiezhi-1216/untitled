import SwiftUI

struct HostSoftwareUpdateView: View {
    @ObservedObject var update: HostSoftwareUpdate
    @ViewState private var showingNotes = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "arrow.down.app")
                .font(.system(size: 36, weight: .light)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(spacing: 5) {
                Text(HostInfo.name).font(.title2.weight(.semibold))
                Text("版本 \(update.installed.display)").font(.callout).foregroundStyle(.secondary)
                    .accessibilityIdentifier("host.update.currentVersion")
            }
            if !summary.isEmpty {
                Text(summary).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).lineLimit(3)
                    .accessibilityIdentifier("host.update.status")
            }
            HStack(spacing: 12) {
                if update.isChecking {
                    ProgressView().controlSize(.small)
                    Button("取消") { update.cancel() }.disabled(update.isCancelling)
                } else if let page = release?.downloadPage(for: update.installed) {
                    Link("前往下载", destination: page).buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("host.update.downloadPage")
                    Button("重新检查") { update.check() }
                        .accessibilityIdentifier("host.update.check")
                } else {
                    Button("检查更新") { update.check() }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("host.update.check")
                }
            }
            if let release, release.compare(to: update.installed) == .newer, !release.notes.isEmpty {
                DisclosureGroup("更新说明", isExpanded: $showingNotes) {
                    ScrollView {
                        Text(verbatim: release.notes).font(.callout).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 8)
                    }
                    .frame(maxHeight: 110)
                }
                .font(.callout)
                .frame(maxWidth: 480)
            }
            Spacer(minLength: 0)
            Link("发布记录", destination: HostInfo.repository.appendingPathComponent("releases"))
                .font(.caption)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .accessibilityIdentifier("host.softwareUpdate")
        .onChange(of: update.report) { _, _ in showingNotes = false }
        .onDisappear { update.cancel(); showingNotes = false }
    }

    private var release: HostSoftwareRelease? {
        guard !update.isChecking, update.message == nil, let report = update.report,
              case .release(let release) = report else { return nil }
        return release
    }
    private var summary: String {
        if update.isChecking { return update.isCancelling ? "正在取消…" : "正在检查更新…" }
        if let message = update.message { return message }
        guard let report = update.report else { return "" }
        switch report {
        case .unpublished: return "暂无可读取的正式版本。"
        case .release(let release):
            switch release.compare(to: update.installed) {
            case .newer:
                return release.hasCompatibleArchive ? "新版本 \(release.version) 可用。" : "版本 \(release.version) 暂无适合此 Mac 的安装包。"
            case .current: return "已是最新正式版。"
            case .ahead: return "当前版本较新，无需更新。"
            case .unknown: return "无法比较版本，请查看发布记录。"
            }
        }
    }
}
