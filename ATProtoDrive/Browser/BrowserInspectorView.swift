import SwiftUI

public struct BrowserInspectorValue: Equatable, Sendable {
    public let access: AccessClassification?
    public let fields: [String: String]
    public let rawJSON: String

    public init(access: AccessClassification?, fields: [String: String], rawJSON: String) {
        self.access = access
        self.fields = fields
        self.rawJSON = rawJSON
    }
}

public enum BrowserInspectorProjection {
    public static func record(_ row: RecordRow, locator: RecordLocator) -> BrowserInspectorValue {
        let access: AccessClassification?
        switch row.origin {
        case .publicRepository(let did):
            access = .publicRepository(did: did)
        case .space(let space, let repoDID):
            access = .permissionedSpace(spaceURI: space.uriString(), writerDID: repoDID)
        case .unknown:
            access = nil
        }
        precondition(locator.uri == row.uri && locator.cid == row.cid)
        return .init(
            access: access,
            fields: [
                "URI": locator.uri,
                "CID": locator.cid,
                "Collection": locator.collection,
                "Record Key": locator.rkey,
                "Repository Scope": locator.scope.stableID
            ],
            rawJSON: row.json
        )
    }
}

public struct BrowserInspectorView: View {
    public let references: [ResourceReference]
    public let primaryRecord: RecordRow?

    public init(
        references: [ResourceReference] = [],
        primaryRecord: RecordRow? = nil
    ) {
        self.references = references
        self.primaryRecord = primaryRecord
    }

    public init(
        reference: ResourceReference?,
        record: RecordRow? = nil
    ) {
        self.references = reference.map { [$0] } ?? []
        self.primaryRecord = record
    }

    public var body: some View {
        Group {
            if references.isEmpty {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.right",
                    description: Text("Select an item to inspect its details.")
                )
            } else if references.count > 1 {
                inspectorMultiSelectionContent(count: references.count, references: references)
            } else if let reference = references.first {
                if case .record(let locator) = reference, let record = primaryRecord {
                    let value = BrowserInspectorProjection.record(record, locator: locator)
                    inspectorRecordContent(value: value, record: record, locator: locator)
                } else {
                    inspectorGeneralReference(reference)
                }
            }
        }
    }

    public static func commonAccessClassification(for references: [ResourceReference]) -> AccessClassification? {
        guard let first = references.first?.scope.accessClassification else { return nil }
        for ref in references.dropFirst() {
            if ref.scope.accessClassification != first {
                return nil
            }
        }
        return first
    }

    @ViewBuilder
    private func inspectorMultiSelectionContent(
        count: Int,
        references: [ResourceReference]
    ) -> some View {
        Form {
            Section("Multiple Selection") {
                LabeledContent("Selected Items", value: "\(count) items")
                if let commonAccess = Self.commonAccessClassification(for: references) {
                    switch commonAccess {
                    case .publicRepository(let did):
                        LabeledContent("Source", value: "Public Repository")
                        LabeledContent("DID", value: did)
                            .textSelection(.enabled)
                    case .permissionedSpace(let spaceURI, let writerDID):
                        LabeledContent("Source", value: "Permissioned Space")
                        LabeledContent("Space URI", value: spaceURI)
                            .textSelection(.enabled)
                        LabeledContent("Writer DID", value: writerDID)
                            .textSelection(.enabled)
                    case .privateAppState(let provider, let accountDID):
                        LabeledContent("Source", value: "Private App State")
                        LabeledContent("Provider", value: provider)
                        LabeledContent("Account DID", value: accountDID)
                            .textSelection(.enabled)
                    case .localBackup(let backupID, _):
                        LabeledContent("Source", value: "Local Backup")
                        LabeledContent("Backup ID", value: backupID.uuidString)
                            .textSelection(.enabled)
                    }
                } else {
                    LabeledContent("Source", value: "Multiple Sources")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func inspectorRecordContent(
        value: BrowserInspectorValue,
        record: RecordRow,
        locator: RecordLocator
    ) -> some View {
        Form {
            Section("Preview") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(locator.rkey)
                        .font(.headline)
                    Text(locator.collection)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Identity & Location") {
                LabeledContent("URI", value: locator.uri)
                    .textSelection(.enabled)
                LabeledContent("CID", value: locator.cid)
                    .textSelection(.enabled)
                LabeledContent("Collection", value: locator.collection)
                    .textSelection(.enabled)
                LabeledContent("Record Key", value: locator.rkey)
                    .textSelection(.enabled)
                LabeledContent("Repository Scope", value: locator.scope.stableID)
                    .textSelection(.enabled)
                if case .publicRepository(let did, let pdsURL) = locator.scope {
                    LabeledContent("DID", value: did)
                        .textSelection(.enabled)
                    LabeledContent("PDS", value: pdsURL.absoluteString)
                        .textSelection(.enabled)
                } else if case .permissionedSpace(let spaceURI, let writerDID, _) = locator.scope {
                    LabeledContent("Space URI", value: spaceURI)
                        .textSelection(.enabled)
                    LabeledContent("Writer DID", value: writerDID)
                        .textSelection(.enabled)
                }
            }

            Section("Access") {
                if let access = value.access {
                    switch access {
                    case .publicRepository(let did):
                        LabeledContent("Classification", value: "Public Repository")
                        LabeledContent("DID", value: did)
                            .textSelection(.enabled)
                    case .permissionedSpace(let spaceURI, let writerDID):
                        LabeledContent("Classification", value: "Permissioned Space")
                        LabeledContent("Space URI", value: spaceURI)
                            .textSelection(.enabled)
                        LabeledContent("Writer DID", value: writerDID)
                            .textSelection(.enabled)
                    case .privateAppState(let provider, let accountDID):
                        LabeledContent("Classification", value: "Private App State")
                        LabeledContent("Provider", value: provider)
                        LabeledContent("Account DID", value: accountDID)
                    case .localBackup(let backupID, _):
                        LabeledContent("Classification", value: "Local Backup")
                        LabeledContent("Backup ID", value: backupID.uuidString)
                    }
                } else {
                    Text("Source unavailable")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Blob References") {
                if record.blobRefs.isEmpty {
                    Text("No blob references")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(record.blobRefs, id: \.self) { cid in
                        Text(cid)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
                Text("Blob index is incomplete")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Section("Raw JSON") {
                ScrollView(.horizontal) {
                    Text(value.rawJSON)
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func inspectorGeneralReference(_ reference: ResourceReference) -> some View {
        Form {
            Section("Selection") {
                LabeledContent("Stable ID", value: reference.stableID)
                    .textSelection(.enabled)
                LabeledContent("Scope", value: reference.scope.stableID)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }
}
