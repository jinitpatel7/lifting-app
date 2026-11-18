import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UIKit

private let photoPrivacy = "Setline keeps device photo links. Your Photos sync settings separately control whether originals are stored in your personal iCloud library."

@MainActor
final class ProgressPhotoAccess: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var revision = 0

    override init() {
        super.init()
        PHPhotoLibrary.shared().register(self)
    }

    deinit { PHPhotoLibrary.shared().unregisterChangeObserver(self) }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in self?.reload() }
    }

    func reload() { revision += 1 }
}

struct ProgressPhotoCollection: View {
    let photos: [DevicePhotoReference]

    var body: some View {
        if photos.isEmpty { Text("No linked progress photos.").font(.caption).foregroundStyle(Palette.muted) }
        else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 105))], alignment: .leading, spacing: 8) {
                ForEach(photos) { photo in ProgressPhotoPreview(photo: photo, pixels: 420) }
            }
        }
    }
}

private struct ProgressPhotoPreview: View {
    let photo: DevicePhotoReference
    let pixels: CGFloat
    @EnvironmentObject private var access: ProgressPhotoAccess
    @Environment(\.scenePhase) private var scenePhase
    @State private var image: UIImage?
    @State private var message = "Loading photo"
    @State private var request: PHImageRequestID?
    @State private var token = UUID()

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Linked progress photo")
                    .privacySensitive()
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "photo").accessibilityHidden(true)
                    Text(message).font(.caption).multilineTextAlignment(.center)
                }.padding(7).foregroundStyle(Palette.muted)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 103, maxHeight: pixels > 500 ? 320 : 160)
        .background(Palette.soft, in: RoundedRectangle(cornerRadius: 8))
        .onAppear { load() }
        .onChange(of: photo.id) { load() }
        .onChange(of: access.revision) { load() }
        .onChange(of: scenePhase) {
            if scenePhase == .active { load() }
            else { cancel(); image = nil }
        }
        .onDisappear { cancel() }
    }

    private func cancel() {
        token = UUID()
        if let request { PHImageManager.default().cancelImageRequest(request) }
        request = nil
    }

    private func load() {
        cancel()
        image = nil
        guard photo.location.isValid else { message = "Photo link unavailable"; return }
        switch photo.location {
        case .appFile(let relativePath):
            if let base = try? TrainingFiles.applicationSupport().directory {
                image = UIImage(contentsOfFile: base.appendingPathComponent(relativePath).path)
            }
            message = "Linked file is missing or unavailable"
        case .photoLibrary(let identifier):
            loadAsset(identifier)
        }
    }

    private func loadAsset(_ identifier: String) {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        switch status {
        case .notDetermined: message = "Allow Photos access to preview"; return
        case .denied: message = "Photo access is off"; return
        case .restricted: message = "Photo access is restricted on this device"; return
        case .authorized, .limited: break
        @unknown default: message = "Photo access is unavailable"; return
        }
        guard let asset = PHAsset.fetchAssets(withLocalIdentifiers: [identifier], options: nil).firstObject else {
            message = status == .limited ? "Photo is missing or outside selected access" : "Photo was deleted or is unavailable"
            return
        }
        message = "Loading photo"
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        let generation = token
        request = PHImageManager.default().requestImage(for: asset, targetSize: CGSize(width: pixels, height: pixels),
            contentMode: .aspectFit, options: options) { bitmap, info in
            let cancelled = (info?[PHImageCancelledKey] as? Bool) == true
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
            let inCloud = (info?[PHImageResultIsInCloudKey] as? Bool) == true
            guard !cancelled, !degraded else { return }
            Task { @MainActor in
                guard token == generation else { return }
                image = bitmap
                message = inCloud ? "Original unavailable on this device. Open it in Photos to download it." : "Photo preview unavailable"
            }
        }
    }
}

private struct PhotoAccessControls: View {
    @EnvironmentObject private var access: ProgressPhotoAccess
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let includesLibraryLinks: Bool

    var body: some View {
        if includesLibraryLinks {
            switch authorization {
            case .notDetermined:
                Button("Allow photo previews") {
                    Task {
                        _ = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
                        access.reload()
                    }
                }.buttonStyle(.borderless)
            case .denied:
                Text("Photo access is off. Setline keeps your links while previews are unavailable.").font(.caption)
                Button("Open Settings") { openSettings() }.buttonStyle(.borderless)
            case .restricted:
                Text("Photo access is restricted by this device.").font(.caption)
            case .limited:
                Text("Previews are available for your selected photos.").font(.caption)
                LimitedPhotoPicker { access.reload() }.frame(height: 44)
            case .authorized:
                EmptyView()
            @unknown default:
                Text("Photo access is unavailable.").font(.caption)
            }
        }
    }

