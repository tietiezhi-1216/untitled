import AppKit
import Foundation
import SwiftUI
import Testing
import UntitledPluginSDK
@testable import UntitledHost

@Suite(.serialized) @MainActor
struct HostSoftwareUpdateTests {
    @Test func onlyNewerVersionsWithCompatibleHostArchivesOfferDownloadPages() {
        let installed = HostInstalledVersion(version: "0.13.0", build: "46")
        #expect(installed.display == "0.13.0（46）")
        #expect(release("0.12.5").compare(to: installed) == .ahead)
        #expect(release("0.13.0").compare(to: installed) == .current)
        #expect(release("0.14.0").compare(to: installed) == .newer)
        #expect(release("0.12.5").downloadPage(for: installed) == nil)
        #expect(release("0.13.0").downloadPage(for: installed) == nil)
        #expect(release("0.14.0", archive: false).downloadPage(for: installed) == nil)
        #expect(release("0.14.0").downloadPage(for: installed) == release("0.14.0").pageURL)
        let development = HostInstalledVersion(version: "development", build: nil)
        #expect(release("0.14.0").compare(to: development) == .unknown)
        #expect(release("0.14.0").downloadPage(for: development) == nil)
    }

    @Test func sourceIsHostRepositoryStableEndpointWithoutCredentialsOrPluginCatalog() async throws {
        let probe = RequestProbe()
        let data = try payload()
        let client = HostUpdateClient(architecture: .arm64, loader: { request, limit in
            await probe.record(request, limit: limit)
            return .init(url: request.url!, status: 200, data: data)
        })
        guard case .release(let result) = try await client.check() else { Issue.record("Expected host release"); return }
        #expect(result.version == "0.14.0" && result.hasCompatibleArchive)
        let requests = await probe.requests
        #expect(requests.count == 1 && requests[0].url?.absoluteString == "https://api.github.com/repos/tietiezhi-1216/untitled/releases/latest")
        #expect(requests[0].httpMethod == "GET")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[0].value(forHTTPHeaderField: "Cookie") == nil)
        #expect(requests[0].value(forHTTPHeaderField: "Accept") == "application/vnd.github+json")
        #expect(requests[0].cachePolicy == .reloadIgnoringLocalCacheData && requests[0].timeoutInterval == 20)
        #expect(await probe.limits == [HostUpdateClient.maximumBytes])
    }

    @Test func invalidOriginsAndRedirectedMetadataFailClosed() async throws {
        let probe = RequestProbe()
        for value in ["http://github.com/owner/repo", "https://github.com.evil.example/owner/repo", "https://github.com/owner/repo?token=x",
                      "https://name:secret@github.com/owner/repo", "https://github.com/owner/repo/releases"] {
            let client = HostUpdateClient(repository: URL(string: value)!, loader: { request, limit in
                await probe.record(request, limit: limit)
                return .init(url: request.url!, status: 404, data: Data())
            })
            await #expect(throws: HostUpdateError.self) { try await client.check() }
        }
        #expect(await probe.requests.isEmpty)
        let data = try payload()
        let redirected = HostUpdateClient(loader: { _, _ in .init(url: URL(string: "https://example.com/releases/latest")!, status: 200, data: data) })
        await #expect(throws: HostUpdateError.self) { try await redirected.check() }
        let mismatched = try payload(page: "https://github.com/another/repository/releases/tag/v0.14.0")
        await #expect(throws: HostUpdateError.self) { try await client(mismatched).check() }
    }

    @Test func stablePayloadRejectsPrereleasesDraftsMalformedVersionsAndOversizedMetadata() async throws {
        for tag in ["v1.2", "v1.2.3-beta", "v01.2.3", "v1.2.3/other", "v9999999999999999999999999999999.2.3"] {
            let data = try payload(tag: tag)
            await #expect(throws: HostUpdateError.self) { try await client(data).check() }
        }
        for data in [try payload(draft: true), try payload(prerelease: true), Data("not JSON".utf8), Data(repeating: 65, count: HostUpdateClient.maximumBytes + 1)] {
            await #expect(throws: HostUpdateError.self) { try await client(data).check() }
        }
        let tooMany = try payload(assets: (0..<257).map { _ in asset() })
        await #expect(throws: HostUpdateError.self) { try await client(tooMany).check() }
    }

