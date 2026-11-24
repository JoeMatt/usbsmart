import AppKit
import SwiftUI

private enum MonitorStatus {
    case reading, waiting, empty, passed, attention, failed

    init(_ model: DrivesModel) {
        if model.drives.contains(where: { $0.report?.verdict == .failed }) { self = .failed }
        else if model.drives.contains(where: { $0.report?.verdict != .passed || $0.status == .partial }) { self = .attention }
        else if model.isReading { self = .reading }
        else if !model.drives.isEmpty { self = .passed }
        else if model.lastRefresh != nil { self = .empty }
        else { self = .waiting }
    }

    var title: String {
        switch self {
        case .reading: return "Reading SMART…"
        case .waiting: return "Waiting for first scan"
        case .empty: return "No supported drives"
        case .passed: return "SMART checks passed"
        case .attention: return "SMART status needs attention"
        case .failed: return "A drive reported a SMART failure"
        }
    }

    var symbol: String {
        switch self {
        case .reading: return "arrow.clockwise"
        case .waiting, .empty: return "externaldrive"
        case .passed: return "checkmark.shield"
        case .attention: return "exclamationmark.triangle"
        case .failed: return "xmark.octagon.fill"
        }
    }
}

struct DriveMonitorLabel: View {
    @ObservedObject var model: DrivesModel

    var body: some View {
        let status = MonitorStatus(model)
        Image(systemName: status.symbol)
            .accessibilityLabel("USBSmart: \(status.title)")
    }
}

struct DriveMonitorMenu: View {
    @ObservedObject var model: DrivesModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(model.isSample ? "USBSmart · Sample data" : MonitorStatus(model).title)

        ForEach(model.drives) { drive in
            Button {
                model.selectedID = drive.id
                showWindow()
            } label: {
                Text("\(drive.name) · \(verdict(for: drive))")
            }
        }

        Divider()
        if let readAt = model.lastRefresh {
            Text("Last scan: \(readAt.formatted(date: .omitted, time: .shortened))")
        }
        Button("Open USBSmart", action: showWindow)
        SettingsLink { Text("Settings…") }
        Button("Refresh SMART") { model.refresh() }
            .disabled(model.isReading || model.isSample)
        if !model.isSample {
            Toggle("Scan every 5 minutes", isOn: $model.automaticScans)
        }

        Divider()
        Button("Quit USBSmart") { NSApp.terminate(nil) }
    }

    private func verdict(for drive: DriveReading) -> String {
        guard let report = drive.report else { return "Read failed" }
        if report.verdict == .passed, drive.status == .partial { return "Passed (incomplete read)" }
        return report.verdict.rawValue
    }

    private func showWindow() {
        openWindow(id: driveMonitorWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}
