import AppKit
import SwiftUI
import UniformTypeIdentifiers

private actor BlobVerificationCapture {
    private var result: BlobVerificationResult?

    func set(_ value: BlobVerificationResult) {
        result = value
    }

    func get() -> BlobVerificationResult? {
        result
    }
}

@MainActor
enum BlobSavePanelHelper {
    static func presentSavePanel(
        suggestedFilename: String,
        mimeType: String?
    ) async -> URL? {
        let panel = NSSavePanel()
        panel.title = "Download File"
        panel.nameFieldStringValue = suggestedFilename
        panel.canCreateDirectories = true
        if let ext = BlobPayloadService.fileExtension(forMIMEType: mimeType),
           let contentType = UTType(filenameExtension: ext) {
            panel.allowedContentTypes = [contentType]
        }

        return await withCheckedContinuation { continuation in
            if let window = NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow {
                panel.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            } else {
                panel.begin { response in
                    continuation.resume(returning: response == .OK ? panel.url : nil)
                }
            }
        }
    }
}

public struct BlobInspectorView: View {
    public let blob: BlobDescriptor
    public let references: [BlobReferenceOccurrence]
    public let onOpenRecord: ((RecordLocator) -> Void)?

    private let payloadService: BlobPayloadService
    @Environment(TransferQueue.self) private var transferQueue: TransferQueue?

    @State private var isLoadingPreview = false
    @State private var isDownloading = false
    @State private var previewResult: BlobPreviewResult?
    @State private var previewImage: NSImage?
    @State private var verifiedState: BlobVerificationState?
    @State private var verifiedByteCount: Int64?
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var copiedCID = false

    public init(
        blob: BlobDescriptor,
        references: [BlobReferenceOccurrence],
        payloadService: BlobPayloadService = BlobPayloadService(),
        onOpenRecord: ((RecordLocator) -> Void)? = nil
    ) {
        self.blob = blob
        self.references = references.sorted {
            ($0.record.uri, $0.jsonPointer) < ($1.record.uri, $1.jsonPointer)
        }
        self.payloadService = payloadService
        self.onOpenRecord = onOpenRecord
    }

    private var isPublicBlob: Bool {
        if case .publicRepository = blob.locator.scope {
            return true
        }
        return false
    }

    private var isActiveDownloadOnly: Bool {
        BlobPayloadService.isActiveDownloadOnlyFormat(mimeType: blob.mimeType)
    }

    private var effectiveVerification: BlobVerificationState {
        verifiedState ?? blob.verification
    }

    private var effectiveVerificationLabel: String {
        switch effectiveVerification {
        case .notVerified:
            "Not Verified"
        case .hashVerified:
            "Hash Verified"
        case .failed:
            "Verification Failed"
        }
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                fileHeader
                actionBar

                if isLoadingPreview || previewImage != nil || previewResult != nil || errorMessage != nil || statusMessage != nil {
                    previewSection
                }

                inspectorSection("Identity & Location") {
                    metadataRow("CID", blob.locator.cid, lines: 3)
                    metadataRow("Owner DID", blob.ownerDID, lines: 2)
                    metadataRow("Data Plane", blob.dataPlaneLabel, monospaced: false)
                    if case .publicRepository(_, let pdsURL) = blob.locator.scope {
                        metadataRow("PDS", pdsURL.absoluteString, lines: 3)
                    }
                }

                inspectorSection("Metadata") {
                    metadataRow("MIME Type", blob.displayMIMEType)
                    metadataRow("Declared Size", BlobTableItem(blob: blob).declaredSizeLabel, monospaced: false)
                    if let verifiedByteCount {
                        metadataRow(
                            "Verified Size",
                            ByteCountFormatter.string(fromByteCount: verifiedByteCount, countStyle: .file),
                            monospaced: false
                        )
                    }
                    metadataRow("Availability", availabilityLabel, monospaced: false)
                    metadataRow("Verification", effectiveVerificationLabel, monospaced: false)
                    if case .hashVerified(let sha256) = effectiveVerification {
                        metadataRow("SHA-256 Digest", sha256, lines: 3)
                        note("Downloaded bytes matched the CIDv1 SHA-256 digest.")
                    } else if case .failed(let reason) = effectiveVerification {
                        note("Verification failed: \(reason)")
                    } else {
                        note("Metadata is derived from public records. File bytes have not been downloaded or verified.")
                    }
                }

                inspectorSection("Access") {
                    metadataRow("Classification", isPublicBlob ? "Public" : blob.dataPlaneLabel, monospaced: false)
                    note(
                        isPublicBlob
                            ? "This file is listed by a public AT Protocol repository and fetched anonymously without credentials."
                            : "This file belongs to a permissioned Space and never falls back to anonymous public sync endpoints."
                    )
                }

                inspectorSection("Record References") {
                    note(referenceSummary)
                    if references.isEmpty {
                        note(blob.referenceIndexComplete
                            ? "No references found."
                            : "Scan references to find record usage.")
                    } else {
                        ForEach(Array(references.enumerated()), id: \.offset) { _, occurrence in
                            referenceRow(occurrence)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: blob.id) { _, _ in
            resetTransientState()
        }
    }

    private var fileHeader: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: blob.fileSymbolName)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(blob.suggestedFilename)
                    .font(.headline)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Suggested filename")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {
                    previewBlob()
                } label: {
                    Label(isLoadingPreview ? "Verifying…" : "Preview", systemImage: "eye")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!isPublicBlob || isLoadingPreview || isActiveDownloadOnly)

