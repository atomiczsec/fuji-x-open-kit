import SwiftUI
import FujiKit

@main
struct FujiXOpenApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var model = CameraModel()
    var body: some Scene {
        WindowGroup {
#if DEBUG && targetEnvironment(simulator) && !HOTSPOT_AUTOJOIN
            if ProcessInfo.processInfo.arguments.contains("-test-manual-camera-wifi")
                || ProcessInfo.processInfo.arguments.contains("-test-nearby-camera-churn") {
                ManualHandoffTestView()
            } else {
                content
            }
#else
            content
#endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.setBackgrounded(true)
            case .active: model.setBackgrounded(false)
            default: break
            }
        }
    }

    private var content: some View {
        ContentView(model: model)
            .task {
                let args = ProcessInfo.processInfo.arguments
                if let index = args.firstIndex(of: "-host"), args.indices.contains(index + 1) {
                    model.host = args[index + 1]
                }
            }
    }
}

struct ContentView: View {
    @Bindable var model: CameraModel
    @State private var showPairing = false
    @State private var reconnecting = false
    @State private var showManual = false
    @State private var showCameraDetails = false
    @State private var showDiagnostics = false
    @State private var previewObject: CameraObject?
    @AppStorage("cameraDiagnosticsEnabled") private var diagnosticsEnabled = false
    var body: some View {
        Group {
            if model.device == nil && model.restoringConnection {
                CenteredCameraLayout { ProgressView("Reconnecting to camera…") }
            } else if model.device == nil {
                NavigationStack { connectView }
            } else {
                NavigationStack { photos }
            }
        }
        .tint(.teal)
        .sheet(isPresented: $showPairing) {
            CameraPairingView(pairing: model.pairing, reconnecting: reconnecting)
        }
        .sheet(isPresented: $showDiagnostics) {
            CameraDiagnosticsView(model: model)
        }
        .sheet(isPresented: $showManual) {
            NavigationStack { manualConnection }
                .tint(.teal)
        }
        .sheet(isPresented: $showCameraDetails) {
            NavigationStack { cameraDetails }
                .tint(.teal)
        }
        .fullScreenCover(item: $previewObject) { object in
            CameraPhotoPreview(model: model, objects: model.visibleObjects, initial: object.id)
                .tint(.teal)
        }
        .onChange(of: model.device != nil) { _, connected in
            if connected {
                showPairing = false
                showManual = false
            } else {
                previewObject = nil
                showCameraDetails = false
            }
        }
    }

