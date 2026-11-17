import Combine
import Foundation

struct HostInstalledVersion: Equatable, Sendable {
    let version: String
    let build: String?
    static var current: Self {
        Self(version: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? HostInfo.version,
             build: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
    }
    var display: String { build.map { "\(version)（\($0)）" } ?? version }
}

enum HostUpdateArchitecture: String, Sendable {
    case arm64, x86_64
    static var current: Self {
        #if arch(arm64)
        .arm64
        #else
        .x86_64
        #endif
    }
}

struct HostSoftwareRelease: Equatable, Sendable {
    let version: String
    let title: String
    let notes: String
    let notesTruncated: Bool
    let publishedAt: Date?
    let pageURL: URL
    let hasCompatibleArchive: Bool

    enum Comparison { case newer, current, ahead, unknown }
    func compare(to installed: HostInstalledVersion) -> Comparison {
        guard let current = Version(installed.version), let published = Version(version) else { return .unknown }
        if current < published { return .newer }
        return current == published ? .current : .ahead
    }
    func downloadPage(for installed: HostInstalledVersion) -> URL? {
        compare(to: installed) == .newer && hasCompatibleArchive ? pageURL : nil
    }
}

enum HostUpdateReport: Equatable, Sendable {
    case unpublished
    case release(HostSoftwareRelease)
}

enum HostUpdateError: LocalizedError {
    case invalidSource, invalidRelease, tooLarge, rateLimited, http(Int), network
    var errorDescription: String? {
        switch self {
        case .invalidSource: "更新来源无效，请前往项目发布页确认。"
        case .invalidRelease: "正式版信息不完整或来源不匹配，请稍后重试。"
        case .tooLarge: "发布信息超过大小限制，请前往发布页查看。"
        case .rateLimited: "GitHub 暂时限制了更新请求，请稍后重试或查看发布记录。"
        case .http(let code): "发布服务暂时不可用（HTTP \(code)），请稍后重试。"
        case .network: "无法连接更新服务，请检查网络后重试。"
        }
    }
}

struct HostUpdateHTTPResponse: Sendable {
    let url: URL
    let status: Int
    let data: Data
}

protocol HostUpdateChecking: Sendable {
    func check() async throws -> HostUpdateReport
}

/// Manual, metadata-only requests. No credentials, cookies, downloads, polling or installer.
struct HostUpdateClient: HostUpdateChecking {
    static let maximumBytes = 1024 * 1024
    static let maximumNoteBytes = 16 * 1024
    typealias Loader = @Sendable (URLRequest, Int) async throws -> HostUpdateHTTPResponse
    let repository: URL
    let architecture: HostUpdateArchitecture
    private let loader: Loader

    init(repository: URL = HostInfo.repository, architecture: HostUpdateArchitecture = .current,
         loader: @escaping Loader = HostUpdateClient.load) {
        self.repository = repository; self.architecture = architecture; self.loader = loader
    }

