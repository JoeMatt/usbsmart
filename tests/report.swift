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
        print("14 report checks passed")
    }
}