    private var errorSection: some View {
        Group {
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
            }
        }
    }

    private var connectView: some View {
        CenteredCameraLayout {
            VStack(spacing: 24) {
                VStack(spacing: 14) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 54, weight: .light))
                        .foregroundStyle(.teal)
                        .accessibilityHidden(true)
                    Text("Fuji Kit").font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
                }
                let camera = model.pairing.savedCamera
                CameraPrimaryButton {
                    reconnecting = camera != nil; showPairing = true
                } label: {
                    Label(camera.map { "Connect to \($0.name ?? "camera")" } ?? "Pair a camera",
                          systemImage: camera == nil ? "plus" : "camera.fill")
                }
                .disabled(model.busy)
                if model.busy { ProgressView("Connecting…") }
                errorSection
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Open gallery on camera Wi-Fi", systemImage: "wifi") {
                        Task { await model.openGalleryOnExistingWiFi() }
                    }
                    Button("Connect manually over Wi-Fi", systemImage: "network") { showManual = true }
                    if model.pairing.savedCamera != nil {
                        Button("Forget camera", systemImage: "trash", role: .destructive) {
                            Task { await model.pairing.forget() }
                        }
                    }
                    Section {
                        Toggle("Camera diagnostics", isOn: $diagnosticsEnabled)
                        if diagnosticsEnabled {
                            Button("Open diagnostics", systemImage: "stethoscope") { showDiagnostics = true }
                        }
                    }
                } label: {
                    Label("Connection options", systemImage: "ellipsis")
                }
                .disabled(model.busy)
            }
        }
    }

    private var manualConnection: some View {
        CenteredCameraLayout {
            VStack(spacing: 20) {
                Text("Join the camera’s Wi-Fi in Settings first.").font(.headline)
                VStack(spacing: 8) {
                    HStack {
                        Text("Host").accessibilityHidden(true)
                        TextField("Host", text: $model.host).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .keyboardType(.numbersAndPunctuation).accessibilityLabel("Camera host")
                            .multilineTextAlignment(.trailing)
                    }.frame(minHeight: 44)
                    Divider()
                    HStack {
                        Text("Port").accessibilityHidden(true)
                        TextField("Port", text: $model.port).keyboardType(.numberPad).accessibilityLabel("Camera port")
                            .multilineTextAlignment(.trailing)
                    }.frame(minHeight: 44)
                }
                .cameraCard()
                .disabled(model.busy)
                CameraPrimaryButton { Task { await model.find() } } label: {
                    Label("Find camera", systemImage: "magnifyingglass")
                }
                .disabled(model.busy)
                if model.busy { ProgressView(model.searching ? "Searching…" : "Connecting…") }
                if model.searched {
                    VStack(spacing: 12) {
                        Text("Cameras").font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(model.candidates, id: \.host) { camera in
                            Button("Connect to \(camera.host)", systemImage: "camera") {
                                Task { await model.connect(camera) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                        }
                        if model.candidates.isEmpty {
                            Text("No cameras found. Check Wi-Fi, host and port, then try again.").foregroundStyle(.secondary)
                        } else {
                            Text("Approve the connection on your camera if prompted.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.busy)
                }
                errorSection
            }
        }
        .navigationTitle("Connect over Wi-Fi")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { showManual = false }.disabled(model.busy) }
        }
        .interactiveDismissDisabled(model.busy)
    }

    private var cameraDetails: some View {
        CenteredCameraLayout {
            VStack(spacing: 24) {
                if let device = model.device {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.fill")
                            .font(.largeTitle).foregroundStyle(.teal).accessibilityHidden(true)
                        Text(device.model).font(.title2.bold()).accessibilityAddTraits(.isHeader)
                    }
                    if !device.serialNumber.isEmpty || model.battery != nil {
                        VStack(spacing: 14) {
                            if !device.serialNumber.isEmpty { LabeledContent("Serial", value: device.serialNumber) }
                            if let battery = model.battery {
                                LabeledContent { Text("\(battery)%") } label: { Label("Battery", systemImage: "battery.75percent") }
                            }
                        }
                        .cameraCard()
                    }
                }
                if !model.storages.isEmpty {
                    VStack(spacing: 16) {
                        Text("Storage").font(.headline).accessibilityAddTraits(.isHeader)
                        ForEach(model.storages) { storage in
                            VStack(spacing: 8) {
                                Text(storage.info.description).font(.subheadline.weight(.semibold))
                                ProgressView(value: Double(storage.info.freeSpace), total: Double(max(1, storage.info.capacity)))
                                Text("\(bytes(storage.info.freeSpace)) free of \(bytes(storage.info.capacity))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .cameraCard()
                }
            }
        }
        .navigationTitle("Camera details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Done") { showCameraDetails = false } }
        }
    }

    private var photos: some View {
        CenteredCameraLayout {
            LazyVStack(spacing: 16) {
                Picker("Format", selection: $model.filter) {
                    ForEach(CameraModel.Filter.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }.pickerStyle(.segmented)
                ForEach(model.visibleObjects) { object in
                    photoRow(object).cameraCard()
                }
                if model.objects.isEmpty && !model.busy && model.error == nil {
                    emptyGallery("No photos on this camera.")
                } else if !model.objects.isEmpty && model.visibleObjects.isEmpty {
                    emptyGallery("No \(model.filter.rawValue) photos.")
                }
                if model.authorizing {
                    ProgressView("Allow Photos access…")
                } else if model.busy && !model.loadingThumbnail {
                    if !model.fileProgress.isEmpty && model.transferSummary == nil {
                        ProgressView("Saving photos…", value: model.overallProgress)
                    } else {
                        ProgressView(model.objects.isEmpty ? "Loading photos…" : "Working…")
                    }
                }
                if let summary = model.transferSummary {
                    Label(summary, systemImage: model.error == nil ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(model.error == nil ? .green : .orange)
                }
                errorSection
            }
        }
        .safeAreaInset(edge: .bottom) {
            if !model.selected.isEmpty {
                CameraPrimaryButton { Task { await model.saveSelected() } } label: {
                    Label("Save to Photos (\(model.selected.count))", systemImage: "square.and.arrow.down")
                }
                .disabled(model.busy || model.authorizing)
                .frame(maxWidth: cameraColumnWidth)
                .padding(.horizontal, 24)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(.bar)
            }
        }
        .navigationTitle("Photos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.loadObjects() } }
                    .disabled(model.busy || model.authorizing)
                Menu {
                    Button("Camera details", systemImage: "camera") { showCameraDetails = true }
                    if diagnosticsEnabled {
                        Button("Open diagnostics", systemImage: "stethoscope") { showDiagnostics = true }
                    }
                    Button("Disconnect", systemImage: "wifi.slash", role: .destructive) {
                        Task { await model.disconnect() }
                    }.disabled(model.busy)
                } label: {
                    Label("Camera options", systemImage: "ellipsis")
                }
            }
        }
        .task { if model.objects.isEmpty { await model.loadObjects() } }
    }

    private func emptyGallery(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "photo.on.rectangle")
                .font(.largeTitle).foregroundStyle(.teal).accessibilityHidden(true)
            Text(message).font(.headline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 16)
    }

    private func photoRow(_ object: CameraObject) -> some View {
        let saved = model.completed.contains(object.id)
        let selected = model.selected.contains(object.id)
        return HStack(spacing: 8) {
            if !saved {
                Button {
                    if selected { model.selected.remove(object.id) }
                    else { model.selected.insert(object.id) }
                } label: {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(selected ? "Deselect \(object.info.filename)" : "Select \(object.info.filename)")
                .disabled((model.busy && !model.loadingThumbnail) || model.authorizing)
            }
            Button { previewObject = object } label: {
                photoRowLabel(object, saved: saved)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview \(object.info.filename)")
        }
    }

    private func photoRowLabel(_ object: CameraObject, saved: Bool) -> some View {
        HStack(spacing: 12) {
            CameraPhotoThumbnail(model: model, object: object, paused: previewObject != nil)
            VStack(alignment: .leading, spacing: 5) {
                Text(object.info.filename).foregroundStyle(.primary)
                Text(bytes(UInt64(object.info.size))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if saved { Label("Saved", systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.green) }
        }.multilineTextAlignment(.leading)
    }

    private func bytes(_ count: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: count), countStyle: .file)
    }
}
