//
//  SelfTest.swift
//
//  Decoders for what a drive records about its own self-tests: the execution status in SMART
//  READ DATA, the self-test log (log 06h) and the error count in the summary error log (01h).
//  Reading these sends nothing new to the drive beyond SMART READ LOG.
//

import Foundation

/// The self-tests a drive can be asked to run. Raw values are the ATA subcommands for
/// SMART EXECUTE OFF-LINE IMMEDIATE in off-line (background) mode. The captive forms (81h-84h),
/// which hold the drive busy, are deliberately absent.
enum SelfTestKind: UInt8, CaseIterable {
    case short = 0x01
    case long = 0x02
    case conveyance = 0x03
    case abort = 0x7F

    init?(name: String) {
        switch name.lowercased() {
        case "short": self = .short
        case "long", "extended": self = .long
        case "conveyance": self = .conveyance
        case "abort", "stop": self = .abort
        default: return nil
        }
    }
}

struct SelfTestInfo: Codable, Equatable {
    struct Entry: Codable, Equatable {
        let type: String
        let result: String
        let passed: Bool
        let percentRemaining: Int
        let lifetimeHours: Int
        let firstFailingLBA: UInt64?
    }

    /// The drive says it implements self-tests at all.
    let supported: Bool
    let conveyanceSupported: Bool
    /// A test is running now.
    let running: Bool
    let percentRemaining: Int?
    /// What the drive says about the most recent test, in words.
    let status: String
    /// The most recent test ended in a failure the drive attributes to itself.
    let lastFailed: Bool
    let shortMinutes: Int?
    let longMinutes: Int?
    /// Newest first. Empty when the log could not be read or the drive has never run a test.
    let log: [Entry]
    /// Device errors counted in the summary error log, nil when that log could not be read.
    let ataErrorCount: Int?

    static func describe(statusCode: UInt8) -> (text: String, failed: Bool) {
        switch statusCode {
        case 0: return ("completed without error", false)
        case 1: return ("aborted by the host", false)
        case 2: return ("interrupted by a reset", false)
        case 3: return ("could not complete (fatal or unknown error)", true)
        case 4: return ("failed: an unknown test element", true)
        case 5: return ("failed: electrical element", true)
        case 6: return ("failed: servo or seek element", true)
        case 7: return ("failed: read element", true)
        case 8: return ("failed: suspected handling damage", true)
        case 15: return ("in progress", false)
        default: return ("reserved status \(statusCode)", false)
        }
    }

    static func typeName(_ subcommand: UInt8) -> String {
        switch subcommand & 0x7F {
        case 0: return "offline"
        case 1: return "short"
        case 2: return "long"
        case 3: return "conveyance"
        case 4: return "selective"
        default: return String(format: "vendor (%02xh)", subcommand)
        }
    }

    /// `data` is the SMART READ DATA page; the two logs are optional.
    init(data: [UInt8], selfTestLog: [UInt8]?, errorLog: [UInt8]?) {
        precondition(data.count == 512)
        let execution = data[363]
        let code = execution >> 4
        let capability = data[367]
        supported = capability & 0x10 != 0
        conveyanceSupported = capability & 0x20 != 0
        running = code == 15
        percentRemaining = running ? Int(execution & 0x0F) * 10 : nil
        let described = SelfTestInfo.describe(statusCode: code)
        lastFailed = described.failed
        shortMinutes = data[372] == 0 ? nil : Int(data[372])
        // FFh in the one-byte field means the time is in the 16-bit field that follows.
        let extended = data[373] == 0xFF ? Int(data.le16(375)) : Int(data[373])
        longMinutes = extended == 0 ? nil : extended

        var entries: [Entry] = []
        if let page = selfTestLog, page.count == 512 {
            let newest = Int(page[508])
            if (1...21).contains(newest) {
                for step in 0..<21 {
                    let slot = (newest - 1 - step + 21) % 21
                    let offset = 2 + slot * 24
                    let raw = Array(page[offset..<(offset + 24)])
                    guard raw.contains(where: { $0 != 0 }) else { continue }
                    let entryCode = raw[1] >> 4
                    let outcome = SelfTestInfo.describe(statusCode: entryCode)
                    let lba = UInt64(raw.le32(5))
                    entries.append(Entry(type: SelfTestInfo.typeName(raw[0]), result: outcome.text,
                                         passed: entryCode == 0, percentRemaining: Int(raw[1] & 0x0F) * 10,
                                         lifetimeHours: Int(raw.le16(2)),
                                         firstFailingLBA: outcome.failed && lba != 0xFFFF_FFFF && lba != 0 ? lba : nil))
                }
            }
        }
        log = entries
        status = entries.isEmpty && code == 0 ? "no test has been run" : described.text
        if let page = errorLog, page.count == 512 {
            ataErrorCount = Int(page.le16(452))
        } else {
            ataErrorCount = nil
        }
    }
}
