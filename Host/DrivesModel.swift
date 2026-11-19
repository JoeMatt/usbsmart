import Foundation
import DiskArbitration
import SwiftUI

struct DriveItem: Identifiable {
    let id: String
    let report: DriveReport?
    let error: String?
    let readAt: Date
    var name: String { report?.identity.model ?? id }
}

/// Reads run serially off the main thread. Disk Arbitration callbacks only schedule a scan;
/// they do not mount, unmount, repair or write to any disk.
final class DrivesModel: ObservableObject {
    @Published var drives: [DriveItem] = []
    @Published var selectedID: String?
    @Published var isReading = false
    @Published var isSample = false
    @Published var lastRefresh: Date?
    private let reader = DispatchQueue(label: "com.joemattiello.USBSmart.reader", qos: .userInitiated)
    private var session: DASession?
    private var pending: DispatchWorkItem?
    private var refreshAgain = false

    init() {
        if let index = CommandLine.arguments.firstIndex(of: "--report-folder"),
           CommandLine.arguments.indices.contains(index + 1) {
            isSample = true
            loadSample(CommandLine.arguments[index + 1])
            return
        }
        if let session = DASessionCreate(kCFAllocatorDefault) {
            self.session = session
            let context = Unmanaged.passUnretained(self).toOpaque()
            DARegisterDiskAppearedCallback(session, nil, { _, context in
                guard let context else { return }
                Unmanaged<DrivesModel>.fromOpaque(context).takeUnretainedValue().scheduleRefresh()
            }, context)
            DARegisterDiskDisappearedCallback(session, nil, { disk, context in
                guard let context else { return }
                let model = Unmanaged<DrivesModel>.fromOpaque(context).takeUnretainedValue()
                if let name = DADiskGetBSDName(disk) {
                    let id = String(cString: name)
                    model.drives.removeAll { $0.id == id }
                }
                model.scheduleRefresh()
            }, context)
            DASessionSetDispatchQueue(session, .main)
        }
        refresh()
    }

    deinit {
        pending?.cancel()
        if let session { DASessionSetDispatchQueue(session, nil) }
    }

    private func scheduleRefresh() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func refresh() {
        guard !isSample else { return }
        guard !isReading else { refreshAgain = true; return }
        isReading = true
        reader.async { [weak self] in
            let rows = SmartDisk.all().map { disk -> (item: DriveItem, registryID: UInt64) in
                do {
                    return (DriveItem(id: disk.bsdName, report: try DriveReport.read(disk), error: nil, readAt: Date()), disk.registryID)
                } catch {
                    return (DriveItem(id: disk.bsdName, report: nil, error: String(describing: error), readAt: Date()), disk.registryID)
                }
            }
            // Filter out removed or replaced registry services before publishing a completed
            // scan. A BSD name can be reused for a different drive after a disconnect.
            let present = Set(SmartDisk.all().map { $0.registryID })
            // The report list is read again on the next disk event; do not keep IOKit handles.
            DispatchQueue.main.async {
                guard let self else { return }
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.isReading = false
                    self.refresh()
                    return
                }
                self.drives = rows.filter { present.contains($0.registryID) }.map { $0.item }
                self.lastRefresh = Date()
                if !self.drives.contains(where: { $0.id == self.selectedID }) {
                    self.selectedID = self.drives.first?.id
                }
                self.isReading = false
            }
        }
    }

    private func loadSample(_ directory: String) {
        func page(_ name: String) -> [UInt8]? {
            guard let data = FileManager.default.contents(atPath: directory + "/" + name), data.count == 512 else { return nil }
            return Array(data)
        }
        guard let identify = page("identify.bin") else {
            drives = [DriveItem(id: "sample", report: nil, error: "No 512-byte identify.bin in the sample folder.", readAt: Date())]
            selectedID = "sample"
            return
        }
        let report = DriveReport(identify: identify, data: page("smart-data.bin"),
                                 thresholds: page("smart-thresholds.bin"), health: .unknown("Sample pages"))
        drives = [DriveItem(id: "sample", report: report, error: nil, readAt: Date())]
        selectedID = "sample"
        lastRefresh = Date()
    }
}
