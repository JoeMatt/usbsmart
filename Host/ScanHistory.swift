import Foundation

struct ScanHistory: Codable {
    static let scansPerDrive = 100
    private(set) var drives: [String: [DriveSnapshot]] = [:]

    /// Missing or corrupt attribute pages must not displace the previous valid comparison.
    @discardableResult
    mutating func record(_ readings: [DriveReading]) -> Bool {
        var changed = false
        for reading in readings {
            guard let snapshot = reading.snapshot, let id = snapshot.driveId,
                  !snapshot.attributes.isEmpty else { continue }
            let previous = drives[id] ?? []
            drives[id] = Array(([snapshot] + previous).prefix(Self.scansPerDrive))
            changed = true
        }
        return changed
    }

    static func load(from url: URL) throws -> ScanHistory {
        do {
            return try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Self()
        }
    }

    func save(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
    }
}

struct ScanChange: Identifiable {
    let id: String
    let name: String
    let before: String
    let after: String

    static func between(_ previous: DriveSnapshot, _ current: DriveSnapshot) -> [ScanChange] {
        var result: [ScanChange] = []
        func add(_ id: String, _ name: String, _ before: String, _ after: String) {
            guard before != after else { return }
            result.append(ScanChange(id: id, name: name, before: before, after: after))
        }
        add("verdict", "SMART health", previous.verdict.capitalized, current.verdict.capitalized)
        add("firmware", "Firmware", previous.firmware, current.firmware)
        let before = Dictionary(previous.attributes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(current.attributes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for id in Set(before.keys).union(after.keys).sorted() {
            let old = before[id]
            let new = after[id]
            let name = new?.name ?? old?.name ?? "Attribute \(id)"
            add("\(id)-raw", name, old?.displayValue ?? "Not reported", new?.displayValue ?? "Not reported")
            if let old, let new {
                add("\(id)-value", "\(name) · normalized", String(old.value), String(new.value))
                add("\(id)-worst", "\(name) · worst", String(old.worst), String(new.worst))
                if let old = old.threshold, let new = new.threshold {
                    add("\(id)-threshold", "\(name) · threshold", String(old), String(new))
                }
            }
        }
        return result
    }
}