    @Test func errorsAndAbsentStableReleasesAreNotReportedAsCurrent() async throws {
        #expect(try await client(Data(), status: 404).check() == .unpublished)
        for code in [403, 429, 500, 301] {
            await #expect(throws: HostUpdateError.self) { try await client(Data(), status: code).check() }
        }
    }

    @Test func archiveMatchingRequiresHostNameArchitectureUploadedStateAndSameReleaseSource() async throws {
        let cases: [([[String: Any]], Bool)] = [
            ([asset()], true),
            ([asset(name: "Untitled-macOS-universal-v0.14.0.dmg")], true),
            ([asset(name: "Untitled-macOS-x86_64-v0.14.0.zip")], false),
            ([asset(name: "peripheral-sharing-1.4.4.zip")], false),
            ([asset(name: "TietiezhiTools-macOS-arm64-v0.14.0.zip")], false),
            ([asset(state: "new")], false), ([asset(size: 0)], false),
            ([asset(url: "https://example.com/Untitled-macOS-arm64-v0.14.0.zip")], false),
            ([asset(url: "https://github.com/other/repo/releases/download/v0.14.0/Untitled-macOS-arm64-v0.14.0.zip")], false),
            ([], false)
        ]
        for (assets, expected) in cases {
            guard case .release(let release) = try await client(payload(assets: assets)).check() else { Issue.record("Missing release"); return }
            #expect(release.hasCompatibleArchive == expected)
        }
        let intel = try payload(assets: [asset(name: "Untitled-macOS-x86_64-v0.14.0.zip")])
        guard case .release(let release) = try await client(intel, architecture: .x86_64).check() else { Issue.record("Missing Intel release"); return }
        #expect(release.hasCompatibleArchive)
    }

    @Test func releaseNotesAreBoundedValidUTF8PlainText() async throws {
        let text = String(repeating: "a", count: 16_383) + "🐈" + String(repeating: "尾", count: 20_000)
        guard case .release(let release) = try await client(payload(notes: text)).check() else { Issue.record("Missing release"); return }
        #expect(release.notesTruncated && release.notes.utf8.count <= HostUpdateClient.maximumNoteBytes)
        #expect(!release.notes.contains("�") && release.notes == String(repeating: "a", count: 16_383))
    }

