import Foundation
import Petrel

public enum BlobReferenceScanner {
    public static func scan(
        value: ATProtocolValueContainer,
        record: RecordLocator
    ) throws -> [BlobReferenceOccurrence] {
        var result: [BlobReferenceOccurrence] = []
        try walk(value, pointer: "", record: record, into: &result)
        return result
    }

    private static func escape(_ key: String) -> String {
        key.replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }

    private static func walk(
        _ value: ATProtocolValueContainer,
        pointer: String,
        record: RecordLocator,
        into result: inout [BlobReferenceOccurrence]
    ) throws {
        switch value {
        case .knownType:
            // Re-encode the existential through the container, then project JSON values to
            // raw containers without generated dispatch. This preserves nested Blob fields.
            let projected = try RawATProtocolProjection.project(value)
            try walk(projected, pointer: pointer, record: record, into: &result)
        case .object(let fields):
            if let occurrence = occurrence(type: nil, fields: fields, pointer: pointer, record: record) {
                result.append(occurrence)
            }
            for key in fields.keys.sorted() {
                guard let child = fields[key] else { continue }
                try walk(child, pointer: "\(pointer)/\(escape(key))", record: record, into: &result)
            }
        case .array(let values):
            for (index, child) in values.enumerated() {
                try walk(child, pointer: "\(pointer)/\(index)", record: record, into: &result)
            }
        case .unknownType(let type, let child):
            switch child {
            case .object(let fields):
                if let occurrence = occurrence(type: type, fields: fields, pointer: pointer, record: record) {
                    result.append(occurrence)
                }
                for key in fields.keys.sorted() {
                    guard let grandchild = fields[key] else { continue }
                    try walk(grandchild, pointer: "\(pointer)/\(escape(key))", record: record, into: &result)
                }
            default:
                try walk(child, pointer: pointer, record: record, into: &result)
            }
        default:
            break
        }
    }

    private static func occurrence(
        type: String?,
        fields: [String: ATProtocolValueContainer],
        pointer: String,
        record: RecordLocator
    ) -> BlobReferenceOccurrence? {
        let isBlob = type == "blob" || fields["$type"].map { $0 == .string("blob") } == true
        guard isBlob else { return nil }
        let cid: String?
        switch fields["ref"] {
        case .link(let link):
            cid = link.cid.description
        case .object(let object):
            if case .string(let value)? = object["$link"] {
                cid = value
            } else {
                cid = nil
            }
        default:
            cid = nil
        }
        guard let cid else { return nil }
        let mimeType: String?
        if case .string(let value)? = fields["mimeType"] { mimeType = value } else { mimeType = nil }
        let declaredSize: Int?
        if case .number(let value)? = fields["size"] { declaredSize = value } else { declaredSize = nil }
        return BlobReferenceOccurrence(
            blob: BlobLocator(scope: record.scope, cid: cid),
            record: record,
            jsonPointer: pointer,
            mimeType: mimeType,
            declaredSize: declaredSize
        )
    }
}

private enum RawATProtocolProjection {
    static func project(_ value: ATProtocolValueContainer) throws -> ATProtocolValueContainer {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
        return try container(object)
    }

    private static func container(_ value: Any) throws -> ATProtocolValueContainer {
        switch value {
        case let object as [String: Any]:
            return .object(try object.mapValues(container))
        case let array as [Any]:
            return .array(try array.map(container))
        case let string as String:
            return .string(string)
        case let number as NSNumber where CFGetTypeID(number) == CFBooleanGetTypeID():
            return .bool(number.boolValue)
        case let number as NSNumber:
            return .number(number.intValue)
        case is NSNull:
            return .null
        default:
            throw BlobReferenceScanError.unsupportedProjectedValue
        }
    }
}
