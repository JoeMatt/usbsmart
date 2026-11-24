import SwiftUI
import UniformTypeIdentifiers

struct DrivesView: View {
    @ObservedObject var model: DrivesModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showHistory = false
    @State private var showExport = false
    @State private var exportDocument: ScanExport?
    @State private var exportError: String?

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                Section(model.isSample ? "Sample drive" : "Supported drives") {
                    ForEach(model.drives) { drive in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "externaldrive.fill").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(drive.name).font(.headline)
                                Text(drive.report?.identity.capacityText ?? "Could not read drive")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                Text(drive.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 5).tag(drive.id)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 230, ideal: 275)
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Reads health data only", systemImage: "lock.shield")
                        .font(.caption).foregroundStyle(.secondary)
                    SettingsLink { Text("Driver setup…") }
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
            }
        } detail: {
            if let drive = model.drives.first(where: { $0.id == model.selectedID }) {
                if let report = drive.report {
                    let scans = drive.snapshot?.driveId.flatMap { model.history.drives[$0] } ?? []
                    ReportView(report: report, readAt: drive.readAt, isSample: model.isSample,
                               snapshot: drive.snapshot, scans: scans, historyError: model.historyError)
                } else {
                    ContentUnavailableView {
                        Label("Could not read this drive", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(drive.error ?? "The drive stopped responding.")
                        Text("Check the dock connection, then click Refresh.")
                    }
                }
            } else {
                ContentUnavailableView {
                    Label(model.isReading ? "Reading drives…" : "No supported drive connected",
                          systemImage: "externaldrive.badge.questionmark")
                } description: {
                    Text("Connect a SATA drive in a listed USB dock. Open Driver setup to see the bridge compatibility list.")
                    Text("For the first use, activate the driver and approve it in System Settings, then reconnect the dock.")
                } actions: {
                    SettingsLink { Text("Set up driver") }
                    Button("Refresh") { model.refresh() }.disabled(model.isReading || model.isSample)
                }.padding()
            }
        }
        .navigationTitle(model.isSample ? "USBSmart — Sample data" : "USBSmart")
        .toolbar {
            ToolbarItemGroup {
                if model.isReading { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .disabled(model.isReading || model.isSample).keyboardShortcut("r", modifiers: .command)
                Button { showHistory = true } label: { Label("Scan history", systemImage: "clock.arrow.circlepath") }
                    .disabled(model.isSample)
                Button { exportScan() } label: { Label("Export JSON", systemImage: "square.and.arrow.up") }
                    .disabled(model.lastRefresh == nil || model.isReading || model.isSample)
                SettingsLink { Label("Driver setup", systemImage: "gearshape") }
                Button { dismissWindow(id: driveMonitorWindowID) } label: {
                    Label("Close to Menu Bar", systemImage: "xmark")
                }
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .sheet(isPresented: $showHistory) {
            ScanHistoryView(history: model.history, selectedDriveId: selectedDriveId, error: model.historyError)
        }
        .fileExporter(isPresented: $showExport, document: exportDocument,
                      contentType: .json, defaultFilename: "USBSmart scan") { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Could not export the scan", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    private var selectedDriveId: String? {
        model.drives.first(where: { $0.id == model.selectedID })?.snapshot?.driveId
    }

    private func exportScan() {
        do {
            guard let data = try model.exportJSON() else { return }
            exportDocument = ScanExport(data: data)
            showExport = true
        } catch {
            exportError = error.localizedDescription
        }
    }
}

struct DriverSettingsView: View {
    @ObservedObject var extensionModel: ExtensionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up the driver").font(.title2.bold())
            Text("Keep USBSmart in Applications. Click Activate, then approve USBSmart under System Settings → General → Login Items & Extensions → Driver Extensions.")
            Text("Safely eject any mounted volumes before reconnecting the dock. Your Mac's security settings stay as they are.")
            HStack {
                Button("Activate driver") { extensionModel.activate() }
                Button("Deactivate driver") { extensionModel.deactivate() }
            }
            Text(extensionModel.status).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Text("Health scans read drive identity and SMART data.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Bridge compatibility").font(.headline)
            Text("Listed bridges use standard SAT commands. The VIA Labs VL715 and Sabrent JMS561 have been verified. The other matches are candidates. UAS operation is unverified.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(bridgeCatalog) { bridge in
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(bridge.name).font(.callout)
                                Text(bridge.status).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(bridge.id).font(.caption.monospaced())
                        }
                    }
                }
            }.frame(height: 190)
        }.padding(24).frame(width: 520)
    }
}

