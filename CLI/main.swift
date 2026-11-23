//
//  main.swift
//
//  usbsmart: SMART data for SATA drives in USB docks, read through the USBSmart driver.
//

import Foundation

let toolVersion = "0.5.0"

let usage = """
    usbsmart \(toolVersion): SMART data and self-tests for SATA drives in USB docks.
    Never writes to a drive's data.

    usage:
      usbsmart                         list the disks the driver is attached to
      usbsmart <disk>                  identity, health verdict and attribute table
      usbsmart --json                  read all connected supported drives into one JSON document
      usbsmart <disk> --smartctl [smartctl options]
                                       let smartctl decode the same pages with its drive
                                       database (default options: -a)
      usbsmart <disk> --raw            hex dump of the raw 512-byte pages
      usbsmart <disk> --save <dir>     write the raw pages to <dir> as .bin files
      usbsmart <disk> --replay         print the pages as `smartctl -r ataioctl,2` text,
                                       which `smartctl -a -` reads from standard input
      usbsmart --decode <dir> [...]    work from pages saved earlier instead of a drive
      usbsmart <disk> --debug          also show each command sent and the bridge's answer
      usbsmart <disk> --selftest short|long|conveyance|abort
                                       start (or stop) one of the drive's own background
                                       self-tests. The drive stays usable; a long test reads
                                       the whole surface and takes hours on a big disk
      usbsmart <disk> --selftest-status
                                       whether a test is running, and the drive's test log

    <disk> is a BSD name such as disk9 or /dev/disk9.

    exit status: 0 success, 1 error, 2 usage, 4 the drive reports failure (its own verdict,
    or an attribute at or below its threshold).
    """

func fail(_ message: String, status: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(status)
}

func note(_ message: String) {
    FileHandle.standardError.write(Data(("usbsmart: " + message + "\n").utf8))
}

// MARK: Capture

/// Everything read from one drive, or loaded from a directory written by --save.
struct Capture {
    var source: String
    var identify: [UInt8]
    var data: [UInt8]?
    var thresholds: [UInt8]?
    var health: Health
    var logs: [UInt8: [UInt8]] = [:]

    /// The logs `smartctl -a` asks for: directory, summary error log, self-test log,
    /// selective self-test log.
    static let logAddresses: [UInt8] = [0x00, 0x01, 0x06, 0x09]

    init(disk: SmartDisk, withLogs: Bool, debug: Bool) throws {
        source = disk.bsdName
        // With --debug, show each command as sent and how the bridge answered.
        func run(_ command: SmartCommand, argument: UInt32 = 0) throws -> Reply {
            let reply = try disk.run(command, argument: argument)
            if debug {
                note("\(command) cdb \(reply.cdb.hex) -> \(reply.succeeded ? "ok" : reply.failure), "
                     + "\(reply.realizedBytes) bytes, sense \(reply.senseValid ? "valid" : "not valid") \(reply.sense.prefix(22).hex)")
            }
            return reply
        }
        let identifyReply = try run(.identify)
        guard identifyReply.succeeded, identifyReply.realizedBytes == 512 else {
            let reason = identifyReply.succeeded ? "The bridge returned an incomplete page." : identifyReply.failure
            throw DriveReport.ReadError("\(disk.bsdName): IDENTIFY DEVICE failed: \(reason)"
                + (identifyReply.refused || identifyReply.succeeded ? "" : "\nThe bridge may not support ATA pass-through, or the drive is not answering."))
        }
        identify = identifyReply.data

        func page(_ command: SmartCommand, label: String) -> [UInt8]? {
            do {
                let reply = try run(command)
                guard reply.succeeded, reply.realizedBytes == 512 else {
                    let reason = reply.succeeded ? "The bridge returned an incomplete page." : reply.failure
                    note("\(label) failed: \(reason)")
                    return nil
                }
                return reply.data
            } catch {
                note("\(label) failed: \(error)")
                return nil
            }
        }
        data = page(.readData, label: "SMART READ DATA")
        thresholds = page(.readThresholds, label: "SMART READ THRESHOLDS")
        do { health = Health(try run(.returnStatus)) }
        catch { health = .unknown(String(describing: error)) }

        if withLogs {
            for address in Capture.logAddresses {
                let reply = try run(.readLog, argument: UInt32(address))
                if reply.succeeded { logs[address] = reply.data }
            }
        }
    }

