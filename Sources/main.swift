import SwiftUI
import RealityKit
import AppKit
import UniformTypeIdentifiers

@MainActor
final class RoomCaptureModel: ObservableObject {
    @Published var photoFolder: URL?
    @Published var outputURL: URL?
    @Published var status = "Choose a folder containing your room photographs."
    @Published var progress = 0.0
    @Published var isProcessing = false
    @Published var photoURLs: [URL] = []
    @Published var activityLog: [String] = ["Ready — choose a folder of photographs."]

    private var task: Task<Void, Never>?

    func addActivity(_ message: String) {
        let timestamp = Date.now.formatted(date: .omitted, time: .shortened)
        activityLog.append("\(timestamp)  \(message)")
        if activityLog.count > 100 {
            activityLog.removeFirst(activityLog.count - 100)
        }
    }

    func choosePhotos() {
        let panel = NSOpenPanel()
        panel.title = "Choose Room Photographs"
        panel.message = "Select the folder containing your room photographs."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            photoFolder = url
            photoURLs = ((try? FileManager.default.contentsOfDirectory(
                at: url,
                includingPropertiesForKeys: nil
            )) ?? [])
            .filter {
                ["jpg", "jpeg", "heic", "png", "tif", "tiff"]
                    .contains($0.pathExtension.lowercased())
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

            status = "Selected: \(url.lastPathComponent)"
            addActivity("Selected photo folder: \(url.lastPathComponent)")
            addActivity("Found \(photoURLs.count) photographs.")
        }
    }

    func createModel() {
        guard let photoFolder else {
            status = "Please choose a photo folder first."
            return
        }

        guard PhotogrammetrySession.isSupported else {
            status = "Object Capture is not supported on this Mac."
            return
        }

        task?.cancel()
        task = Task {
            await reconstruct(from: photoFolder)
        }
    }

    private func reconstruct(from folder: URL) async {
        isProcessing = true
        progress = 0
        status = "Preparing photographs..."
        addActivity("Preparing photographs for reconstruction.")

        defer { isProcessing = false }

        let accessGranted = folder.startAccessingSecurityScopedResource()
        defer {
            if accessGranted {
                folder.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let fileManager = FileManager.default
            let photos = try fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: nil
            ).filter {
                ["jpg", "jpeg", "heic", "png", "tif", "tiff"]
                    .contains($0.pathExtension.lowercased())
            }

            guard photos.count >= 3 else {
                status = "Please select a folder with at least 3 photographs."
                return
            }

            let savePanel = NSSavePanel()
            savePanel.title = "Save 3D Room Model"
            savePanel.nameFieldStringValue = "RoomModel.usdz"
            savePanel.allowedContentTypes = [.usdz]
            savePanel.canCreateDirectories = true

            guard savePanel.runModal() == .OK,
                  let destination = savePanel.url else {
                status = "Export cancelled."
                return
            }

            status = "Reconstructing \(photos.count) photographs..."
            addActivity("Starting 3D reconstruction with \(photos.count) photographs.")

            var configuration = PhotogrammetrySession.Configuration()
            configuration.sampleOrdering = .sequential
            configuration.featureSensitivity = .high

            let session = try PhotogrammetrySession(
                input: folder,
                configuration: configuration
            )

            let request = PhotogrammetrySession.Request.modelFile(
                url: destination,
                detail: .reduced
            )

            try session.process(requests: [request])

            for try await event in session.outputs {
                if Task.isCancelled {
                    session.cancel()
                    status = "Reconstruction cancelled."
                    return
                }

                switch event {
                case .requestProgress(_, let fraction):
                    let previousProgress = progress
                    progress = fraction
                    status = "Reconstructing: \(Int(fraction * 100))%"

                    if Int(fraction * 10) > Int(previousProgress * 10) {
                        addActivity("Reconstruction progress: \(Int(fraction * 100))%.")
                    }

                case .requestComplete(_, _):
                    outputURL = destination
                    progress = 1
                    status = "3D model saved successfully!"
                    addActivity("3D model created successfully.")

                case .requestError(_, let error):
                    status = "Reconstruction failed: \(error.localizedDescription)"
                    addActivity("Reconstruction failed: \(error.localizedDescription)")

                case .processingComplete:
                    if fileManager.fileExists(atPath: destination.path) {
                        outputURL = destination
                        progress = 1
                        status = "Finished! Your 3D model is ready."
                        addActivity("Finished! Your USDZ model is ready.")
                    }

                case .processingCancelled:
                    status = "Reconstruction cancelled."

                case .inputComplete:
                    break

                case .requestProgressInfo(_, _):
                    break

                case .invalidSample(_, let reason):
                    print("Invalid photograph: \(reason)")

                case .skippedSample(_):
                    break

                case .automaticDownsampling:
                    status = "Optimizing photographs for your Mac..."
                    addActivity("Optimizing photographs for your Mac.")

                case .stitchingIncomplete:
                    status = "Warning: reconstruction may be incomplete."

                @unknown default:
                    break
                }
            }
        } catch {
            status = "Error: \(error.localizedDescription)"
        }
    }

    func openModel() {
        guard let outputURL else { return }
        NSWorkspace.shared.open(outputURL)
    }

    func cancel() {
        task?.cancel()
    }
}

@main
struct RoomCaptureMacApp: App {
    var body: some SwiftUI.Scene {
        WindowGroup {
            RoomCaptureView()
        }
        .windowResizability(.contentSize)
    }
}

struct RoomCaptureView: View {
    @StateObject private var model = RoomCaptureModel()

