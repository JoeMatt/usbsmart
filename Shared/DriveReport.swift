import Foundation

/// A value snapshot. No IOKit handles escape the background reader.
struct DriveReport {
    let identity: Identity
    let table: SmartTable?
    let health: Health
    let warnings: [String]

    init(identify: [UInt8], data: [UInt8]?, thresholds: [UInt8]?, health: Health,
         warnings: [String] = []) {
        precondition(identify.count == 512)
        precondition(data == nil || data?.count == 512)
        precondition(thresholds == nil || thresholds?.count == 512)
        identity = Identity(identify)
        table = data.map { SmartTable(data: $0, thresholds: thresholds) }
        self.health = health
        self.warnings = warnings
    }

    static func read(_ disk: SmartDisk) throws -> DriveReport {
        let identify = try disk.run(.identify)
        guard identify.succeeded, identify.realizedBytes == 512 else {
            throw ReadError("Could not read the drive's identity. " +
                            (identify.succeeded ? "The bridge returned an incomplete page." : identify.failure))
        }
        var warnings: [String] = []
        func page(_ command: SmartCommand, label: String) -> [UInt8]? {
            do {
                let reply = try disk.run(command)
                guard reply.succeeded, reply.realizedBytes == 512 else {
                    warnings.append("\(label) could not be read. " +
                                    (reply.succeeded ? "The bridge returned an incomplete page." : reply.failure))
                    return nil
                }
                return reply.data
            } catch {
                warnings.append("\(label) could not be read. \(error)")
                return nil
            }
        }
        let data = page(.readData, label: "SMART attributes")
        let thresholds = page(.readThresholds, label: "Failure thresholds")
        let health: Health
        do { health = Health(try disk.run(.returnStatus)) }
        catch { health = .unknown(String(describing: error)) }
        return DriveReport(identify: identify.data, data: data, thresholds: thresholds,
                           health: health, warnings: warnings)
    }

    enum Verdict: String { case passed = "Passed", failed = "Failed", unknown = "Unknown" }

    var verdict: Verdict {
        if case .failed = health { return .failed }
        // Never infer a pass from corrupt pages, an empty table or absent thresholds.
        if let table, table.dataChecksumValid, table.thresholdChecksumValid == true,
           table.attributes.contains(where: { $0.whenFailed == "FAILING_NOW" }) { return .failed }
        guard let table, table.dataChecksumValid, !table.attributes.isEmpty else { return .unknown }
        if case .passed = health { return .passed }
        guard table.thresholdChecksumValid == true,
              table.attributes.contains(where: { ($0.threshold ?? 0) > 0 }),
              table.attributes.allSatisfy({ $0.threshold != nil }) else { return .unknown }
        return .passed
    }

    var verdictDetail: String {
        switch health {
        case .failed: return "The drive reports a failure. Copy important data to another drive."
        case .passed:
            return verdict == .failed ? "An attribute has reached its failure threshold. Copy important data to another drive."
                : "The drive returned a passing SMART status. SMART cannot predict every failure."
        case .unknown:
            switch verdict {
            case .passed: return "No attribute has reached its failure threshold. This verdict is calculated from the attributes; the bridge did not return the drive's own verdict."
            case .failed: return "An attribute has reached its failure threshold. Copy important data to another drive."
            case .unknown: return "There is not enough valid SMART data to judge this drive's health."
            }
        }
    }

    var issues: [String] {
        var result = warnings
        if let table {
            if !table.dataChecksumValid { result.append("The attribute page has an invalid checksum. Its values may be corrupt.") }
            if table.thresholdChecksumValid == false { result.append("The threshold page has an invalid checksum. Its values may be corrupt.") }
            if table.attributes.isEmpty { result.append("The drive returned an empty attribute table.") }
            if table.thresholdChecksumValid == nil { result.append("Failure thresholds are unavailable.") }
        } else {
            result.append(identity.smartSupported && !identity.smartEnabled
                          ? "SMART is switched off. USBSmart will not change the drive's settings."
                          : "No SMART attribute page was returned.")
        }
        return result
    }

    var concerns: [String] {
        guard let table, table.dataChecksumValid else { return [] }
        return table.attributes.compactMap { attribute in
            guard let meaning = countersToWatch[attribute.id] else { return nil }
            let count = [5, 188, 196].contains(attribute.id) ? attribute.raw48 & 0xFFFF : attribute.raw48
            guard count > 0 else { return nil }
            return "\(attributeNames[attribute.id] ?? "Attribute \(attribute.id)"): \(count) — \(meaning)"
        }
    }

    func metric(_ id: UInt8) -> String? {
        guard let table, table.dataChecksumValid else { return nil }
        return table.attributes.first(where: { $0.id == id })?.rawText
    }

    struct ReadError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}