    init(directory: String) {
        func page(_ name: String) -> [UInt8]? {
            guard let contents = FileManager.default.contents(atPath: directory + "/" + name), contents.count == 512 else {
                return nil
            }
            return [UInt8](contents)
        }
        source = directory
        guard let identifyPage = page("identify.bin") else {
            fail("\(directory): no 512-byte identify.bin there.")
        }
        identify = identifyPage
        data = page("smart-data.bin")
        thresholds = page("smart-thresholds.bin")
        let verdict = (try? String(contentsOfFile: directory + "/health.txt", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        switch verdict {
        case "passed": health = .passed
        case "failed": health = .failed
        default: health = .unknown("no verdict was saved")
        }
        for address in Capture.logAddresses {
            if let log = page(String(format: "log-%02x.bin", address)) { logs[address] = log }
        }
    }

    func save(to directory: String) throws {
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        func write(_ name: String, _ bytes: [UInt8]) throws {
            try Data(bytes).write(to: URL(fileURLWithPath: directory + "/" + name))
        }
        try write("identify.bin", identify)
        if let data { try write("smart-data.bin", data) }
        if let thresholds { try write("smart-thresholds.bin", thresholds) }
        for (address, log) in logs { try write(String(format: "log-%02x.bin", address), log) }
        switch health {
        case .passed: try write("health.txt", Array("passed\n".utf8))
        case .failed: try write("health.txt", Array("failed\n".utf8))
        case .unknown: break
        }
    }

    var report: DriveReport {
        DriveReport(identify: identify, data: data, thresholds: thresholds, health: health,
                    selfTestLog: logs[0x06], errorLog: logs[0x01])
    }
}

// MARK: Output

func hexDump(_ page: [UInt8]) -> String {
    stride(from: 0, to: page.count, by: 16).map { offset in
        String(format: "%03d-%03d: ", offset, offset + 15) + page[offset..<(offset + 16)].hex
    }.joined(separator: "\n")
}

func printReport(_ capture: Capture, report: DriveReport) {
    let identity = report.identity
    print("usbsmart \(toolVersion): \(capture.source)")
    print("")
    print("Device Model:     \(identity.model)")
    print("Serial Number:    \(identity.serial)")
    print("Firmware Version: \(identity.firmware)")
    if let wwn = identity.wwn { print("LU WWN Device Id: \(wwn)") }
    print("User Capacity:    \(identity.capacityText)")
    if identity.logicalSectorSize == identity.physicalSectorSize {
        print("Sector Size:      \(identity.logicalSectorSize) bytes logical/physical")
    } else {
        print("Sector Sizes:     \(identity.logicalSectorSize) bytes logical, \(identity.physicalSectorSize) bytes physical")
    }
    print("Rotation Rate:    \(identity.rotation)")
    let support = identity.smartSupported ? "Available, " + (identity.smartEnabled ? "enabled" : "disabled") : "Unavailable"
    print("SMART support:    \(support)")
    print("")

    switch (report.verdict, report.health) {
    case (.passed, .passed):
        print("SMART overall-health self-assessment test result: PASSED")
    case (.failed, .failed):
        print("SMART overall-health self-assessment test result: FAILED!")
        print("The drive reports that a failure threshold has been exceeded. Back up its data now.")
    default:
        print("SMART overall-health: \(report.verdict.rawValue.uppercased()) (\(report.verdictDetail))")
    }
    print("")

    guard let table = report.table else {
        if identity.smartSupported && !identity.smartEnabled {
            print("SMART is switched off on this drive, so it returned no attributes. usbsmart is read-only and will not switch it on.")
        } else {
            print("The drive returned no SMART attribute page.")
        }
        return
    }

    if !table.dataChecksumValid { print("Warning: the attribute page's checksum is wrong; the values below may be corrupt.") }
    if table.thresholdChecksumValid == false { print("Warning: the threshold page's checksum is wrong.") }
    if capture.thresholds == nil { print("Warning: the threshold page could not be read; THRESH and WHEN_FAILED are blank.") }

    print("SMART Attributes Data Structure revision number: \(table.revision)")
    print("Vendor Specific SMART Attributes with Thresholds:")
    print("ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE")
    for attribute in table.attributes {
        let name = attributeNames[attribute.id] ?? "Unknown_Attribute"
        let threshold = attribute.threshold.map { String(format: "%03d", $0) } ?? "---"
        let line = String(format: "%3d ", attribute.id)
            + name.padding(toLength: 24, withPad: " ", startingAt: 0)
            + String(format: "0x%04x   %03d   %03d   ", attribute.flags, attribute.value, attribute.worst)
            + threshold + "    "
            + (attribute.isPrefail ? "Pre-fail" : "Old_age").padding(toLength: 10, withPad: " ", startingAt: 0)
            + (attribute.updatedOnline ? "Always" : "Offline").padding(toLength: 9, withPad: " ", startingAt: 0)
            + (attribute.whenFailed == "-" ? "    -" : attribute.whenFailed).padding(toLength: 12, withPad: " ", startingAt: 0)
            + attribute.rawText
        print(line)
    }

    let concerns = table.attributes.compactMap { attribute -> String? in
        guard let meaning = countersToWatch[attribute.id] else { return nil }
        // Count in the low 16 bits for 5, 188 and 196 (the rest is vendor data), whole value otherwise.
        let count = [5, 188, 196].contains(attribute.id) ? attribute.raw48 & 0xFFFF : attribute.raw48
        guard count > 0 else { return nil }
        let name = attributeNames[attribute.id] ?? "Unknown_Attribute"
        return String(format: "  %3d %@ = %llu: %@", attribute.id, name, count, meaning)
    }
    if !concerns.isEmpty {
        print("")
        print("Worth a look (these counters are zero on a healthy drive):")
        concerns.forEach { print($0) }
    }
}

/// The capture as `smartctl -r ataioctl,2` debug text, which smartctl accepts on standard
/// input in place of a device (`smartctl -a -`).
func replayText(_ capture: Capture) -> String {
    var lines: [String] = []
    func command(_ name: String, parameter: UInt8? = nil, returned: Int = 0, errno: Int32? = nil, data: [UInt8]? = nil) {
        let start = "REPORT-IOCTL: DeviceF=usbsmart Command=" + name
        lines.append(parameter.map { start + " InputParameter=\($0)" } ?? start)
        lines.append(start + " returned \(returned)" + (errno.map { " errno=\($0)" } ?? ""))
        if let data {
            lines.append("===== [\(name)] DATA START (BASE-16) =====")
            lines.append(hexDump(data))
            lines.append("===== [\(name)] DATA END (512 Bytes) =====")
        }
        lines.append("")
    }
    // In the order smartctl asks for them, so its replay stays in step.
    command("IDENTIFY DEVICE", data: capture.identify)
    if let data = capture.data { command("SMART READ ATTRIBUTE VALUES", data: data) }
    if let thresholds = capture.thresholds { command("SMART READ ATTRIBUTE THRESHOLDS", data: thresholds) }
    switch capture.health {
    case .passed: command("SMART STATUS CHECK", returned: 0)
    case .failed: command("SMART STATUS CHECK", returned: 1)
    // No verdict from the bridge: report the command as failed, and smartctl falls back to
    // checking the attributes against their thresholds, saying so.
    case .unknown: command("SMART STATUS CHECK", returned: -1, errno: ENOSYS)
    }
    for address in capture.logs.keys.sorted() {
        command("SMART READ LOG", parameter: address, data: capture.logs[address])
    }
    return lines.joined(separator: "\n") + "\n"
}

func runSmartctl(_ capture: Capture, options: [String]) -> Int32 {
    let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        + ["/opt/homebrew/sbin", "/opt/homebrew/bin", "/usr/local/sbin", "/usr/local/bin"]
    guard let directory = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0 + "/smartctl") }) else {
        fail("smartctl was not found. Install it with: brew install smartmontools")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: directory + "/smartctl")
    process.arguments = (options.isEmpty ? ["-a"] : options) + ["-"]
    let input = Pipe()
    process.standardInput = input
    do {
        try process.run()
    } catch {
        fail("Could not start smartctl: \(error.localizedDescription)")
    }
    input.fileHandleForWriting.write(Data(replayText(capture).utf8))
    input.fileHandleForWriting.closeFile()
    process.waitUntilExit()
    return process.terminationStatus
}

