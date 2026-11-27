import SwiftUI
import UIKit
import FujiKit

struct CameraDiagnosticsView: View {
    let model: CameraModel
    @Environment(\.dismiss) private var dismiss

    private var pairing: CameraPairing { model.pairing }
    private var working: Bool { pairing.isWorking || model.busy }

    var body: some View {
        NavigationStack {
            Form {
                Section("Current stage") {
                    LabeledContent("Bluetooth", value: pairing.hasBluetoothLink ? "Connected" : "Not connected")
                    LabeledContent("PTP/IP", value: model.telemetry.state.rawValue.capitalized)
                    LabeledContent("Last AP state", value: pairing.lastAPState ?? "Not read")
                    LabeledContent("Last AP error", value: pairing.lastAPError ?? "Not read")
                    if let progress = pairing.progress { ProgressView(progress.rawValue) }
                    if let ssid = pairing.diagnosticSSID {
                        LabeledContent("Network", value: ssid).textSelection(.enabled)
                    }
                    if let password = pairing.diagnosticPassword {
                        Button("Copy Wi-Fi password") { UIPasteboard.general.string = password }
                    }
                    if let error = model.error {
                        Text(error).foregroundStyle(.red)
                    }
                }
                Section("PTP/IP telemetry") {
                    LabeledContent("Round trip", value: String(format: "%.1f ms", model.telemetry.lastRoundTripTime * 1000))
                    LabeledContent("Throughput", value: String(format: "%.2f MB/s", model.telemetry.bytesPerSecond / 1_000_000))
                    LabeledContent("Bytes received", value: model.telemetry.bytesIn.formatted())
                    LabeledContent("Bytes sent", value: model.telemetry.bytesOut.formatted())
                }
                Section("Manual steps") {
                    Button("Connect Bluetooth") { Task { await pairing.connectDiagnosticBluetooth() } }
                        .disabled(pairing.savedCamera == nil || pairing.hasBluetoothLink)
                    ForEach(CameraPairing.DiagnosticStep.allCases) { step in
                        Button(step.rawValue) { Task { await pairing.runDiagnostic(step) } }
                            .disabled(!pairing.supports(step))
                    }
                    Button("Open gallery on existing Wi-Fi") {
                        Task { await model.openGalleryOnExistingWiFi() }
                    }.disabled(model.device != nil)
                    Button("Disconnect Bluetooth", role: .destructive) { pairing.releaseBluetooth() }
                        .disabled(!pairing.hasBluetoothLink)
                }.disabled(working)
                Section("Connection log") {
                    let log = model.trace.lines.joined(separator: "\n")
                    Button("Copy connection log") { UIPasteboard.general.string = log }.disabled(log.isEmpty)
                    if log.isEmpty {
                        Text("No activity yet.").foregroundStyle(.secondary)
                    } else {
                        Text(log).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
            .navigationTitle("Camera diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}

struct CameraPairingView: View {
    @Bindable var pairing: CameraPairing
    let reconnecting: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            CenteredCameraLayout {
                VStack(spacing: 20) {
                    if let credentials = pairing.manualJoin {
                        manualJoin(credentials)
                    } else if let progress = pairing.progress {
                        ProgressView(progress.rawValue)
                        if progress == .pairing {
                            Text("Confirm matching codes if prompted.").foregroundStyle(.secondary)
                        } else if progress == .turningOnWiFi {
                            Text("Leave the camera on the shooting display and keep it awake.").foregroundStyle(.secondary)
                        }
                    } else if let guidance = pairing.bluetoothState.guidance {
                        Label(guidance, systemImage: "antenna.radiowaves.left.and.right.slash")
                            .foregroundStyle(.secondary)
                        if pairing.bluetoothState == .unauthorized {
                            Button("Open app settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                            }
                        }
                    } else if !reconnecting {
                        nearbyCameras
                    }
                    if let error = pairing.error {
                        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                        if reconnecting && pairing.manualJoin == nil {
                            CameraPrimaryButton { Task { await pairing.connectSaved() } } label: { Text("Try again") }
                                .disabled(pairing.isWorking)
                        }
                    }
                }
            }
            .navigationTitle(pairing.manualJoin == nil ? (reconnecting ? "Connect camera" : "Pair a camera") : "Join camera Wi-Fi")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }.disabled(pairing.progress != nil)
            } }
        }
        .tint(.teal)
        .interactiveDismissDisabled(pairing.progress != nil)
        .task {
            if reconnecting { await pairing.connectSaved() }
            else { pairing.scan() }
        }
        .task(id: pairing.manualJoin?.ssid) { await pairing.waitForCameraWiFi() }
        .onDisappear {
            pairing.stopScanning()
            pairing.dismissManualJoin()
        }
    }

    private var nearbyCameras: some View {
        VStack(spacing: 24) {
            VStack(spacing: 10) {
                Image(systemName: "camera")
                    .font(.largeTitle).foregroundStyle(.teal).accessibilityHidden(true)
                Text("On your camera").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Text("In MENU/OK → Network/USB Setting, turn Airplane Mode off and Bluetooth on.")
                Text("From the shooting display, press DISP/BACK → Bluetooth → PAIRING. Select your camera below when it shows SEARCHING.")
            }
            .foregroundStyle(.primary)
            VStack(spacing: 12) {
                Text("Nearby cameras").font(.headline).accessibilityAddTraits(.isHeader)
                ForEach(pairing.cameras) { camera in
                    CameraPrimaryButton { Task { await pairing.pair(camera) } } label: {
                        Label(camera.name, systemImage: "camera")
                    }
                }
                if pairing.cameras.isEmpty {
                    ProgressView("Looking for your camera…")
                    Text("Leave the camera’s pairing screen open. Make sure it isn’t connected to another phone.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .disabled(pairing.isWorking)
        }
    }

    @ViewBuilder private func manualJoin(_ credentials: WiFiCredentials) -> some View {
        Image(systemName: "wifi").font(.largeTitle).foregroundStyle(.teal).accessibilityHidden(true)
        Text("In Settings → Wi-Fi, join this network.").font(.headline)
        VStack(spacing: 4) {
            credential("Network", value: credentials.ssid, copyLabel: "Copy SSID")
            Divider()
            if let password = credentials.passphrase {
                credential("Password", value: password, copyLabel: "Copy password")
            } else {
                LabeledContent("Password", value: "None")
            }
        }
        .cameraCard()
        Text("If it’s not listed, tap Other… to enter the network name. Stay connected even if iOS says there’s no internet.")
            .font(.footnote).foregroundStyle(.secondary)
        VStack(spacing: 10) {
            Text("The gallery opens automatically when connected.")
                .font(.subheadline).foregroundStyle(.secondary)
            if let progress = pairing.progress {
                ProgressView(progress.rawValue)
            } else {
                CameraPrimaryButton { Task { await pairing.continueAfterManualJoin() } } label: {
                    Text(pairing.error == nil ? "I’ve joined" : "Try again")
                }
            }
        }
    }

    private func credential(_ title: String, value: String, copyLabel: String) -> some View {
        HStack {
            LabeledContent(title, value: value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
            Button { UIPasteboard.general.string = value } label: {
                Label(copyLabel, systemImage: "doc.on.doc")
                    .labelStyle(.iconOnly)
                    .frame(minWidth: 44, minHeight: 44)
            }.buttonStyle(.borderless)
        }
    }
}
