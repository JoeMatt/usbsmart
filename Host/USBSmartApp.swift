//
//  USBSmartApp.swift
//
//  The host app exists to install and remove the driver extension, which macOS only allows
//  from an app in /Applications. The app and the bundled `usbsmart` command share the drive reader and page decoders.
//
//  Launch arguments: `--activate` or `--deactivate` submit that request at launch, so the
//  driver can be installed from a terminal; the approval in System Settings is still the
//  user's.
//

import AppKit
import SwiftUI
import SystemExtensions

let driveMonitorWindowID = "drive-monitor"
let driverIdentifier = "com.joemattiello.USBSmart.driver"

final class ExtensionModel: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "Idle."

    func activate() {
        submit(OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier: driverIdentifier,
                                                          queue: .main), label: "Activating")
    }

    func deactivate() {
        submit(OSSystemExtensionRequest.deactivationRequest(forExtensionWithIdentifier: driverIdentifier,
                                                            queue: .main), label: "Deactivating")
    }

    private func submit(_ request: OSSystemExtensionRequest, label: String) {
        request.delegate = self
        report(label + "…")
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func report(_ text: String) {
        status = text
        // Also on stderr, for runs started from a terminal.
        FileHandle.standardError.write(Data(("USBSmart: " + text + "\n").utf8))
    }

    // MARK: OSSystemExtensionRequestDelegate

    func request(_ request: OSSystemExtensionRequest,
                 actionForReplacingExtension existing: OSSystemExtensionProperties,
                 withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        report("Replacing driver \(existing.bundleShortVersion) (\(existing.bundleVersion)) with "
               + "\(ext.bundleShortVersion) (\(ext.bundleVersion))…")
        return .replace
    }

    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        report("Waiting for approval: System Settings → General → Login Items & Extensions → "
               + "Driver Extensions → turn on USBSmart.")
    }

    func request(_ request: OSSystemExtensionRequest,
                 didFinishWithResult result: OSSystemExtensionRequest.Result) {
        switch result {
        case .completed:
            report("Done. Unplug and replug the dock so the driver attaches to its drive.")
        case .willCompleteAfterReboot:
            report("Will complete after a restart.")
        @unknown default:
            report("Finished with result \(result.rawValue).")
        }
    }

    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let nsError = error as NSError
        report("Failed: \(nsError.localizedDescription) (\(nsError.domain) \(nsError.code))")
    }
}

final class USBSmartAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct USBSmartApp: App {
    @NSApplicationDelegateAdaptor(USBSmartAppDelegate.self) private var appDelegate
    @StateObject private var model = ExtensionModel()
    @StateObject private var drives = DrivesModel()

    var body: some Scene {
        Window("USBSmart", id: driveMonitorWindowID) {
            DrivesView(extensionModel: model, model: drives)
                .onAppear {
                    if CommandLine.arguments.contains("--activate") { model.activate() }
                    else if CommandLine.arguments.contains("--deactivate") { model.deactivate() }
                }
        }
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra {
            DriveMonitorMenu(model: drives)
        } label: {
            DriveMonitorLabel(model: drives)
        }
        .menuBarExtraStyle(.menu)
    }
}
