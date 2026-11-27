import SwiftUI
import UIKit

struct CameraPhotoThumbnail: View {
    let model: CameraModel
    let object: CameraObject
    let paused: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo").foregroundStyle(.secondary)
            }
        }
        .frame(width: 58, height: 48)
        .background(.quaternary)
        .clipShape(.rect(cornerRadius: 7))
        .accessibilityHidden(true)
        .task(id: [model.galleryRevision, paused ? 1 : 0]) {
            guard !paused else { return }
            let result = await model.thumbnail(for: object)
            if !Task.isCancelled { image = result }
        }
    }
}

struct CameraPhotoPreview: View {
    let model: CameraModel
    let objects: [CameraObject]
    @State private var current: UInt32
    @State private var loaded: UInt32?
    @State private var image: UIImage?
    @State private var failure: String?
    @State private var retry = 0
    @Environment(\.dismiss) private var dismiss

    init(model: CameraModel, objects: [CameraObject], initial: UInt32) {
        self.model = model
        self.objects = objects
        _current = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let index = objects.firstIndex(where: { $0.id == current }) {
                    let object = objects[index]
                    Group {
                        if loaded == object.id, let image {
                            ZoomableCameraImage(image: image, page: move)
                                .accessibilityLabel(object.info.filename)
                        } else {
                            Group {
                                if loaded == object.id, let failure {
                                    ContentUnavailableView {
                                        Label(failure, systemImage: "photo")
                                    } actions: {
                                        if !object.isRAW { Button("Retry") { retry += 1 } }
                                    }
                                } else {
                                    ProgressView("Loading preview…")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .gesture(DragGesture().onEnded { value in
                                let dx = value.translation.width
                                guard abs(dx) > max(40, abs(value.translation.height)) else { return }
                                move(dx < 0 ? 1 : -1)
                            })
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    VStack(spacing: 12) {
                        HStack(spacing: 12) {
                            Button { move(-1) } label: {
                                Label("Previous photo", systemImage: "chevron.backward").labelStyle(.iconOnly)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }.disabled(index == 0)
                            Text("\(index + 1) of \(objects.count)")
                                .font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                            Button { move(1) } label: {
                                Label("Next photo", systemImage: "chevron.forward").labelStyle(.iconOnly)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }.disabled(index + 1 == objects.count)
                        }
                        if model.completed.contains(object.id) {
                            Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            HStack(spacing: 16) {
                                Button(model.selected.contains(object.id) ? "Deselect" : "Select") {
                                    if model.selected.contains(object.id) { model.selected.remove(object.id) }
                                    else { model.selected.insert(object.id) }
                                }
                                .buttonStyle(.bordered)
                                Button("Save photo") { Task { await model.savePhoto(object) } }
                                    .buttonStyle(.borderedProminent)
                            }
                            .controlSize(.large)
                            .disabled(model.busy || model.authorizing)
                        }
                        if model.authorizing { ProgressView("Allow Photos access…") }
                        if let progress = model.fileProgress[object.id], model.busy {
                            ProgressView(value: progress)
                        }
                        if let error = model.error {
                            Text(error).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: cameraColumnWidth)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 12)
                }
            }
            .navigationTitle(objects.first { $0.id == current }?.info.filename ?? "Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task(id: [Int(current), retry]) {
                guard let object = objects.first(where: { $0.id == current }) else { return }
                loaded = nil
                image = nil
                failure = nil
                do {
                    let result = try await model.preview(for: object)
                    guard !Task.isCancelled else { return }
                    image = result
                    failure = object.isRAW ? "No RAW thumbnail available" : "Preview unavailable"
                } catch {
                    guard !Task.isCancelled else { return }
                    failure = "Couldn’t load preview"
                }
                loaded = object.id
            }
        }
    }

    private func move(_ offset: Int) {
        guard let index = objects.firstIndex(where: { $0.id == current }),
              objects.indices.contains(index + offset) else { return }
        current = objects[index + offset].id
    }
}

private struct ZoomableCameraImage: UIViewRepresentable {
    let image: UIImage
    let page: (Int) -> Void

    func makeUIView(context: Context) -> ZoomScrollView { ZoomScrollView() }

    func updateUIView(_ view: ZoomScrollView, context: Context) {
        view.page = page
        guard view.photo.image !== image else { return }
        view.setZoomScale(1, animated: false)
        view.photo.image = image
    }
}

private final class ZoomScrollView: UIScrollView, UIScrollViewDelegate {
    let photo = UIImageView()
    var page: ((Int) -> Void)?
    private var pageSwipes: [UISwipeGestureRecognizer] = []

    init() {
        super.init(frame: .zero)
        delegate = self
        minimumZoomScale = 1
        maximumZoomScale = 4
        panGestureRecognizer.isEnabled = false
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        photo.contentMode = .scaleAspectFit
        addSubview(photo)
        photo.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            photo.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            photo.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            photo.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor),
            photo.bottomAnchor.constraint(equalTo: contentLayoutGuide.bottomAnchor),
            photo.widthAnchor.constraint(equalTo: frameLayoutGuide.widthAnchor),
            photo.heightAnchor.constraint(equalTo: frameLayoutGuide.heightAnchor),
        ])
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(swipePage(_:)))
            swipe.direction = direction
            addGestureRecognizer(swipe)
            pageSwipes.append(swipe)
        }
    }

    required init?(coder: NSCoder) { nil }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { photo }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        let zoomed = zoomScale > minimumZoomScale
        panGestureRecognizer.isEnabled = zoomed
        for swipe in pageSwipes { swipe.isEnabled = !zoomed }
    }

    @objc private func swipePage(_ recognizer: UISwipeGestureRecognizer) {
        guard zoomScale <= minimumZoomScale else { return }
        page?(recognizer.direction == .left ? 1 : -1)
    }

    @objc private func toggleZoom(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale {
            setZoomScale(minimumZoomScale, animated: true)
        } else {
            let center = recognizer.location(in: photo)
            let size = CGSize(width: bounds.width / 2.5, height: bounds.height / 2.5)
            zoom(to: CGRect(x: center.x - size.width / 2, y: center.y - size.height / 2,
                            width: size.width, height: size.height), animated: true)
        }
    }
}
