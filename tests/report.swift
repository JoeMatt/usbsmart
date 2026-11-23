import Foundation

@main
struct ReportTests {
    static func main() throws {
        let directory = CommandLine.arguments[1]
        func page(_ name: String) throws -> [UInt8] {
            Array(try Data(contentsOf: URL(fileURLWithPath: directory + "/" + name)))
        }
        let identify = try page("identify.bin")
        let data = try page("smart-data.bin")
        let thresholds = try page("smart-thresholds.bin")
        func report(_ data: [UInt8]?, _ thresholds: [UInt8]?, _ health: Health = .unknown("No registers")) -> DriveReport {
            DriveReport(identify: identify, data: data, thresholds: thresholds, health: health)
        }
        func check(_ condition: Bool, _ message: String) {
            guard condition else { fatalError(message) }
        }
        check(report(data, thresholds).verdict == .passed, "Valid thresholds should allow a derived pass")
        check(report(data, nil).verdict == .unknown, "Missing thresholds must not produce a pass")
        check(report(nil, nil).verdict == .unknown, "Missing attributes must not produce a pass")
        check(report(data, thresholds, .failed).verdict == .failed, "Keep the drive's failure verdict")
        var corrupt = data
        corrupt[100] ^= 1
        check(report(corrupt, thresholds).verdict == .unknown, "Bad checksum must not produce a pass")
        check(report(corrupt, thresholds).concerns.isEmpty, "Do not interpret corrupt counters")
        var corruptThresholds = thresholds
        corruptThresholds[100] ^= 1
        check(report(data, corruptThresholds).verdict == .unknown, "Bad thresholds must not produce a derived pass")
        let empty = [UInt8](repeating: 0, count: 512)
        check(report(empty, thresholds).verdict == .unknown, "Empty attributes must not produce a pass")
        check(report(data, empty).verdict == .unknown, "Unmatched thresholds must not produce a pass")
        var failing = data
        failing[5] = 1 // First attribute's normalized value, below threshold 16.
        failing[511] = 0
        failing[511] = 0 &- failing.reduce(UInt8(0), &+)
        check(report(failing, thresholds).verdict == .failed, "Threshold failure must be visible")
        check(report(failing, thresholds, .passed).verdict == .failed, "An attribute failure must not be hidden by a passing drive status")
        check(report(data, thresholds).concerns.contains(where: { $0.contains("24") }), "Remapped sectors should be called out")
        check(report(data, thresholds).metric(194)?.hasPrefix("35") == true, "Temperature must come from raw data")
        // Return status unavailable, but SMART disabled: there should be an explanation.
        var disabled = identify
        disabled[170] &= 0xfe
        let off = DriveReport(identify: disabled, data: nil, thresholds: nil, health: .unknown("No data"))
        check(off.issues.contains(where: { $0.contains("switched off") }), "Explain disabled SMART")
        let first = Date(timeIntervalSince1970: 1000)
        let second = Date(timeIntervalSince1970: 2000)
        func scan(_ rows: [(String, DriveReport?)], at date: Date) -> DriveScan {
            DriveScan(readings: rows.map {
                DriveReading(id: $0.0, report: $0.1, error: $0.1 == nil ? "Drive stopped responding" : nil, readAt: date)
            }, completedAt: date)
        }
        let initial = scan([("disk9", report(data, thresholds))], at: first)
        let id = initial.readings[0].snapshot!.driveId!
        let historyFile = URL(fileURLWithPath: directory).appendingPathComponent("history-v1.json")
        var history = try ScanHistory.load(from: historyFile)
        check(history.drives.isEmpty, "A missing history file must open an empty history")
        history.record(initial.readings)
        let invalid = scan([("disk12", report(corrupt, thresholds))], at: second)
        check(!history.record(invalid.readings), "A corrupt read must not supplant a valid baseline")
        let current = scan([("disk12", report(failing, thresholds)), ("disk13", nil)], at: second)
        history.record(current.readings)
        try history.save(to: historyFile)
        let saved = try ScanHistory.load(from: historyFile)
        let snapshots = saved.drives[id]!
        check(snapshots.count == 2 && snapshots[0].readAt == second && snapshots[1].readAt == first,
              "Record both valid scans under one drive ID despite the BSD rename")
        let changes = ScanChange.between(snapshots[1], snapshots[0])
        check(changes.contains { $0.id == "1-value" && $0.before == "100" && $0.after == "1" },
              "Compare normalized attribute values across persisted scans")
        check(changes.contains { $0.id == "verdict" && $0.after == "Failed" }, "Show health transitions")
        check(ScanChange.between(snapshots[0], snapshots[0]).isEmpty, "Identical scans should show no changes")

        let json = try current.json()
        let jsonText = String(decoding: json, as: UTF8.self)
        let document = try JSONSerialization.jsonObject(with: json) as! [String: Any]
        let rows = document["drives"] as! [[String: Any]]
        check(document["schemaVersion"] as? Int == 1 && rows.count == 2, "Export each connected drive")
        check(rows[1]["status"] as? String == "error" && rows[1]["error"] as? String == "Drive stopped responding",
              "Preserve failed reads in the export")
        check(!jsonText.contains("TESTSERIAL0001") && !jsonText.contains("5000cca212345678"),
              "Omit the raw serial and WWN")
        check(current.exitStatus == 4 && invalid.exitStatus == 1, "Preserve health and read-error exit codes")
        check(invalid.readings[0].snapshot?.attributes.isEmpty == true, "Do not export corrupt attribute values")
        let noThresholds = scan([("disk12", report(data, corruptThresholds))], at: second)
        check(noThresholds.readings[0].snapshot?.attributes.allSatisfy { $0.threshold == nil } == true,
              "Do not export a threshold from a corrupt page")
        let duplicate = scan([("disk9", report(data, thresholds)), ("disk12", report(data, thresholds))], at: first)
        check(!history.record(duplicate.readings), "Do not merge two connected drives with the same identity")
        for _ in 0..<ScanHistory.scansPerDrive { history.record(initial.readings) }
        check(history.drives[id]?.count == ScanHistory.scansPerDrive, "Cap retained history for each drive")
        print("Report, scan history, and JSON export checks passed")
    }
}
