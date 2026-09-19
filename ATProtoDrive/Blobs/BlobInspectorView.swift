import SwiftUI

public struct BlobInspectorView: View {
    public let blob: BlobDescriptor
    public let references: [BlobReferenceOccurrence]
    public let onOpenRecord: ((RecordLocator) -> Void)?

    public init(
        blob: BlobDescriptor,
        references: [BlobReferenceOccurrence],
        onOpenRecord: ((RecordLocator) -> Void)? = nil
    ) {
        self.blob = blob
        self.references = references.sorted {
            ($0.record.uri, $0.jsonPointer) < ($1.record.uri, $1.jsonPointer)
        }
        self.onOpenRecord = onOpenRecord
    }

    public var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                fileHeader

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
                    metadataRow("Availability", availabilityLabel, monospaced: false)
                    metadataRow("Verification", blob.verificationLabel, monospaced: false)
                    note("Metadata is derived from public records. File bytes have not been downloaded or verified.")
                }

                inspectorSection("Access") {
                    metadataRow("Classification", "Public", monospaced: false)
                    note("This file is listed by a public AT Protocol repository.")
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