// MARK: Self-tests

func printSelfTest(_ report: DriveReport) {
    guard let test = report.selfTest else {
        print("The drive returned no SMART data page, so its self-test state is unknown.")
        return
    }
    if !test.supported { print("The drive does not say it supports self-tests.") }
    if test.running {
        print("Self-test:        in progress, \(test.percentRemaining ?? 0)% remaining")
    } else {
        print("Self-test:        \(test.status)")
    }
    let times = [test.shortMinutes.map { "short \($0) min" }, test.longMinutes.map { "long \($0) min" }].compactMap { $0 }
    if !times.isEmpty { print("Expected time:    " + times.joined(separator: ", ")) }
    if let errors = test.ataErrorCount { print("ATA error count:  \(errors)") }
    print("")
    if test.log.isEmpty {
        print("The self-test log is empty or could not be read.")
        return
    }
    print("Num  Test         Result                                    Remaining  LifeTime(hours)  LBA_of_first_error")
    for (index, entry) in test.log.enumerated() {
        print(String(format: "#%2d  ", index + 1)
              + entry.type.padding(toLength: 13, withPad: " ", startingAt: 0)
              + entry.result.padding(toLength: 42, withPad: " ", startingAt: 0)
              + "\(entry.percentRemaining)%".padding(toLength: 11, withPad: " ", startingAt: 0)
              + "\(entry.lifetimeHours)".padding(toLength: 17, withPad: " ", startingAt: 0)
              + (entry.firstFailingLBA.map(String.init) ?? "-"))
    }
}