    @Test func releaseTitlesCannotBypassTheTextBudgetWithCombiningCharacters() async throws {
        let name = String(repeating: "e\u{301}", count: 4_000)
        guard case .release(let release) = try await client(payload(name: name)).check() else { Issue.record("Missing release"); return }
        #expect(release.title.utf8.count <= 320 && !release.title.contains("�"))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["UNTITLED_HOST_UPDATE_NETWORK_TEST"] == "1"))
    func publishedStableChannelCanBeReadWithoutDownloadingAnApplication() async throws {
        let report = try await HostUpdateClient().check()
        if case .release(let release) = report {
            #expect(Version(release.version) != nil && release.pageURL.host == "github.com")
            print("Public host-update metadata: " + release.version)
        }
    }

    @Test func checkingIsLazySingleFlightAndCancellationDrainsBeforeAnotherCheck() async throws {
        let checker = ControlledChecker()
        let model = HostSoftwareUpdate(installed: .init(version: "0.13.0", build: "46"), client: checker)
        #expect(await checker.calls == 0)
        #expect(!model.isChecking && model.report == nil && model.checkedAt == nil)
        model.check(); model.check()
        #expect(await wait { await checker.calls == 1 })
        #expect(model.isChecking)
        model.cancel(); #expect(model.isChecking && model.isCancelling && model.message == nil && model.checkedAt == nil)
        model.check(); #expect(await checker.calls == 1)
        await checker.finish(0, result: .success(.release(release("0.5.3"))))
        #expect(await wait { !model.isChecking && !model.isCancelling })
        #expect(model.report == nil && model.checkedAt == nil) // A cancelled late result is never published.
        model.check(); #expect(await wait { await checker.calls == 2 })
        let newer = HostUpdateReport.release(release("0.14.0"))
        await checker.finish(1, result: .success(newer))
        #expect(await wait { !model.isChecking && model.report == newer })
        let date = model.checkedAt
        #expect(model.message == nil)
        model.check(); #expect(await wait { await checker.calls == 3 })
        await checker.finish(2, result: .failure(URLError(.notConnectedToInternet)))
        #expect(await wait { !model.isChecking && model.message != nil })
        #expect(model.report == newer && model.checkedAt == date)
    }

    @Test func deinitDoesNotRetainAnUnfinishedCheckOrPublishLateResults() async throws {
        let checker = ControlledChecker()
        var model: HostSoftwareUpdate? = HostSoftwareUpdate(client: checker)
        weak var weakModel = model
        model?.check(); #expect(await wait { await checker.calls == 1 })
        model = nil
        #expect(weakModel == nil)
        await checker.finish(0, result: .success(.unpublished))
    }

    @Test func offscreenPaneHasNoAutomaticRequestsAndRendersBoundedNotes() async throws {
        let checker = ControlledChecker()
        let model = HostSoftwareUpdate(installed: .init(version: "0.13.0", build: "46"), client: checker)
        let view = NSHostingView(rootView: HostSoftwareUpdateView(update: model))
        view.frame = CGRect(x: 0, y: 0, width: 640, height: 386)
        view.layoutSubtreeIfNeeded()
        #expect(await checker.calls == 0)
        model.check(); #expect(await wait { await checker.calls == 1 })
        await checker.finish(0, result: .success(.release(release("0.14.0", notes: String(repeating: "更新内容\n", count: 150)))))
        #expect(await wait { !model.isChecking })
        try await Task.sleep(for: .milliseconds(30))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        #expect(await checker.calls == 1)
        if let path = ProcessInfo.processInfo.environment["UNTITLED_HOST_UPDATE_PREVIEW_DIR"] {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (name, appearanceName, scheme) in [("light", NSAppearance.Name.aqua, ColorScheme.light), ("dark", NSAppearance.Name.darkAqua, ColorScheme.dark)] {
                let preview = NSHostingView(rootView: HostSoftwareUpdateView(update: model).environment(\.colorScheme, scheme))
                let appearance = try #require(NSAppearance(named: appearanceName))
                preview.appearance = appearance; preview.frame = view.frame
                try await Task.sleep(for: .milliseconds(30))
                preview.layoutSubtreeIfNeeded()
                let rendered = try #require(preview.bitmapImageRepForCachingDisplay(in: preview.bounds))
                appearance.performAsCurrentDrawingAppearance { preview.cacheDisplay(in: preview.bounds, to: rendered) }
                try #require(rendered.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
            }
        }
        model.cancel()
    }

    private func release(_ version: String, archive: Bool = true, notes: String = "Changes") -> HostSoftwareRelease {
        .init(version: version, title: version, notes: notes, notesTruncated: false, publishedAt: nil,
              pageURL: HostInfo.repository.appendingPathComponent("releases/tag/v" + version), hasCompatibleArchive: archive)
    }
    private func asset(name: String = "Untitled-macOS-arm64-v0.14.0.zip", state: String = "uploaded", size: Int = 123,
                       url: String? = nil) -> [String: Any] {
        ["name": name, "state": state, "size": size,
         "browser_download_url": url ?? "https://github.com/tietiezhi-1216/untitled/releases/download/v0.14.0/\(name)"]
    }
    private func payload(tag: String = "v0.14.0", draft: Bool = false, prerelease: Bool = false, page: String? = nil,
                         notes: String = "# Changes\n\n- Update", assets: [[String: Any]]? = nil, name: String = "Release") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["tag_name": tag, "name": name, "body": notes,
            "published_at": "2026-11-10T05:52:55Z", "html_url": page ?? "https://github.com/tietiezhi-1216/untitled/releases/tag/\(tag)",
            "draft": draft, "prerelease": prerelease, "assets": assets ?? [asset()]])
    }
    private func client(_ data: Data, status: Int = 200, architecture: HostUpdateArchitecture = .arm64) -> HostUpdateClient {
        HostUpdateClient(architecture: architecture, loader: { request, _ in .init(url: request.url!, status: status, data: data) })
    }
    private func wait(_ predicate: () async -> Bool) async -> Bool {
        for _ in 0..<300 {
            if await predicate() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }
    private actor RequestProbe {
        var requests: [URLRequest] = []
        var limits: [Int] = []
        func record(_ request: URLRequest, limit: Int) { requests.append(request); limits.append(limit) }
    }
    private actor ControlledChecker: HostUpdateChecking {
        private var pending: [CheckedContinuation<HostUpdateReport, any Error>?] = []
        var calls: Int { pending.count }
        func check() async throws -> HostUpdateReport {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func finish(_ index: Int, result: Result<HostUpdateReport, any Error>) {
            pending[index]?.resume(with: result); pending[index] = nil
        }
    }
}
