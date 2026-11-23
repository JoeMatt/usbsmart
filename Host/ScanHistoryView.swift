import SwiftUI
import UniformTypeIdentifiers

struct ScanExport: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ScanChangesView: View {
    let previous: DriveSnapshot
    let current: DriveSnapshot

    var body: some View {
        let changes = ScanChange.between(previous, current)
        VStack(alignment: .leading, spacing: 8) {
            Text("Compared with \(previous.readAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption).foregroundStyle(.secondary)
            if changes.isEmpty {
                Text("No reported changes.").foregroundStyle(.secondary)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        Text("Attribute").fontWeight(.semibold)
                        Text("Previous").fontWeight(.semibold)
                        Text("Current").fontWeight(.semibold)
                    }
                    Divider()
                    ForEach(changes) { change in
                        GridRow {
                            Text(change.name)
                            Text(change.before).foregroundStyle(.secondary)
                            Text(change.after)
                        }
                    }
                }.font(.callout).textSelection(.enabled)
            }
        }
    }
}

struct ScanHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    let history: ScanHistory
    let error: String?
    @State private var selected: String?

    init(history: ScanHistory, selectedDriveId: String?, error: String?) {
        self.history = history
        self.error = error
        let keys = Self.sortedKeys(in: history)
        _selected = State(initialValue: selectedDriveId.flatMap { keys.contains($0) ? $0 : nil } ?? keys.first)
    }

    private static func sortedKeys(in history: ScanHistory) -> [String] {
        history.drives.keys.sorted {
            let left = history.drives[$0]?.first?.readAt ?? .distantPast
            let right = history.drives[$1]?.first?.readAt ?? .distantPast
            return left == right ? $0 < $1 : left > right
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Scan history").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            Text("The last \(ScanHistory.scansPerDrive) valid scans per drive are kept on this Mac, including drives that are unplugged.")
                .foregroundStyle(.secondary)
            if let error { Text(error).foregroundStyle(.orange) }
            if history.drives.isEmpty {
                ContentUnavailableView("No saved scans", systemImage: "clock",
                                       description: Text("Read a drive with valid SMART attributes to start its history."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(Self.sortedKeys(in: history), id: \.self, selection: $selected) { id in
                        if let scans = history.drives[id], let latest = scans.first {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(latest.model).fontWeight(.semibold)
                                Text("\(scans.count) scans · \(String(id.prefix(8)))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }.padding(.vertical, 3).tag(id)
                        }
                    }.frame(width: 235)
                    Divider()
                    if let selected, let scans = history.drives[selected] {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(scans.indices, id: \.self) { index in
                                    let scan = scans[index]
                                    DisclosureGroup {
                                        if scans.indices.contains(index + 1) {
                                            ScanChangesView(previous: scans[index + 1], current: scan).padding(.top, 8)
                                        } else {
                                            Text("Oldest saved scan.").foregroundStyle(.secondary).padding(.top, 8)
                                        }
                                        if !scan.issues.isEmpty {
                                            Text(scan.issues.joined(separator: " ")).font(.caption)
                                                .foregroundStyle(.secondary).padding(.top, 4)
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(scan.readAt.formatted(date: .abbreviated, time: .standard))
                                            Text("SMART health: \(scan.verdict.capitalized)")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }.padding(10).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                                }
                            }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        }.id(selected)
                    } else {
                        ContentUnavailableView("Select a drive", systemImage: "externaldrive")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
        }.padding(20).frame(width: 830, height: 510)
    }
}