/// Starts or stops a background self-test. Returns the exit status.
func startSelfTest(_ disk: SmartDisk, _ kind: SelfTestKind, debug: Bool) -> Int32 {
    do {
        // Ask the drive first: a clear "not supported" beats a bridge error.
        let before = try disk.run(.readData)
        let info = before.succeeded && before.realizedBytes == 512
            ? SelfTestInfo(data: before.data, selfTestLog: nil, errorLog: nil) : nil
        if let info, kind != .abort {
            if !info.supported { fail("\(disk.bsdName): the drive does not say it supports self-tests.") }
            if kind == .conveyance && !info.conveyanceSupported {
                fail("\(disk.bsdName): the drive does not support the conveyance self-test.")
            }
            if info.running {
                fail("\(disk.bsdName): a self-test is already running (\(info.percentRemaining ?? 0)% remaining). "
                     + "Stop it with --selftest abort, or wait.")
            }
        }
        let reply = try disk.run(.selfTest, argument: UInt32(kind.rawValue))
        if debug {
            note("selfTest cdb \(reply.cdb.hex) -> \(reply.succeeded ? "ok" : reply.failure)")
        }
        guard reply.succeeded else {
            fail("\(disk.bsdName): the self-test command was not accepted: \(reply.failure)\n"
                 + "The bridge may not pass this command, or the installed driver is older than 0.5.0 "
                 + "(update and reactivate it in /Applications/USBSmart.app).")
        }
        switch kind {
        case .abort:
            print("\(disk.bsdName): self-test stopped.")
        default:
            let minutes = kind == .short ? info?.shortMinutes : kind == .long ? info?.longMinutes : nil
            print("\(disk.bsdName): \(kind) self-test started in the background"
                  + (minutes.map { ", about \($0) minutes" } ?? "") + ".")
            print("Check on it with: usbsmart \(disk.bsdName) --selftest-status")
            print("Unplugging, sleeping or power-cycling the dock stops the test.")
        }
        return 0
    } catch let error as DriverError {
        if case .callFailed = error {
            fail("\(disk.bsdName): \(error)\nThe installed driver is older than 0.5.0 and has no self-test command. "
                 + "Update and reactivate it in /Applications/USBSmart.app.")
        }
        fail("\(error)")
    } catch {
        fail("\(error)")
    }
}

// MARK: Arguments

var arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage)
    exit(0)
}
if arguments.contains("--version") {
    print("usbsmart \(toolVersion)")
    exit(0)
}

/// Removes `flag` and the value after it from the arguments and returns the value.
func takeValue(_ flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag) else { return nil }
    guard index + 1 < arguments.count else { fail("\(flag) needs a value.\n\n" + usage, status: 2) }
    let value = arguments[index + 1]
    arguments.removeSubrange(index...(index + 1))
    return value
}

func takeFlag(_ flag: String) -> Bool {
    guard let index = arguments.firstIndex(of: flag) else { return false }
    arguments.remove(at: index)
    return true
}