    private var statusSymbol: String {
        if model.isProcessing {
            return "gearshape.2"
        }
        if model.outputURL != nil {
            return "checkmark.circle.fill"
        }
        if model.status.lowercased().contains("error") ||
           model.status.lowercased().contains("failed") {
            return "exclamationmark.triangle.fill"
        }
        return "info.circle.fill"
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    introduction
                    photoSection
                    photoGallerySection
                    reconstructionSection
                    statusSection
                    activityLogSection
                    outputSection
                }
                .padding(28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }

            Divider()

            footer
        }
        .frame(minWidth: 680, idealWidth: 760,
               minHeight: 680, idealHeight: 760)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(
                        LinearGradient(
                            colors: [.blue, .indigo],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 52, height: 52)

                Image(systemName: "cube.transparent")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Room Capture")
                    .font(.title2.bold())

                Text("Photographs to 3D models")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isProcessing {
                ProgressView()
                    .controlSize(.regular)
                    .help("Reconstruction is running")
            }
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Create a 3D model")
                .font(.system(size: 27, weight: .bold, design: .rounded))

            Text("Choose photographs of an object or room. Room Capture will use Apple's Object Capture technology to reconstruct a 3D model.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var photoSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                number: "1",
                title: "Choose photographs",
                subtitle: "Select a folder containing your images."
            )

            HStack(spacing: 13) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 25))
                    .foregroundStyle(.blue)
                    .frame(width: 46, height: 46)
                    .background(.blue.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 4) {
                    Text(model.photoFolder?.lastPathComponent ?? "No folder selected")
                        .font(.headline)
                        .lineLimit(1)

                    Text(model.photoFolder?.path ?? "Choose a folder containing at least 3 photographs.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 4)

                Button("Choose Folder…") {
                    model.choosePhotos()
                }
                .disabled(model.isProcessing)
            }
            .padding(16)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(.quaternary, lineWidth: 1)
            }
        }
    }

    private var photoGallerySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Photographs")
                    .font(.headline)
                Spacer()
                Text("\(model.photoURLs.count) images")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.photoURLs.isEmpty {
                Label("Choose a folder to preview its photographs.", systemImage: "photo.on.rectangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(model.photoURLs, id: \.self) { url in
                            VStack(alignment: .leading, spacing: 5) {
                                if let image = NSImage(contentsOf: url) {
                                    Image(nsImage: image)
                                        .resizable()
                                        .scaledToFill()
                                        .frame(width: 112, height: 82)
                                        .clipped()
                                        .clipShape(RoundedRectangle(cornerRadius: 9))
                                } else {
                                    RoundedRectangle(cornerRadius: 9)
                                        .fill(.quaternary)
                                        .frame(width: 112, height: 82)
                                        .overlay {
                                            Image(systemName: "photo")
                                                .font(.title2)
                                        }
                                }

                                Text(url.lastPathComponent)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .frame(width: 112, alignment: .leading)
                            }
                        }
                    }
                    .padding(.vertical, 3)
                }
                .scrollIndicators(.visible)
            }
        }
    }

    private var reconstructionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            sectionHeading(
                number: "2",
                title: "Reconstruct your model",
                subtitle: "Turn your photographs into a 3D object."
            )

            Button {
                model.createModel()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 18, weight: .semibold))

                    Text(model.isProcessing ? "Reconstructing…" : "Create 3D Model")
                        .font(.headline)

                    Spacer()

                    Image(systemName: "arrow.right")
                        .font(.headline)
                }
                .padding(.horizontal, 18)
                .frame(height: 54)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isProcessing)

            if model.isProcessing {
                Button(role: .cancel) {
                    model.cancel()
                } label: {
                    Label("Cancel Reconstruction", systemImage: "xmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.regular)
            }

            if model.isProcessing || model.progress > 0 {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Reconstruction progress")
                            .font(.subheadline.weight(.medium))

                        Spacer()

                        Text("\(Int(model.progress * 100))%")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }

                    ProgressView(value: model.progress)
                        .progressViewStyle(.linear)
                }
                .padding(15)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            }
        }
    }

    private var statusSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol)
                .font(.title3)
                .foregroundStyle(model.outputURL != nil ? .green : .secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 4) {
                Text("Activity")
                    .font(.subheadline.weight(.semibold))

                Text(model.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 12)
        )
    }

    private var activityLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Activity Log", systemImage: "text.alignleft")
                    .font(.headline)
                Spacer()
                Text("\(model.activityLog.count) events")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(model.activityLog.enumerated()), id: \.offset) { _, entry in
                        Text(entry)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(12)
            }
            .frame(height: 125)
            .background(
                Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: 10)
            )
        }
    }

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeading(
                number: "3",
                title: "Your 3D model",
                subtitle: "The finished model is saved as a USDZ file."
            )

            if let outputURL = model.outputURL {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 27))
                        .foregroundStyle(.green)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(outputURL.lastPathComponent)
                            .font(.headline)

                        Text(outputURL.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 4)

                    Button("Open Model") {
                        model.openModel()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(16)
                .background(
                    Color(nsColor: .controlBackgroundColor),
                    in: RoundedRectangle(cornerRadius: 12)
                )
            } else {
                Label("Your model will appear here when reconstruction finishes.", systemImage: "shippingbox")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 5)
            }
        }
    }

    private func sectionHeading(
        number: String,
        title: String,
        subtitle: String
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.subheadline.bold())
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(.blue.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)

                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 7) {
            Image(systemName: "apple.logo")
                .font(.caption)

            Text("Powered by Apple Object Capture")
                .font(.caption)

            Spacer()

            Text("USDZ Export")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(.quaternary, in: Capsule())
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 28)
        .padding(.vertical, 13)
    }
}
