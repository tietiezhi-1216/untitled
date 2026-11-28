import Foundation
import UntitledHost
import UntitledPluginSDK

// Keep credentials out of the wire-only build of the diagnostic peer.
extension SharingPairingKey {
    static let builtInPluginID = "com.untitled.peripheral-sharing"
    private static let account = "pairing-v1"
    static func service(for pluginID: String) -> String {
        let original = HostInfo.bundleIdentifier + ".peripheral-sharing"
        return pluginID == builtInPluginID ? original : original + ".plugin." + pluginID
    }
    static func load(for pluginID: String) -> String? {
        guard let data = try? AppCredentials.read(service: service(for: pluginID), account: account) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    static func save(_ value: String, for pluginID: String) throws {
        _ = try decode(value)
        let data = Data(value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().utf8)
        try AppCredentials.save(data, service: service(for: pluginID), account: account)
    }
    static func delete(for pluginID: String) throws {
        try AppCredentials.delete(service: service(for: pluginID), account: account)
    }
}
