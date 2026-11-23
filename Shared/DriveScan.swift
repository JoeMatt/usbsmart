import CryptoKit
import Foundation

/// A portable report with vendor-specific raw values preserved and no raw serial or WWN.
struct DriveSnapshot: Codable {
    let driveId: String?
    let readAt: Date
    let model: String
    let firmware: String
    let capacityBytes: UInt64
    let smartSupported: Bool
    let smartEnabled: Bool
    let verdict: String
    let verdictSource: String
    let issues: [String]
    let concerns: [String]
    let attributes: [AttributeRow]
    /// Added in 0.5.0; absent in older saved scans.
    var rotation: String? = nil
    var selfTest: SelfTestInfo? = nil

    struct AttributeRow: Codable {
        let id: UInt8
        let name: String
        let flags: UInt16
        let value: UInt8
        let worst: UInt8
        let threshold: UInt8?
        let rawValue: UInt64
        let displayValue: String
    }

    init(report: DriveReport, readAt: Date, driveId: String?) {
        self.driveId = driveId
        self.readAt = readAt
        model = report.identity.model
        firmware = report.identity.firmware
        capacityBytes = report.identity.capacityBytes
        smartSupported = report.identity.smartSupported
        smartEnabled = report.identity.smartEnabled
        verdict = report.verdict.rawValue.lowercased()
        rotation = report.identity.rotation
        selfTest = report.selfTest
        switch report.health {
        case .failed: verdictSource = "drive"
        case .passed where report.verdict == .passed: verdictSource = "drive"
        default: verdictSource = report.verdict == .unknown ? "unavailable" : "attributeThresholds"
        }
        concerns = report.concerns
        let table = report.table
        let validRows = table?.dataChecksumValid == true ? table?.attributes ?? [] : []
        if Set(validRows.map(\.id)).count != validRows.count {
            issues = report.issues + ["The drive returned duplicate SMART attribute IDs."]
            attributes = []
        } else {
            issues = report.issues
            attributes = validRows.map { row in
                AttributeRow(id: row.id, name: attributeNames[row.id] ?? "Attribute \(row.id)",
                             flags: row.flags, value: row.value, worst: row.worst,
                             threshold: table?.thresholdChecksumValid == true ? row.threshold : nil,
                             rawValue: row.raw48, displayValue: row.rawText)
            }.sorted { $0.id < $1.id }
        }
    }

    static func stableID(for identity: Identity) -> String? {
        func usable(_ text: String) -> Bool {
            let cleaned = text.uppercased().filter { $0.isLetter || $0.isNumber }
            return !cleaned.isEmpty && !cleaned.allSatisfy { $0 == "0" || $0 == "F" }
                && !["NA", "NONE", "UNKNOWN", "NOTAVAILABLE", "NOTSPECIFIED"].contains(cleaned)
        }
        let input: String
        if let wwn = identity.wwn, usable(wwn) {
            input = "ata-wwn\u{0}\(wwn)"
        } else if !identity.model.isEmpty, usable(identity.serial) {
            input = "ata-serial\u{0}\(identity.model)\u{0}\(identity.serial)"
        } else {
            return nil
        }
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct DriveReading: Identifiable {
    let id: String
    let report: DriveReport?
    let error: String?
    let readAt: Date
    var snapshot: DriveSnapshot? = nil

    enum Status: String, CaseIterable { case ok, partial, error }

    var status: Status {
        guard let snapshot else { return .error }
        return snapshot.issues.isEmpty ? .ok : .partial
    }

    var name: String { report?.identity.model ?? id }
}

struct DriveScan {
    let readings: [DriveReading]
    let completedAt: Date

    /// Use the same read path for the app and CLI. Recheck registry identity after the scan so a
    /// removed drive, or a different disk reusing its BSD name, cannot be reported as present.
    static func readConnected() -> DriveScan {
        let observed = SmartDisk.all().map { disk -> (UInt64, DriveReading) in
            do {
                let report = try DriveReport.read(disk)
                return (disk.registryID, DriveReading(id: disk.bsdName, report: report, error: nil, readAt: Date()))
            } catch {
                return (disk.registryID, DriveReading(id: disk.bsdName, report: nil,
                                                     error: String(describing: error), readAt: Date()))
            }
        }
        let present = Set(SmartDisk.all().map(\.registryID))
        return DriveScan(readings: observed.filter { present.contains($0.0) }.map(\.1), completedAt: Date())
    }

    init(readings: [DriveReading], completedAt: Date) {
        let ids = readings.map { $0.report.flatMap { DriveSnapshot.stableID(for: $0.identity) } }
        let counts = ids.compactMap { $0 }.reduce(into: [String: Int]()) { $0[$1, default: 0] += 1 }
        self.readings = zip(readings, ids).map { reading, id in
            var item = reading
            if let report = item.report {
                let uniqueID = id.flatMap { counts[$0] == 1 ? $0 : nil }
                item.snapshot = DriveSnapshot(report: report, readAt: item.readAt, driveId: uniqueID)
            }
            return item
        }
        self.completedAt = completedAt
    }

    var exitStatus: Int32 {
        if readings.contains(where: { $0.report?.verdict == .failed }) { return 4 }
        return readings.contains(where: { $0.status != .ok }) ? 1 : 0
    }

    func json() throws -> Data {
        struct Row: Encodable {
            let disk: String
            let readAt: Date
            let status: String
            let report: DriveSnapshot?
            let error: String?
        }
        struct Document: Encodable {
            let schemaVersion = 1
            let scannedAt: Date
            let drives: [Row]
        }
        let drives = readings.map {
            Row(disk: $0.id, readAt: $0.readAt,
                status: $0.status.rawValue,
                report: $0.snapshot, error: $0.error)
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(scannedAt: completedAt, drives: drives))
    }
}
