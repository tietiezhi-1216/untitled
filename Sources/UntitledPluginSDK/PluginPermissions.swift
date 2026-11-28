import Foundation

package struct HostPermissionID: RawRepresentable, Hashable, Codable, Sendable {
    package let rawValue: String
    package init(rawValue: String) { self.rawValue = rawValue }
    package init(from decoder: any Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    package static let screenRecording = Self(rawValue: "system.screenRecording")
    package static let accessibility = Self(rawValue: "system.accessibility")
    package static let inputMonitoring = Self(rawValue: "system.inputMonitoring")
    package static let camera = Self(rawValue: "system.camera")
    package static let bluetooth = Self(rawValue: "system.bluetooth")
    package static let microphone = Self(rawValue: "system.microphone")
    package static let notifications = Self(rawValue: "system.notifications")
}

package struct PluginPermissionDeclaration: Codable, Equatable, Sendable {
    package let id: HostPermissionID
    package let reason: String
    package var optional: Bool?
    package var isOptional: Bool { optional == true }

    package init(id: HostPermissionID, reason: String, optional: Bool? = nil) {
        self.id = id
        self.reason = reason
        self.optional = optional
    }
}

/// A plugin receives this client from the host; it cannot manufacture an OS grant.
@MainActor package struct PluginPermissionClient {
    package let isAuthorized: (HostPermissionID) -> Bool
    package let require: (Set<HostPermissionID>) throws -> Void
    package init(isAuthorized: @escaping (HostPermissionID) -> Bool = { _ in false },
         require: @escaping (Set<HostPermissionID>) throws -> Void) {
        self.isAuthorized = isAuthorized; self.require = require
    }
}