    private var authorization: PHAuthorizationStatus {
        _ = access.revision
        _ = scenePhase
        return PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

private struct LimitedPhotoPicker: UIViewControllerRepresentable {
    let changed: () -> Void

    func makeUIViewController(context: Context) -> Controller { Controller(changed: changed) }
    func updateUIViewController(_ controller: Controller, context: Context) { controller.changed = changed }

    final class Controller: UIViewController {
        var changed: () -> Void
        init(changed: @escaping () -> Void) {
            self.changed = changed
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { return nil }
        override func loadView() {
            let button = UIButton(type: .system)
            button.setTitle("Manage selected photos", for: .normal)
            button.contentHorizontalAlignment = .leading
            button.addTarget(self, action: #selector(manage), for: .touchUpInside)
            view = button
        }
        @objc private func manage() {
            PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: self) { [weak self] _ in
                Task { @MainActor in self?.changed() }
            }
        }
    }
}

struct ProgressPhotosSheet: View {
    let model: TrainingModel
    let day: WorkoutDate
    var sessionID: UUID? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @EnvironmentObject private var access: ProgressPhotoAccess
    @State private var picker = false
    @State private var selection: [PhotosPickerItem] = []
    @State private var camera = false
    @State private var busy = false
    @State private var notice: String?
    @State private var needsSettings = false
    @State private var pendingRemoval: DevicePhotoReference?

    private var links: [DevicePhotoReference] {
        model.records.progressPhotos(on: day).filter { photo in
            photo.subject == sessionID.map(PhotoSubject.session)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section(day.key) {
                    Button("Choose device photos") { picker = true }.disabled(busy)
                    Button("Take photo") { Task { await prepareCamera() } }.disabled(busy)
                    if let notice { Text(notice).font(.caption).foregroundStyle(Palette.muted) }
                    if let error = model.storageError { Text(error).font(.caption).foregroundStyle(Palette.red) }
                    PhotoAccessControls(includesLibraryLinks: links.contains(where: \.usesPhotoLibrary))
                    if !links.isEmpty {
                        ForEach(links) { photo in
                            VStack(alignment: .leading, spacing: 4) {
                                ProgressPhotoPreview(photo: photo, pixels: 540)
                                Button("Remove link", role: .destructive) { pendingRemoval = photo }
                                    .buttonStyle(.borderless)
                            }
                        }
                    } else { Text("No linked progress photos.").font(.caption) }
                }
                Section {
                    Text(photoPrivacy).font(.caption).foregroundStyle(Palette.muted)
                    Text("Photo content is excluded from Setline exports and sharing.").font(.caption).foregroundStyle(Palette.muted)
                    if needsSettings {
                        Button("Open device settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    }
                }
            }
            .navigationTitle("Progress photos")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .photosPicker(isPresented: $picker, selection: $selection, maxSelectionCount: 8, matching: .images,
                preferredItemEncoding: .current, photoLibrary: .shared())
            .onChange(of: selection) { linkSelection() }
            .fullScreenCover(isPresented: $camera) {
                ProgressPhotoCamera { picture in
                    camera = false
                    if let picture { Task { await saveCaptured(picture) } }
                }.ignoresSafeArea()
            }
            .confirmationDialog("Remove photo link?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } })) {
                Button("Remove link", role: .destructive) {
                    if let photo = pendingRemoval { _ = model.updateUserData { try $0.unlinkProgressPhoto(photo.id) } }
                }
            } message: { Text("The original stays in Photos.") }
        }
    }

    private func linkSelection() {
        guard !selection.isEmpty else { return }
        let identifiers = selection.compactMap(\.itemIdentifier)
        let missing = identifiers.count < selection.count
        selection = []
        needsSettings = false
        notice = missing ? "One or more items had no Photos reference. Save them to your Photos library and select them again." : nil
        if !identifiers.isEmpty { _ = model.updateUserData { try $0.linkProgressPhotos(identifiers, on: day, sessionID: sessionID) } }
        access.reload()
    }

    private func prepareCamera() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        notice = nil
        needsSettings = false
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else {
            notice = "The camera is unavailable. You can still choose an existing photo."; return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        else { allowed = status == .authorized }
        guard allowed else {
            notice = status == .restricted ? "Camera access is restricted on this device." : "Camera access is off. You can still choose an existing photo."
            needsSettings = status != .restricted
            return
        }
        let added = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let permission = added == .notDetermined ? await PHPhotoLibrary.requestAuthorization(for: .addOnly) : added
        guard permission == .authorized || permission == .limited else {
            notice = permission == .restricted ? "This device restricts additions to Photos." : "Allow Photos additions in Settings to save a new camera photo."
            needsSettings = permission != .restricted
            return
        }
        camera = true
    }

    private func saveCaptured(_ picture: UIImage) async {
        busy = true
        defer { busy = false }
        do {
            let identifier = try await saveToDevicePhotos(picture)
            if !model.updateUserData({ try $0.linkProgressPhotos([identifier], on: day, sessionID: sessionID) }) {
                notice = "The photo was saved in Photos. Choose it again to retry linking."
            }
            access.reload()
        } catch {
            notice = "The camera photo could not be saved to Photos."
        }
    }
}

private extension DevicePhotoReference {
    var usesPhotoLibrary: Bool {
        if case .photoLibrary = location { return true }
        return false
    }
}

private struct ProgressPhotoCamera: UIViewControllerRepresentable {
    let finished: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let controller = UIImagePickerController()
        if UIImagePickerController.isSourceTypeAvailable(.camera) { controller.sourceType = .camera }
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(finished: finished) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let finished: (UIImage?) -> Void
        init(finished: @escaping (UIImage?) -> Void) { self.finished = finished }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { finished(nil) }
        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            finished(info[.originalImage] as? UIImage)
        }
    }
}

private final class CreatedPhotoIdentifier: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ id: String?) { lock.lock(); defer { lock.unlock() }; value = id }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return value }
}

