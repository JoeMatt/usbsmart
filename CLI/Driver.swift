//
//  Driver.swift
//
//  Finds the USBSmart driver for a disk and asks it for pages. The structures here mirror
//  Driver/USBSmartShared.h.
//

import Foundation
import IOKit

/// The driver's whole command set (USBSmartCommand in the driver). All read-only.
enum SmartCommand: UInt32 {
    case identify = 0
    case readData = 1
    case readThresholds = 2
    case returnStatus = 3
    case readLog = 4
}

/// USBSmartReply, decoded.
struct Reply {
    static let size = 592

    let sendResult: Int32
    let taskStatus: UInt32
    let serviceResponse: UInt32
    let realizedBytes: UInt64
    let senseValid: Bool
    let cdb: [UInt8]
    let sense: [UInt8]
    let refused: Bool
    let data: [UInt8]

    init?(_ bytes: [UInt8]) {
        guard bytes.count >= Reply.size, bytes.le32(0) == 1 else { return nil }
        sendResult = Int32(bitPattern: bytes.le32(4))
        taskStatus = bytes.le32(8)
        serviceResponse = bytes.le32(12)
        realizedBytes = UInt64(bytes.le32(16)) | UInt64(bytes.le32(20)) << 32
        senseValid = bytes[24] != 0
        cdb = Array(bytes[26..<42])
        sense = Array(bytes[42..<74])
        refused = bytes[74] != 0
        data = Array(bytes[80..<592])
    }

    /// kSCSIServiceResponse_TASK_COMPLETE with kSCSITaskStatus_GOOD.
    var succeeded: Bool { !refused && sendResult == 0 && serviceResponse == 2 && taskStatus == 0 }

    /// One line for error messages.
    var failure: String {
        if refused {
            return "the driver's read-only check refused the command (CDB " + cdb.hex + ")"
        }
        var text = String(format: "UserSendCDB 0x%08x, service response %u, task status %u",
                          UInt32(bitPattern: sendResult), serviceResponse, taskStatus)
        if senseValid {
            text += ", sense " + sense.prefix(22).hex
        }
        return text
    }
}

enum DriverError: Error, CustomStringConvertible {
    case noSuchDisk(String)
    case notAttached(String, String)
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case badReply

    var description: String {
        switch self {
        case .noSuchDisk(let name):
            return "\(name): no such disk."
        case .notAttached(let name, let stack):
            return """
                \(name): the USBSmart driver is not attached to this disk (\(stack)).
                Activate it in /Applications/USBSmart.app, then unplug and replug the dock. \
                Only bridges listed in the driver's Info.plist are matched.
                """
        case .openFailed(let code):
            return String(format: "Could not connect to the driver (0x%08x).", UInt32(bitPattern: code))
        case .callFailed(let code):
            return String(format: "The driver rejected the request (0x%08x).", UInt32(bitPattern: code))
        case .badReply:
            return "The driver's reply was not understood (version mismatch between usbsmart and the driver?)."
        }
    }
}

/// A disk the driver is attached to.
final class SmartDisk {
    let bsdName: String
    let service: io_service_t

    init(bsdName: String, service: io_service_t) {
        self.bsdName = bsdName
        self.service = service
    }

    deinit { IOObjectRelease(service) }

    var registryID: UInt64 {
        var id: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &id)
        return id
    }

    /// Walks up from the disk's IOMedia to the driver's service.
    static func find(_ name: String, physicalOnly: Bool = false) throws -> SmartDisk {
        let bsdName = name.hasPrefix("/dev/") ? String(name.dropFirst(5)) : name
        guard let matching = IOBSDNameMatching(kIOMainPortDefault, 0, bsdName) else {
            throw DriverError.noSuchDisk(bsdName)
        }
        let media = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard media != 0 else { throw DriverError.noSuchDisk(bsdName) }

        var entry = media
        var classes: [String] = []
        while true {
            let className = IOObjectCopyClass(entry)?.takeRetainedValue() as String? ?? "?"
            if isDriver(entry) {
                return SmartDisk(bsdName: bsdName, service: entry)
            }
            if className.contains("SCSI") || className.contains("USB") {
                classes.append(className)
            }
            var parent: io_registry_entry_t = 0
            let result = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            guard result == KERN_SUCCESS, parent != 0 else { break }
            // A synthesized APFS container can advertise Whole=true, but its ancestry
            // passes through other media before reaching the actual disk's driver.
            if physicalOnly, IOObjectConformsTo(parent, "IOMedia") != 0 {
                IOObjectRelease(parent)
                throw DriverError.notAttached(bsdName, "a logical media layer")
            }
            entry = parent
        }
        let stack = classes.isEmpty ? "not a SCSI or USB disk" : "its driver stack is " + classes.prefix(4).joined(separator: " ← ")
        throw DriverError.notAttached(bsdName, stack)
    }

    /// Every whole disk the driver is attached to.
    static func all() -> [SmartDisk] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMedia"), &iterator) == KERN_SUCCESS else {
            return []
        }
        defer { IOObjectRelease(iterator) }
        var names: [String] = []
        while case let media = IOIteratorNext(iterator), media != 0 {
            defer { IOObjectRelease(media) }
            guard let whole = property(media, "Whole") as? Bool, whole,
                  let name = property(media, "BSD Name") as? String else { continue }
            names.append(name)
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .compactMap { try? find($0, physicalOnly: true) }
    }

    private static func isDriver(_ entry: io_registry_entry_t) -> Bool {
        (property(entry, "IOUserClass") as? String) == "USBSmartDevice"
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    /// Sends one command and returns the driver's reply, whatever the drive answered.
    func run(_ command: SmartCommand, argument: UInt32 = 0) throws -> Reply {
        var connection: io_connect_t = 0
        let opened = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard opened == KERN_SUCCESS else { throw DriverError.openFailed(opened) }
        defer { IOServiceClose(connection) }

        var input = [UInt8](repeating: 0, count: 8)
        withUnsafeBytes(of: command.rawValue.littleEndian) { input.replaceSubrange(0..<4, with: $0) }
        withUnsafeBytes(of: argument.littleEndian) { input.replaceSubrange(4..<8, with: $0) }
        var output = [UInt8](repeating: 0, count: Reply.size)
        var outputSize = output.count
        let result = IOConnectCallStructMethod(connection, 0, input, input.count, &output, &outputSize)
        guard result == KERN_SUCCESS else { throw DriverError.callFailed(result) }
        guard outputSize >= Reply.size, let reply = Reply(output) else { throw DriverError.badReply }
        return reply
    }
}

extension Array where Element == UInt8 {
    func le16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func le32(_ offset: Int) -> UInt32 { UInt32(le16(offset)) | UInt32(le16(offset + 2)) << 16 }
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}

extension ArraySlice where Element == UInt8 {
    var hex: String { map { String(format: "%02x", $0) }.joined(separator: " ") }
}
