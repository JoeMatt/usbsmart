//
//  USBSmartApp.swift
//
//  The host app exists to install and remove the driver extension, which macOS only allows
//  from an app in /Applications. Reading drives is done with the `usbsmart` command inside the
//  app bundle (Contents/MacOS/usbsmart).
//
//  Launch arguments: `--activate` or `--deactivate` submit that request at launch, so the
//  driver can be installed from a terminal; the approval in System Settings is still the
//  user's.
//

import SwiftUI
import SystemExtensions

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

@main
struct USBSmartApp: App {
    @StateObject private var model = ExtensionModel()

    var body: some Scene {
        WindowGroup("USBSmart") {
            VStack(alignment: .leading, spacing: 14) {
                Text("USBSmart driver").font(.title2).bold()
                Text("Reads SMART health data from SATA drives in USB docks. Read-only: it never "
                     + "writes to a drive, starts a self-test or changes a setting.")
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Activate") { model.activate() }
                        .keyboardShortcut(.defaultAction)
                    Button("Deactivate") { model.deactivate() }
                }
                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                Text("Then, in Terminal:")
                Text(verbatim: "/Applications/USBSmart.app/Contents/MacOS/usbsmart disk9")
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
            }
            .padding(20)
            .frame(width: 460)
            .onAppear {
                let arguments = CommandLine.arguments
                if arguments.contains("--activate") {
                    model.activate()
                } else if arguments.contains("--deactivate") {
                    model.deactivate()
                }
            }
        }
        .windowResizability(.contentSize)
    }
}