    func check() async throws -> HostUpdateReport {
        let components = repository.path.split(separator: "/")
        guard Self.isHTTPS(repository, host: "github.com"), components.count == 2,
              components.allSatisfy({ $0.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil })
        else { throw HostUpdateError.invalidSource }
        let repoPath = components.joined(separator: "/")
        let endpoint = URL(string: "https://api.github.com/repos/\(repoPath)/releases/latest")!
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("Untitled/\(HostInfo.version)", forHTTPHeaderField: "User-Agent")
        let response = try await loader(request, Self.maximumBytes)
        try Task.checkCancellation()
        guard response.url == endpoint else { throw HostUpdateError.invalidSource }
        if response.status == 404 { return .unpublished }
        if response.status == 403 || response.status == 429 { throw HostUpdateError.rateLimited }
        guard response.status == 200 else { throw HostUpdateError.http(response.status) }
        guard response.data.count <= Self.maximumBytes else { throw HostUpdateError.tooLarge }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let release = try? decoder.decode(Payload.self, from: response.data), !release.draft, !release.prerelease,
              release.assets.count <= 256, release.tag_name.utf8.count <= 64 else { throw HostUpdateError.invalidRelease }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard version.range(of: #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil,
              Version(version) != nil else { throw HostUpdateError.invalidRelease }
        let page = URL(string: "https://github.com/\(repoPath)/releases/tag/\(release.tag_name)")!
        guard release.html_url == page else { throw HostUpdateError.invalidSource }
        let compatible = release.assets.contains { asset in
            guard asset.state == "uploaded", asset.size > 0 else { return false }
            let names = [architecture.rawValue, "universal"].flatMap { arch in
                ["zip", "dmg"].map { "Untitled-macOS-\(arch)-\(release.tag_name).\($0)" }
            }
            return names.contains(asset.name) && asset.browser_download_url ==
                URL(string: "https://github.com/\(repoPath)/releases/download/\(release.tag_name)/\(asset.name)")
        }
        let notes = release.body ?? ""
        let truncated = notes.utf8.count > Self.maximumNoteBytes
        return .release(HostSoftwareRelease(version: version,
            title: Self.boundedText(release.name ?? release.tag_name, maximumBytes: 320),
            notes: Self.boundedText(notes, maximumBytes: Self.maximumNoteBytes), notesTruncated: truncated,
            publishedAt: release.published_at, pageURL: page, hasCompatibleArchive: compatible))
    }

    private static func boundedText(_ text: String, maximumBytes: Int) -> String {
        var bytes = Data(text.utf8.prefix(maximumBytes))
        while String(data: bytes, encoding: .utf8) == nil { bytes.removeLast() }
        return String(decoding: bytes, as: UTF8.self)
    }
    private struct Payload: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let published_at: Date?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    private struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
        let size: Int64
        let state: String
    }
    private static func isHTTPS(_ url: URL, host: String) -> Bool {
        url.scheme == "https" && url.host == host && url.port == nil && url.user == nil && url.password == nil
            && url.query == nil && url.fragment == nil
    }

    private static func load(_ request: URLRequest, limit: Int) async throws -> HostUpdateHTTPResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 25
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        return try await withTaskCancellationHandler {
            let (bytes, response) = try await session.bytes(for: request)
            guard let response = response as? HTTPURLResponse, response.url == request.url, let url = response.url else {
                throw HostUpdateError.invalidSource
            }
            guard response.statusCode == 200 else { return .init(url: url, status: response.statusCode, data: Data()) }
            guard response.expectedContentLength <= limit else { throw HostUpdateError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                guard data.count < limit else { throw HostUpdateError.tooLarge }
                data.append(byte)
            }
            try Task.checkCancellation()
            return .init(url: url, status: response.statusCode, data: data)
        } onCancel: { session.invalidateAndCancel() }
    }
    private final class NoRedirects: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

@MainActor final class HostSoftwareUpdate: ObservableObject {
    let installed: HostInstalledVersion
    @Published private(set) var isChecking = false
    @Published private(set) var isCancelling = false
    @Published private(set) var report: HostUpdateReport?
    @Published private(set) var message: String?
    @Published private(set) var checkedAt: Date?
    private let client: any HostUpdateChecking
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(installed: HostInstalledVersion = .current, client: any HostUpdateChecking = HostUpdateClient()) {
        self.installed = installed; self.client = client
    }
    deinit { task?.cancel() }
    func check() {
        guard task == nil else { return }
        generation &+= 1
        let expected = generation, client = client
        isChecking = true; isCancelling = false; message = nil
        task = Task { @MainActor [weak self] in
            do {
                let report = try await client.check()
                try Task.checkCancellation()
                guard let self, self.generation == expected else { return }
                self.report = report; self.checkedAt = Date(); self.isChecking = false; self.isCancelling = false; self.task = nil
            } catch {
                guard let self, self.generation == expected else { return }
                self.isChecking = false; self.isCancelling = false; self.task = nil
                if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { return }
                self.message = (error as? HostUpdateError)?.errorDescription ?? HostUpdateError.network.errorDescription
            }
        }
    }
    func cancel() {
        guard let task else { return }
        // Keep ownership until cancellation actually drains; repeated cancel/retry
        // must not accumulate old requests while a service is slow to finish.
        isCancelling = true; task.cancel()
    }
}