private func saveToDevicePhotos(_ image: UIImage) async throws -> String {
    let identifier = CreatedPhotoIdentifier()
    return try await withCheckedThrowingContinuation { continuation in
        PHPhotoLibrary.shared().performChanges({
            identifier.set(PHAssetChangeRequest.creationRequestForAsset(from: image).placeholderForCreatedAsset?.localIdentifier)
        }, completionHandler: { saved, error in
            if saved, let id = identifier.get() { continuation.resume(returning: id) }
            else { continuation.resume(throwing: error ?? TrainingDataError.invalidRecord("The photo could not be saved.")) }
        })
    }
}

struct ProgressPhotoComparisonSheet: View {
    let model: TrainingModel
    @Environment(\.dismiss) private var dismiss
    @State private var left: Date
    @State private var right: Date

    init(model: TrainingModel, selected: WorkoutDate) {
        self.model = model
        let dates = model.records.progressPhotoDates
        let newer = dates.contains(selected) ? selected : (dates.last ?? selected)
        _right = State(initialValue: newer.localPickerDate)
        _left = State(initialValue: (dates.last { $0 < newer } ?? dates.first { $0 != newer } ?? newer.offset(-7)).localPickerDate)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    DatePicker("First date", selection: $left, displayedComponents: .date)
                    DatePicker("Second date", selection: $right, displayedComponents: .date)
                    let a = WorkoutDate(left), b = WorkoutDate(right)
                    if a == b {
                        Text("Choose two different dates to compare.").font(.subheadline)
                    } else {
                        HStack(alignment: .top, spacing: 8) {
                            PhotoComparisonColumn(day: a, photos: model.records.progressPhotos(on: a)).id(a)
                            PhotoComparisonColumn(day: b, photos: model.records.progressPhotos(on: b)).id(b)
                        }
                        .frame(maxWidth: .infinity)
                        let links = model.records.progressPhotos(on: a) + model.records.progressPhotos(on: b)
                        PhotoAccessControls(includesLibraryLinks: links.contains(where: \.usesPhotoLibrary))
                    }
                    Text(photoPrivacy).font(.caption).foregroundStyle(Palette.muted)
                }.padding(14)
            }
            .navigationTitle("Compare progress photos")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

private struct PhotoComparisonColumn: View {
    let day: WorkoutDate
    let photos: [DevicePhotoReference]
    @State private var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.formatted(.dateTime.month(.abbreviated).day().year())).font(.subheadline.weight(.semibold))
            if let photo = photos.first(where: { $0.id == selection }) ?? photos.first {
                if photos.count > 1 {
                    Picker("Photo for \(day.key)", selection: Binding(get: { photo.id }, set: { selection = $0 })) {
                        ForEach(photos.indices, id: \.self) { index in
                            Text("Photo \(index + 1)").tag(photos[index].id)
                        }
                    }
                }
                ProgressPhotoPreview(photo: photo, pixels: 850)
            } else {
                Text("No linked photos").font(.caption).foregroundStyle(Palette.muted)
            }
        }.frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
