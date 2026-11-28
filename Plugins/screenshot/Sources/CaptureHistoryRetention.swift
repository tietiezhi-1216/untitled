import Foundation
import UntitledPluginSDK

enum CaptureHistoryRetention {
    static let daysKey = "capture.historyRetentionDays"
    static let rolloutKey = "capture.historyRetentionStartedAt"
    static let defaultDays = 7
    static let customDays = 1...3650
    static let secondsPerDay: TimeInterval = 86_400
    static let batchSize = 4

    static func readDays(from defaults: UserDefaults) -> Int {
        guard let stored = defaults.object(forKey: daysKey) else { return defaultDays }
        // A corrupt preference must not shorten the lifetime of any files.
        guard let days = stored as? Int, customDays.contains(days) else { return 0 }
        return days
    }

    static func deadline(for record: CaptureRecord, days: Int, rollout: Date) -> Date? {
        guard customDays.contains(days) else { return nil }
        let expires = record.date.addingTimeInterval(Double(days) * secondsPerDay)
        // Give pre-upgrade history a full week to allow users to opt out.
        guard record.date < rollout else { return expires }
        return max(expires, rollout.addingTimeInterval(Double(defaultDays) * secondsPerDay))
    }

    /// Keep the original index if a move or the atomic index write fails. Trash
    /// provides actual destination URLs so a partial batch can be put back.
    static func moveToTrash(
        _ files: [URL], move: (URL) throws -> URL, commit: () throws -> Void
    ) throws {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        let existing = try files.filter { file in
            let values: URLResourceValues
            do { values = try file.resourceValues(forKeys: keys) }
            catch let error as NSError where error.domain == NSCocoaErrorDomain
                && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) { return false }
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw PluginError.invalid("发现不属于应用的历史文件，已跳过清理。")
            }
            return true
        }
        var moved: [(from: URL, to: URL)] = []
        do {
            for file in existing { moved.append((file, try move(file))) }
            try commit()
        } catch {
            var failed = false
            for item in moved.reversed() {
                do { try FileManager.default.moveItem(at: item.to, to: item.from) }
                catch { failed = true }
            }
            if failed { throw PluginError.invalid("清理未完成，部分文件可在废纸篓中找回。") }
            throw error
        }
    }

    static func trash(_ file: URL) throws -> URL {
        var destination: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &destination)
        guard let destination else { throw PluginError.invalid("未能确认文件已移到废纸篓。") }
        return destination as URL
    }
}