                Button {
                    downloadBlob()
                } label: {
                    Label(isDownloading ? "Downloading…" : "Download…", systemImage: "arrow.down.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!isPublicBlob || isDownloading)

                Button {
                    copyCID()
                } label: {
                    Label(copiedCID ? "Copied" : "Copy CID", systemImage: copiedCID ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if isActiveDownloadOnly {
                note("HTML and SVG blobs are download-only and cannot be previewed directly.")
            }
        }
    }

    private var previewSection: some View {
        inspectorSection("Preview & Integrity") {
            if isLoadingPreview {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Fetching and verifying CIDv1 SHA-256…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            if let previewImage {
                Image(nsImage: previewImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(.rect(cornerRadius: 6))
            }

            if let previewResult {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.shield.fill")
                        .foregroundStyle(.green)
                    Text("CIDv1 SHA-256 verified")
                        .font(.caption.weight(.medium))
                }

                HStack(spacing: 8) {
                    Button {
                        NSWorkspace.shared.open(previewResult.fileURL)
                    } label: {
                        Label("Open in Default App", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([previewResult.fileURL])
                    } label: {
                        Label("Reveal in Finder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }

            if let statusMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let errorMessage {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var availabilityLabel: String {
        switch blob.availability {
        case .unknown: "Unknown (not checked)"
        case .available: "Available"
        case .missing: "Missing"
        }
    }

    private var referenceSummary: String {
        let suffix = blob.referenceIndexComplete ? "scan complete" : "scan incomplete"
        return "\(references.count) occurrence\(references.count == 1 ? "" : "s") · \(suffix)"
    }

    private func previewBlob() {
        guard isPublicBlob, !isLoadingPreview else { return }
        let locator = blob.locator
        let mimeType = blob.mimeType
        let service = payloadService
        let currentBlobID = blob.id

        isLoadingPreview = true
        errorMessage = nil
        statusMessage = nil

        Task {
            defer {
                if blob.id == currentBlobID {
                    isLoadingPreview = false
                }
            }
            do {
                let result = try await service.materializePreview(
                    for: locator,
                    mimeType: mimeType
                )
                guard blob.id == currentBlobID else { return }
                previewResult = result
                verifiedState = result.verification.state
                verifiedByteCount = result.verification.byteCount

                let effectiveMIME = result.contentType ?? mimeType
                if BlobPayloadService.isInlinePreviewableImage(mimeType: effectiveMIME),
                   let loadedImage = NSImage(contentsOf: result.fileURL) {
                    previewImage = loadedImage
                    statusMessage = "Loaded verified inline preview."
                } else {
                    previewImage = nil
                    NSWorkspace.shared.open(result.fileURL)
                    statusMessage = "Opened verified preview file."
                }
            } catch {
                guard blob.id == currentBlobID else { return }
                let message = error.localizedDescription
                errorMessage = message
                if case BlobPayloadError.cidDigestMismatch = error {
                    verifiedState = .failed(reason: message)
                }
            }
        }
    }

    private func downloadBlob() {
        guard isPublicBlob, !isDownloading else { return }
        let locator = blob.locator
        let suggestedFilename = blob.suggestedFilename
        let mimeType = blob.mimeType
        let service = payloadService
        let queue = transferQueue
        let currentBlobID = blob.id

        Task {
            guard let destinationURL = await BlobSavePanelHelper.presentSavePanel(
                suggestedFilename: suggestedFilename,
                mimeType: mimeType
            ) else {
                return
            }

            guard blob.id == currentBlobID else { return }
            isDownloading = true
            errorMessage = nil
            statusMessage = nil
            defer {
                if blob.id == currentBlobID {
                    isDownloading = false
                }
            }

            if let queue {
                let verificationCapture = BlobVerificationCapture()
                let jobID = queue.enqueueAndRun(
                    kind: .blobDownload,
                    title: suggestedFilename,
                    subtitle: locator.cid,
                    requiredAccountDIDs: [],
                    destinationPath: destinationURL.path
                ) { report in
                    let result = try await service.downloadBlob(locator, to: destinationURL) { state, done, total in
                        report(state, done, total)
                    }
                    await verificationCapture.set(result.verification)
                    return result.destinationURL
                }
                statusMessage = "Download queued in Activity."
                await queue.waitForJob(id: jobID)
                guard blob.id == currentBlobID else { return }
                if let job = queue.job(id: jobID) {
                    switch job.state {
                    case .completed:
                        if let captured = await verificationCapture.get() {
                            verifiedState = captured.state
                            verifiedByteCount = captured.byteCount
                        } else {
                            verifiedByteCount = job.bytesCompleted
                        }
                        statusMessage = "Saved and verified at \(destinationURL.lastPathComponent)."
                    case .failed:
                        let message = job.errorMessage ?? "Download failed."
                        errorMessage = message
                        if message.localizedStandardContains("CID verification failed") {
                            verifiedState = .failed(reason: message)
                        }
                        statusMessage = nil
                    case .cancelled:
                        statusMessage = "Download cancelled."
                    case .interrupted:
                        errorMessage = job.errorMessage ?? "Download interrupted."
                        statusMessage = nil
                    default:
                        break
                    }
                }
            } else {
                do {
                    let result = try await service.downloadBlob(locator, to: destinationURL)
                    guard blob.id == currentBlobID else { return }
                    verifiedState = result.verification.state
                    verifiedByteCount = result.verification.byteCount
                    statusMessage = "Saved and verified at \(destinationURL.lastPathComponent)."
                } catch {
                    guard blob.id == currentBlobID else { return }
                    let message = error.localizedDescription
                    errorMessage = message
                    if case BlobPayloadError.cidDigestMismatch = error {
                        verifiedState = .failed(reason: message)
                    }
                }
            }
        }
    }

    private func copyCID() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(blob.locator.cid, forType: .string)
        copiedCID = true
        let currentBlobID = blob.id
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if blob.id == currentBlobID {
                copiedCID = false
            }
        }
    }

    private func resetTransientState() {
        isLoadingPreview = false
        isDownloading = false
        previewResult = nil
        previewImage = nil
        verifiedState = nil
        verifiedByteCount = nil
        statusMessage = nil
        errorMessage = nil
        copiedCID = false
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 9))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metadataRow(
        _ label: String,
        _ value: String,
        monospaced: Bool = true,
        lines: Int = 2
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .lineLimit(lines)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func referenceRow(_ occurrence: BlobReferenceOccurrence) -> some View {
        if let onOpenRecord {
            Button {
                onOpenRecord(occurrence.record)
            } label: {
                referenceLabel(occurrence)
            }
            .buttonStyle(.plain)
        } else {
            referenceLabel(occurrence)
        }
    }

    private func referenceLabel(_ occurrence: BlobReferenceOccurrence) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(occurrence.record.uri)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text("JSON Pointer: \(occurrence.jsonPointer)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.middle)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
