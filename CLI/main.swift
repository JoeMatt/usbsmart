//
//  main.swift
//
//  usbsmart: SMART data for SATA drives in USB docks, read through the USBSmart driver.
//

import Foundation

let toolVersion = "0.2.0"

let usage = """
    usbsmart \(toolVersion): SMART data for SATA drives in USB docks. Read-only.

    usage:
      usbsmart                         list the disks the driver is attached to
      usbsmart <disk>                  identity, health verdict and attribute table
      usbsmart <disk> --smartctl [smartctl options]
                                       let smartctl decode the same pages with its drive
                                       database (default options: -a)
      usbsmart <disk> --raw            hex dump of the raw 512-byte pages
      usbsmart <disk> --save <dir>     write the raw pages to <dir> as .bin files
      usbsmart <disk> --replay         print the pages as `smartctl -r ataioctl,2` text,
                                       which `smartctl -a -` reads from standard input
      usbsmart --decode <dir> [...]    work from pages saved earlier instead of a drive
      usbsmart <disk> --debug          also show each command sent and the bridge's answer

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
        guard identifyReply.succeeded else {
            fail("\(disk.bsdName): IDENTIFY DEVICE failed: \(identifyReply.failure)"
                 + (identifyReply.refused ? "" : "\nThe bridge may not support ATA pass-through, or the drive is not answering."))
        }
        identify = identifyReply.data

        let dataReply = try run(.readData)
        if dataReply.succeeded {
            data = dataReply.data
        } else {
            note("SMART READ DATA failed: \(dataReply.failure)")
        }
        let thresholdReply = try run(.readThresholds)
        if thresholdReply.succeeded {
            thresholds = thresholdReply.data
        } else {
            note("SMART READ THRESHOLDS failed: \(thresholdReply.failure)")
        }
        health = Health(try run(.returnStatus))

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

    /// True when the drive's own verdict is failure or an attribute is at or below its threshold.
    var reportsFailure: Bool {
        if case .failed = health { return true }
        guard let data else { return false }
        return SmartTable(data: data, thresholds: thresholds).attributes.contains { $0.whenFailed == "FAILING_NOW" }
    }
}

// MARK: Output

func hexDump(_ page: [UInt8]) -> String {
    stride(from: 0, to: page.count, by: 16).map { offset in
        String(format: "%03d-%03d: ", offset, offset + 15) + page[offset..<(offset + 16)].hex
    }.joined(separator: "\n")
}

func printReport(_ capture: Capture) {
    let identity = Identity(capture.identify)
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

    guard let data = capture.data else {
        if identity.smartSupported && !identity.smartEnabled {
            print("SMART is switched off on this drive, so it returned no attributes. usbsmart is read-only and will not switch it on.")
        } else {
            print("The drive returned no SMART attribute page.")
        }
        return
    }
    let table = SmartTable(data: data, thresholds: capture.thresholds)

    switch capture.health {
    case .passed:
        print("SMART overall-health self-assessment test result: PASSED")
    case .failed:
        print("SMART overall-health self-assessment test result: FAILED!")
        print("The drive reports that a failure threshold has been exceeded. Back up its data now.")
    case .unknown(let reason):
        let failing = table.attributes.filter { $0.whenFailed == "FAILING_NOW" }
        let derived = capture.thresholds == nil ? "UNKNOWN" : (failing.isEmpty ? "PASSED" : "FAILED!")
        print("SMART overall-health: \(derived) (worked out from the attribute thresholds; the drive's own verdict was not available: \(reason))")
    }
    print("")

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

if let unknown = arguments.first(where: { $0.hasPrefix("-") }) {
    fail("Unknown option \(unknown).\n\n" + usage, status: 2)
}
guard arguments.count <= 1 else { fail(usage, status: 2) }

let capture: Capture
if let decodeDirectory {
    guard arguments.isEmpty else { fail("--decode takes the place of a disk name.\n\n" + usage, status: 2) }
    capture = Capture(directory: decodeDirectory)
} else if let name = arguments.first {
    do {
        let disk = try SmartDisk.find(name)
        capture = try Capture(disk: disk, withLogs: smartctlOptions != nil || wantReplay || saveDirectory != nil,
                              debug: wantDebug)
    } catch {
        fail("\(error)")
    }
} else {
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

if wantReplay {
    print(replayText(capture), terminator: "")
} else if wantRaw {
    print("IDENTIFY DEVICE\n" + hexDump(capture.identify))
    if let data = capture.data { print("\nSMART READ DATA\n" + hexDump(data)) }
    if let thresholds = capture.thresholds { print("\nSMART READ THRESHOLDS\n" + hexDump(thresholds)) }
} else if let smartctlOptions {
    exit(runSmartctl(capture, options: smartctlOptions))
} else {
    printReport(capture)
}
exit(capture.reportsFailure ? 4 : 0)
