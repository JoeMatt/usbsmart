import Foundation

private struct MetricSample {
    let value: String
    let labels: [(String, String)]

    init(_ value: some CustomStringConvertible, labels: [(String, String)] = []) {
        self.value = value.description
        self.labels = labels
    }

    private static func escape(_ label: String) -> String {
        label.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    func render(_ name: String) -> String {
        guard !labels.isEmpty else { return "\(name) \(value)" }
        let fields = labels.map { "\($0.0)=\"\(Self.escape($0.1))\"" }.joined(separator: ",")
        return "\(name){\(fields)} \(value)"
    }
}

extension DriveScan {
    /// Prometheus text exposition, also usable by the Node Exporter textfile collector.
    func prometheusMetrics() -> String {
        var lines: [String] = []
        func gauge(_ suffix: String, _ help: String, _ samples: [MetricSample]) {
            guard !samples.isEmpty else { return }
            let name = "usbsmart_\(suffix)"
            lines += ["# HELP \(name) \(help)", "# TYPE \(name) gauge"]
            lines += samples.map { $0.render(name) }
        }

        // Keep time series stable across disk renumbering. A BSD fallback is unique within
        // this scan only, and is explicitly separated from persistent drive identifiers.
        let drives = readings.map { reading in
            (reading: reading, labels: [("drive_id", reading.snapshot?.driveId ?? "bsd:\(reading.id)")])
        }

        gauge("scan_timestamp_seconds", "Unix time when the SMART scan completed.", [
            MetricSample(Int64(completedAt.timeIntervalSince1970))
        ])
        gauge("connected_drives", "Number of connected drives attached to the USBSmart driver.", [
            MetricSample(drives.count)
        ])
        gauge("drive_info", "Drive identity and current BSD disk name.", drives.map { reading, labels in
            MetricSample(1, labels: labels + [
                ("disk", reading.id),
                ("model", reading.snapshot?.model ?? ""),
                ("firmware", reading.snapshot?.firmware ?? "")
            ])
        })
        gauge("drive_read_status", "Status of the most recent read, one for the current state and zero otherwise.", drives.flatMap { reading, labels in
            DriveReading.Status.allCases.map { state in
                MetricSample(reading.status == state ? 1 : 0, labels: labels + [("state", state.rawValue)])
            }
        })
        gauge("drive_health", "SMART verdict, one for the current state and zero otherwise.", drives.flatMap { reading, labels in
            let verdict = reading.snapshot?.verdict ?? "unknown"
            return ["passed", "failed", "unknown"].map { state in
                MetricSample(verdict == state ? 1 : 0, labels: labels + [("state", state)])
            }
        })
        gauge("drive_capacity_bytes", "Drive capacity in bytes.", drives.compactMap { reading, labels in
            reading.snapshot.map { MetricSample($0.capacityBytes, labels: labels) }
        })
        gauge("drive_temperature_celsius", "Drive temperature in degrees Celsius from SMART attribute 194 or 190.", drives.compactMap { reading, labels in
            guard let attributes = reading.snapshot?.attributes,
                  let row = attributes.first(where: { $0.id == 194 }) ?? attributes.first(where: { $0.id == 190 })
            else { return nil }
            return MetricSample(row.rawValue & 0xff, labels: labels)
        })
        gauge("drive_power_on_seconds", "Estimated drive power-on time in seconds, assuming SMART attribute 9 is in hours.", drives.compactMap { reading, labels in
            guard let row = reading.snapshot?.attributes.first(where: { $0.id == 9 }) else { return nil }
            return MetricSample((row.rawValue & 0xff_ffff) * 3600, labels: labels)
        })

        let attributes = drives.flatMap { reading, labels in
            (reading.snapshot?.attributes ?? []).map { row in
                (row: row, labels: labels + [("attribute_id", String(row.id)), ("attribute_name", row.name)])
            }
        }
        gauge("attribute_raw_value", "Raw SMART attribute value. Encoding and units are vendor-specific.",
              attributes.map { MetricSample($0.row.rawValue, labels: $0.labels) })
        gauge("attribute_normalized_value", "Current normalized SMART attribute value.",
              attributes.map { MetricSample($0.row.value, labels: $0.labels) })
        gauge("attribute_worst", "Worst recorded normalized SMART attribute value.",
              attributes.map { MetricSample($0.row.worst, labels: $0.labels) })
        gauge("attribute_threshold", "Reported SMART failure threshold. Zero indicates no usable limit.",
              attributes.compactMap { row, labels in row.threshold.map { MetricSample($0, labels: labels) } })
        return lines.joined(separator: "\n") + "\n"
    }
}
