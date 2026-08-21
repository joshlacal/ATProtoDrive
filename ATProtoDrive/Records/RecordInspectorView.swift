//
//  RecordInspectorView.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct RecordInspectorView: View {
    let record: RecordRow?
    let commit: (rev: String, hash: String)?

    public init(record: RecordRow?, commit: (rev: String, hash: String)? = nil) {
        self.record = record
        self.commit = commit
    }

    public var body: some View {
        if let record = record {
            VStack(alignment: .leading, spacing: 0) {
                // Header
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(record.collection)
                            .font(.headline)
                        Text("/ \(record.rkey)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        Text("CID:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(record.cid)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }

                    HStack(spacing: 8) {
                        Text("URI:")
                            .font(.caption)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                        Text(record.uri)
                            .font(.system(.caption2, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(NSColor.controlBackgroundColor))

                Divider()

                // Blob refs section if present
                if !record.blobRefs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Blob References (\(record.blobRefs.count))")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)

                        ForEach(record.blobRefs, id: \.self) { blobCID in
                            HStack(spacing: 6) {
                                Image(systemName: "doc.zipper")
                                    .foregroundStyle(.secondary)
                                Text(blobCID)
                                    .font(.system(.caption, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.05))

                    Divider()
                }

                // JSON Content View
                ScrollView {
                    Text(record.json)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .padding()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Divider()

                // Commit Footer
                if let commit = commit {
                    HStack(spacing: 12) {
                        Label(commit.rev, systemImage: "clock.arrow.circlepath")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)

                        Label(commit.hash, systemImage: "number")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(NSColor.controlBackgroundColor))
                }
            }
            .frame(minWidth: 260)
        } else {
            ContentUnavailableView(
                "No Record Selected",
                systemImage: "doc.text",
                description: Text("Select a record to inspect its value and metadata.")
            )
            .frame(minWidth: 260)
        }
    }
}