private struct ReportView: View {
    let report: DriveReport
    let readAt: Date
    let isSample: Bool
    let snapshot: DriveSnapshot?
    let scans: [DriveSnapshot]
    let historyError: String?

    private var color: Color {
        switch report.verdict { case .passed: return .green; case .failed: return .red; case .unknown: return .orange }
    }
    private var symbol: String {
        switch report.verdict { case .passed: return "checkmark.shield.fill"; case .failed: return "exclamationmark.shield.fill"; case .unknown: return "questionmark.circle.fill" }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if isSample { Label("Sample pages · no drive is being read", systemImage: "doc.text").foregroundStyle(.orange) }
                VStack(alignment: .leading, spacing: 6) {
                    Text(report.identity.model).font(.largeTitle.bold()).textSelection(.enabled)
                    Text(report.identity.capacityText).foregroundStyle(.secondary)
                }
                HStack(alignment: .top, spacing: 16) {
                    Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SMART health: \(report.verdict.rawValue)").font(.title2.bold())
                        Text(report.verdictDetail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 14))

                HStack(alignment: .top, spacing: 24) {
                    metric("Temperature", value: report.metric(194) ?? report.metric(190), suffix: " °C", firstOnly: true)
                    metric("Power-on hours", value: report.metric(9))
                    metric("Reallocated sectors", value: report.metric(5))
                    metric("Pending sectors", value: report.metric(197))
                }
                if !isSample {
                    GroupBox("Changed since last valid scan") {
                        currentChanges.frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if !report.issues.isEmpty {
                    GroupBox("Report incomplete") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.issues, id: \.self) { Text($0) }
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                if !report.concerns.isEmpty {
                    GroupBox("Worth a look") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(report.concerns, id: \.self) { Text($0) }
                            Text("These counters can record past problems. Attribute meanings and raw formats vary by drive model.")
                                .foregroundStyle(.secondary)
                        }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                    }
                }
                GroupBox("Drive information") {
                    Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 8) {
                        info("Serial number", report.identity.serial)
                        info("Firmware", report.identity.firmware)
                        info("Rotation", report.identity.rotation)
                        info("Sector sizes", "\(report.identity.logicalSectorSize) logical / \(report.identity.physicalSectorSize) physical bytes")
                        info("SMART", report.identity.smartSupported ? (report.identity.smartEnabled ? "Enabled" : "Disabled") : "Not supported")
                    }.font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                if let table = report.table {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("SMART attributes").font(.title3.bold())
                        Text("Revision \(table.revision) · Generic names and raw formats; vendors may use different meanings.")
                            .font(.caption).foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                                GridRow {
                                    ForEach(["ID", "Attribute", "Value", "Worst", "Threshold", "Raw value", "Status"], id: \.self) {
                                        Text($0).fontWeight(.semibold)
                                    }
                                }
                                Divider()
                                ForEach(Array(table.attributes.enumerated()), id: \.offset) { _, row in
                                    GridRow {
                                        Text(String(row.id))
                                        Text(attributeNames[row.id] ?? "Unknown attribute")
                                        Text(String(row.value))
                                        Text(String(row.worst))
                                        Text(row.threshold.map(String.init) ?? "—")
                                        Text(row.rawText)
                                        Text(row.whenFailed == "-" ? "—" : row.whenFailed)
                                            .foregroundStyle(row.whenFailed == "FAILING_NOW" ? .red : .secondary)
                                    }
                                }
                            }.font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding(12)
                        }.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
                Text("Read \(readAt.formatted(date: .abbreviated, time: .standard)). Refresh to read again.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var currentChanges: some View {
        if let historyError {
            Text(historyError).foregroundStyle(.secondary)
        } else if snapshot?.driveId == nil {
            Text("This drive did not provide a unique identity for history.").foregroundStyle(.secondary)
        } else if let snapshot, snapshot.attributes.isEmpty {
            Text("This scan has no valid SMART attributes to compare.").foregroundStyle(.secondary)
        } else if let snapshot, scans.first?.readAt == snapshot.readAt, let previous = scans.dropFirst().first {
            ScanChangesView(previous: previous, current: snapshot)
        } else {
            Text("First saved scan. Refresh or reconnect the drive to compare.").foregroundStyle(.secondary)
        }
    }

    private func metric(_ title: String, value: String?, suffix: String = "", firstOnly: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value.map { (firstOnly ? String($0.split(separator: " ").first ?? "") : $0) + suffix } ?? "Unavailable")
                .font(.headline).textSelection(.enabled)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private func info(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).textSelection(.enabled) }
    }
}
