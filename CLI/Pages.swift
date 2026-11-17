//
//  Pages.swift
//
//  Decoders for the raw 512-byte ATA pages: IDENTIFY DEVICE, SMART READ DATA and
//  SMART READ THRESHOLDS, plus the answer to SMART RETURN STATUS.
//

import Foundation

/// The parts of IDENTIFY DEVICE that identify a drive.
struct Identity {
    let model: String
    let serial: String
    let firmware: String
    let wwn: String?
    let sectors: UInt64
    let logicalSectorSize: Int
    let physicalSectorSize: Int
    let rotation: String
    let smartSupported: Bool
    let smartEnabled: Bool

    init(_ page: [UInt8]) {
        func word(_ index: Int) -> UInt16 { page.le16(index * 2) }
        // ATA strings are stored with the two bytes of each word swapped.
        func string(_ first: Int, _ last: Int) -> String {
            var bytes: [UInt8] = []
            for index in first...last {
                bytes.append(UInt8(word(index) >> 8))
                bytes.append(UInt8(word(index) & 0xFF))
            }
            let text = String(bytes: bytes.map { (0x20...0x7E).contains($0) ? $0 : 0x20 }, encoding: .ascii) ?? ""
            return text.trimmingCharacters(in: .whitespaces)
        }

        serial = string(10, 19)
        firmware = string(23, 26)
        model = string(27, 46)

        // Word 87 bit 8: the World Wide Name in words 108-111 is valid.
        if word(87) & 0x0100 != 0 {
            wwn = String(format: "%04x%04x%04x%04x", word(108), word(109), word(110), word(111))
        } else {
            wwn = nil
        }

        // Word 83 bit 10: 48-bit addressing, capacity in words 100-103. Otherwise words 60-61.
        if word(83) & 0x0400 != 0 {
            sectors = (100...103).reversed().reduce(UInt64(0)) { $0 << 16 | UInt64(word($1)) }
        } else {
            sectors = UInt64(word(61)) << 16 | UInt64(word(60))
        }

        // Word 106: bit 14 set and bit 15 clear means the word is valid. Bit 12: the logical
        // sector is not 512 bytes (size in words 117-118, counted in 16-bit words). Bit 13:
        // several logical sectors per physical one (2^n, n in bits 3:0).
        let sizes = word(106)
        var logical = 512
        var physical = 512
        if sizes & 0xC000 == 0x4000 {
            if sizes & 0x1000 != 0 {
                logical = Int(UInt32(word(118)) << 16 | UInt32(word(117))) * 2
            }
            physical = sizes & 0x2000 != 0 ? logical << Int(sizes & 0x000F) : logical
        }
        logicalSectorSize = logical
        physicalSectorSize = physical

        switch word(217) {
        case 0x0001: rotation = "Solid State Device"
        case 0x0401...0xFFFE: rotation = "\(word(217)) rpm"
        default: rotation = "not reported"
        }

        smartSupported = word(82) & 0x0001 != 0
        smartEnabled = word(85) & 0x0001 != 0
    }

    var capacityBytes: UInt64 { sectors * UInt64(logicalSectorSize) }

    var capacityText: String {
        let bytes = capacityBytes
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = ","
        let grouped = formatter.string(from: NSNumber(value: bytes)) ?? String(bytes)
        let units: [(String, Double)] = [("TB", 1e12), ("GB", 1e9), ("MB", 1e6)]
        let (unit, scale) = units.first { Double(bytes) >= $0.1 } ?? ("bytes", 1)
        let short = scale == 1 ? "" : String(format: " [%.2f %@]", Double(bytes) / scale, unit)
        return grouped + " bytes" + short
    }
}

/// One row of the attribute table.
struct Attribute {
    let id: UInt8
    let flags: UInt16
    let value: UInt8
    let worst: UInt8
    let raw: [UInt8]            // 6 bytes, little-endian
    let threshold: UInt8?