// Everything after --smartctl belongs to smartctl.
var smartctlOptions: [String]?
if let index = arguments.firstIndex(of: "--smartctl") {
    smartctlOptions = Array(arguments[(index + 1)...])
    arguments.removeSubrange(index...)
}
let decodeDirectory = takeValue("--decode")
let saveDirectory = takeValue("--save")
let wantRaw = takeFlag("--raw")
let wantReplay = takeFlag("--replay")
let wantDebug = takeFlag("--debug")
let wantJSON = takeFlag("--json")
let selfTestName = takeValue("--selftest")
let wantSelfTestStatus = takeFlag("--selftest-status")

if let unknown = arguments.first(where: { $0.hasPrefix("-") }) {
    fail("Unknown option \(unknown).\n\n" + usage, status: 2)
}
guard arguments.count <= 1 else { fail(usage, status: 2) }

if wantJSON {
    guard arguments.isEmpty, decodeDirectory == nil, saveDirectory == nil,
          smartctlOptions == nil, !wantRaw, !wantReplay, !wantDebug,
          selfTestName == nil, !wantSelfTestStatus else {
        fail("--json is a standalone scan of all connected supported drives.\n\n" + usage, status: 2)
    }
    let scan = DriveScan.readConnected()
    do {
        FileHandle.standardOutput.write(try scan.json())
        print()
    } catch {
        fail("Could not encode the scan. \(error)")
    }
    exit(scan.exitStatus)
}

let capture: Capture
if let decodeDirectory {
    guard arguments.isEmpty else { fail("--decode takes the place of a disk name.\n\n" + usage, status: 2) }
    guard selfTestName == nil else { fail("--selftest needs a real disk.\n\n" + usage, status: 2) }
    capture = Capture(directory: decodeDirectory)
} else if let name = arguments.first {
    do {
        let disk = try SmartDisk.find(name)
        if let selfTestName {
            guard let kind = SelfTestKind(name: selfTestName) else {
                fail("--selftest takes short, long, conveyance or abort.\n\n" + usage, status: 2)
            }
            exit(startSelfTest(disk, kind, debug: wantDebug))
        }
        capture = try Capture(disk: disk, withLogs: smartctlOptions != nil || wantReplay || saveDirectory != nil || wantSelfTestStatus,
                              debug: wantDebug)
    } catch {
        fail("\(error)")
    }
} else {
    guard selfTestName == nil, !wantSelfTestStatus else { fail("Name the disk to test.\n\n" + usage, status: 2) }
    let disks = SmartDisk.all()
    if disks.isEmpty {
        print("The USBSmart driver is not attached to any disk.")
        print("Activate it in /Applications/USBSmart.app, then unplug and replug the dock.")
        exit(1)
    }
    for disk in disks {
        do {
            let reply = try disk.run(.identify)
            if reply.succeeded {
                let identity = Identity(reply.data)
                print("\(disk.bsdName)  \(identity.model)  \(identity.serial)  \(identity.capacityText)")
            } else {
                print("\(disk.bsdName)  (IDENTIFY DEVICE failed: \(reply.failure))")
            }
        } catch {
            print("\(disk.bsdName)  (\(error))")
        }
    }
    exit(0)
}

if let saveDirectory {
    do {
        try capture.save(to: saveDirectory)
        note("pages written to \(saveDirectory)")
    } catch {
        fail("Could not write to \(saveDirectory): \(error.localizedDescription)")
    }
}

let report = capture.report
if wantReplay {
    print(replayText(capture), terminator: "")
} else if wantRaw {
    print("IDENTIFY DEVICE\n" + hexDump(capture.identify))
    if let data = capture.data { print("\nSMART READ DATA\n" + hexDump(data)) }
    if let thresholds = capture.thresholds { print("\nSMART READ THRESHOLDS\n" + hexDump(thresholds)) }
} else if let smartctlOptions {
    exit(runSmartctl(capture, options: smartctlOptions))
} else if wantSelfTestStatus {
    print("usbsmart \(toolVersion): \(capture.source)  \(report.identity.model)")
    print("")
    printSelfTest(report)
    exit(report.selfTest?.lastFailed == true ? 4 : 0)
} else {
    printReport(capture, report: report)
}
exit(report.verdict == .failed ? 4 : 0)
