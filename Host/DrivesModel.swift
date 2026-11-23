import Foundation
import DiskArbitration
import SwiftUI

/// Reads run serially off the main thread. Disk Arbitration callbacks only schedule a scan;
/// they do not mount, unmount, repair or write to any disk.
final class DrivesModel: ObservableObject {
    @Published var drives: [DriveReading] = []
    @Published var selectedID: String?
    @Published var isReading = false
    @Published var isSample = false
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var history = ScanHistory()
    @Published private(set) var historyError: String?
    private let historyURL = URL.applicationSupportDirectory
        .appendingPathComponent("com.joemattiello.USBSmart", isDirectory: true)
        .appendingPathComponent("history-v1.json")
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
        // Disk Arbitration replays existing disks on registration. Coalesce that replay with
        // startup so the first scan doesn't immediately become its own comparison baseline.
        scheduleRefresh()
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
        reader.async { [weak self, historyURL] in
            let scan = DriveScan.readConnected()
            var history = ScanHistory()
            var historyError: String?
            do {
                history = try ScanHistory.load(from: historyURL)
                if history.record(scan.readings) {
                    try history.save(to: historyURL)
                }
            } catch {
                historyError = "Scan history could not be saved or opened. \(error.localizedDescription)"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.history = history
                self.historyError = historyError
                if self.refreshAgain {
                    self.refreshAgain = false
                    self.isReading = false
                    self.refresh()
                    return
                }
                self.drives = scan.readings
                self.lastRefresh = scan.completedAt
                if !self.drives.contains(where: { $0.id == self.selectedID }) {
                    self.selectedID = self.drives.first?.id
                }
                self.isReading = false
            }
        }
    }

    func exportJSON() throws -> Data? {
        guard !isSample, !isReading, let lastRefresh else { return nil }
        return try DriveScan(readings: drives, completedAt: lastRefresh).json()
    }

    private func loadSample(_ directory: String) {
        func page(_ name: String) -> [UInt8]? {
            guard let data = FileManager.default.contents(atPath: directory + "/" + name), data.count == 512 else { return nil }
            return Array(data)
        }
        guard let identify = page("identify.bin") else {
            drives = [DriveReading(id: "sample", report: nil, error: "No 512-byte identify.bin in the sample folder.", readAt: Date())]
            selectedID = "sample"
            return
        }
        let report = DriveReport(identify: identify, data: page("smart-data.bin"),
                                 thresholds: page("smart-thresholds.bin"), health: .unknown("Sample pages"))
        drives = [DriveReading(id: "sample", report: report, error: nil, readAt: Date())]
        selectedID = "sample"
        lastRefresh = Date()
    }
}