    var raw48: UInt64 { raw.reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) } }
    private func rawWord(_ index: Int) -> UInt16 { UInt16(raw[index * 2]) | UInt16(raw[index * 2 + 1]) << 8 }

    var isPrefail: Bool { flags & 0x0001 != 0 }
    var updatedOnline: Bool { flags & 0x0002 != 0 }

    /// "FAILING_NOW", "In_the_past" or "-", as smartctl reports it. Threshold 0 never fails.
    var whenFailed: String {
        guard let threshold, threshold > 0 else { return "-" }
        if value <= threshold { return "FAILING_NOW" }
        if worst <= threshold { return "In_the_past" }
        return "-"
    }

    /// The raw value in the format smartctl uses by default for this attribute.
    var rawText: String {
        switch id {
        case 3:     // Spin-up time: current in word 0, average in word 1.
            return rawWord(1) == 0 ? "\(rawWord(0))" : "\(rawWord(0)) (Average \(rawWord(1)))"
        case 5, 196:    // Count in word 0; the upper words carry vendor extras.
            return rawWord(1) == 0 && rawWord(2) == 0 ? "\(rawWord(0))" : "\(rawWord(0)) (\(rawWord(2)) \(rawWord(1)))"
        case 9, 240:    // Hours in the low 24 bits.
            let hours = raw48 & 0xFFFFFF
            return raw[3] == 0 && raw[4] == 0 && raw[5] == 0 ? "\(hours)" : "\(hours) (\(raw[5]) \(raw[4]) \(raw[3]))"
        case 190, 194:  // Temperature in byte 0, often with min and max in bytes 2 and 4.
            let temperature = raw[0]
            if raw[1...5].allSatisfy({ $0 == 0 }) { return "\(temperature)" }
            if raw[1] == 0, raw[3] == 0, raw[5] == 0, raw[2] > 0, raw[4] >= raw[2] {
                return "\(temperature) (Min/Max \(raw[2])/\(raw[4]))"
            }
            return "\(temperature) (\(raw[1]) \(raw[2]) \(raw[3]) \(raw[4]) \(raw[5]))"
        default:
            return "\(raw48)"
        }
    }
}

/// SMART READ DATA joined with SMART READ THRESHOLDS.
struct SmartTable {
    let revision: UInt16
    let attributes: [Attribute]
    let dataChecksumValid: Bool
    let thresholdChecksumValid: Bool?

    init(data: [UInt8], thresholds: [UInt8]?) {
        revision = data.le16(0)
        var limits: [UInt8: UInt8] = [:]
        if let thresholds {
            for slot in 0..<30 {
                let offset = 2 + slot * 12
                if thresholds[offset] != 0 { limits[thresholds[offset]] = thresholds[offset + 1] }
            }
        }
        var rows: [Attribute] = []
        for slot in 0..<30 {
            let offset = 2 + slot * 12
            let id = data[offset]
            guard id != 0 else { continue }
            rows.append(Attribute(id: id,
                                  flags: data.le16(offset + 1),
                                  value: data[offset + 3],
                                  worst: data[offset + 4],
                                  raw: Array(data[(offset + 5)..<(offset + 11)]),
                                  threshold: limits[id]))
        }
        attributes = rows
        dataChecksumValid = SmartTable.checksumValid(data)
        thresholdChecksumValid = thresholds.map(SmartTable.checksumValid)
    }

    /// An ATA page is valid when its 512 bytes sum to zero modulo 256.
    static func checksumValid(_ page: [UInt8]) -> Bool {
        page.reduce(UInt8(0)) { $0 &+ $1 } == 0
    }
}

/// What the drive said to SMART RETURN STATUS.
enum Health {
    case passed
    case failed
    case unknown(String)

    /// The drive answers in the LBA registers, which the bridge returns as sense data:
    /// 4Fh/C2h means no threshold exceeded, F4h/2Ch means one has been.
    init(_ reply: Reply) {
        guard reply.sendResult == 0 || reply.senseValid else {
            self = .unknown(reply.failure)
            return
        }
        let sense = reply.sense
        var registers: (mid: UInt8, high: UInt8)?
        switch sense[0] & 0x7F {
        case 0x72, 0x73:    // Descriptor format: look for the ATA Status Return descriptor (09h).
            var offset = 8
            let end = min(sense.count, 8 + Int(sense[7]))
            while offset + 1 < end {
                let length = Int(sense[offset + 1]) + 2
                if sense[offset] == 0x09, offset + 12 <= sense.count {
                    registers = (sense[offset + 9], sense[offset + 11])
                    break
                }
                offset += length
            }
        case 0x70, 0x71:    // Fixed format: valid when ASC/ASCQ is 00h/1Dh (ATA pass-through information).
            if sense[12] == 0x00, sense[13] == 0x1D {
                registers = (sense[10], sense[11])
            }
        default:
            break
        }
        switch registers {
        case (0x4F, 0xC2)?: self = .passed
        case (0xF4, 0x2C)?: self = .failed
        case let other?:
            self = .unknown(String(format: "unexpected registers %02x/%02x", other.mid, other.high))
        case nil:
            self = .unknown(reply.senseValid ? "the bridge did not return the drive's registers (sense " + sense.prefix(22).hex + ")"
                                             : "the bridge returned no sense data")
        }
    }
}
