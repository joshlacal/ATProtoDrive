import Foundation

public enum SearchToken: Hashable, Sendable, Identifiable {
    case source(String)
    case account(String)
    case space(String)
    case owner(String)
    case collection(String)
    case kind(String)
    case mimeType(String)
    case transferState(String)
    case verification(String)

    public var id: String {
        switch self {
        case .source(let v): "source:\(v)"
        case .account(let v): "account:\(v)"
        case .space(let v): "space:\(v)"
        case .owner(let v): "owner:\(v)"
        case .collection(let v): "collection:\(v)"
        case .kind(let v): "kind:\(v)"
        case .mimeType(let v): "mime:\(v)"
        case .transferState(let v): "state:\(v)"
        case .verification(let v): "verification:\(v)"
        }
    }
}

public enum SearchSurface: Hashable, Sendable {
    case publicRecord
    case publicBlob
}

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    public var tokens: [SearchToken]

    public init(text: String = "", tokens: [SearchToken] = []) {
        self.text = text
        self.tokens = tokens
    }

    public func unsupportedTokens(for surface: SearchSurface) -> [SearchToken] {
        switch surface {
        case .publicRecord:
            return tokens.filter { token in
                switch token {
                case .collection, .owner:
                    return false
                case .source(let value):
                    return value.caseInsensitiveCompare("public") != .orderedSame
                case .kind(let value):
                    return value.caseInsensitiveCompare("record") != .orderedSame
                case .account:
                    return false
                case .space, .mimeType, .transferState, .verification:
                    return true
                }
            }
        case .publicBlob:
            return tokens.filter { token in
                switch token {
                case .source(let value):
                    return value.caseInsensitiveCompare("public") != .orderedSame
                case .kind(let value):
                    return value.caseInsensitiveCompare("file") != .orderedSame
                case .owner, .mimeType:
                    return false
                case .verification(let value):
                    return value.caseInsensitiveCompare("not-verified") != .orderedSame
                case .account, .space, .collection, .transferState:
                    return true
                }
            }
        }
    }
}

public extension SearchQuery {
    func matches(record: RecordRow, repository: ResolvedRepository? = nil) -> Bool {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let textMatches = needle.isEmpty || [
            record.collection, record.rkey, record.uri, record.cid, record.json
        ].contains { $0.lowercased().contains(needle) }
        guard textMatches else { return false }
        return tokens.allSatisfy { token in
            switch token {
            case .collection(let value):
                return record.collection.caseInsensitiveCompare(value) == .orderedSame
            case .owner(let value):
                let owner: String?
                switch record.origin {
                case .publicRepository(let did): owner = did
                case .space(_, let repoDID): owner = repoDID
                case .unknown: owner = nil
                }
                return owner?.caseInsensitiveCompare(value) == .orderedSame
            case .source(let value):
                return value.caseInsensitiveCompare("public") == .orderedSame
            case .kind(let value):
                return value.caseInsensitiveCompare("record") == .orderedSame
            case .account(let value):
                return repository?.connectedAccountDID?.caseInsensitiveCompare(value) == .orderedSame
            case .space, .mimeType, .transferState, .verification:
                return false
            }
        }
    }

    func matches(blob: BlobDescriptor) -> Bool {
        guard unsupportedTokens(for: .publicBlob).isEmpty else { return false }
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let textMatches = needle.isEmpty || [
            blob.locator.cid, blob.suggestedFilename, blob.displayMIMEType, blob.ownerDID
        ].contains { $0.lowercased().contains(needle) }
        guard textMatches else { return false }
        return tokens.allSatisfy { token in
            switch token {
            case .source(let value):
                return value.caseInsensitiveCompare("public") == .orderedSame
            case .owner(let value):
                return blob.ownerDID.caseInsensitiveCompare(value) == .orderedSame
            case .mimeType(let value):
                return blob.mimeType?.caseInsensitiveCompare(value) == .orderedSame
            case .kind(let value):
                return value.caseInsensitiveCompare("file") == .orderedSame
            case .verification(let value):
                return value.caseInsensitiveCompare("not-verified") == .orderedSame
                    && blob.verification == .notVerified
            case .account, .space, .collection, .transferState:
                return false
            }
        }
    }
}

public enum SearchQueryParser {
    public static func parse(_ raw: String) -> SearchQuery {
        var freeTextParts: [String] = []
        var tokens: [SearchToken] = []

        var index = raw.startIndex

        while index < raw.endIndex {
            if raw[index].isWhitespace {
                index = raw.index(after: index)
                continue
            }

            if let (token, nextIndex) = parseToken(from: raw, startIndex: index) {
                tokens.append(token)
                index = nextIndex
            } else {
                let (textChunk, nextIndex) = parseFreeText(from: raw, startIndex: index)
                if !textChunk.isEmpty {
                    freeTextParts.append(textChunk)
                }
                index = nextIndex
            }
        }

        let text = freeTextParts.joined(separator: " ")
        return SearchQuery(text: text, tokens: tokens)
    }

    private static func parseToken(from raw: String, startIndex: String.Index) -> (SearchToken, String.Index)? {
        let prefixes: [(prefix: String, makeToken: (String) -> SearchToken)] = [
            ("source:", { .source($0) }),
            ("account:", { .account($0) }),
            ("space:", { .space($0) }),
            ("owner:", { .owner($0) }),
            ("collection:", { .collection($0) }),
            ("kind:", { .kind($0) }),
            ("mime:", { .mimeType($0) }),
            ("state:", { .transferState($0) }),
            ("verification:", { .verification($0) })
        ]

        for (prefix, makeToken) in prefixes {
            guard let prefixEnd = matchPrefix(prefix, in: raw, from: startIndex) else {
                continue
            }

            var curr = prefixEnd
            if curr < raw.endIndex && raw[curr] == "\"" {
                curr = raw.index(after: curr)
                var parsedValue = ""
                var terminated = false
                while curr < raw.endIndex {
                    let c = raw[curr]
                    if c == "\\" {
                        let next = raw.index(after: curr)
                        if next < raw.endIndex {
                            let escaped = raw[next]
                            if escaped == "\"" || escaped == "\\" {
                                parsedValue.append(escaped)
                                curr = raw.index(after: next)
                                continue
                            } else {
                                parsedValue.append(c)
                                parsedValue.append(escaped)
                                curr = raw.index(after: next)
                                continue
                            }
                        } else {
                            parsedValue.append(c)
                            curr = next
                            break
                        }
                    } else if c == "\"" {
                        terminated = true
                        curr = raw.index(after: curr)
                        break
                    } else {
                        parsedValue.append(c)
                        curr = raw.index(after: curr)
                    }
                }

                if terminated && !parsedValue.isEmpty {
                    return (makeToken(parsedValue), curr)
                } else {
                    return nil
                }
            } else {
                var parsedValue = ""
                while curr < raw.endIndex && !raw[curr].isWhitespace {
                    parsedValue.append(raw[curr])
                    curr = raw.index(after: curr)
                }
                guard !parsedValue.isEmpty else {
                    return nil
                }
                return (makeToken(parsedValue), curr)
            }
        }
        return nil
    }

    private static func matchPrefix(_ prefix: String, in raw: String, from startIndex: String.Index) -> String.Index? {
        var pIdx = prefix.startIndex
        var rIdx = startIndex
        while pIdx < prefix.endIndex && rIdx < raw.endIndex {
            if raw[rIdx].lowercased() != prefix[pIdx].lowercased() {
                return nil
            }
            pIdx = prefix.index(after: pIdx)
            rIdx = raw.index(after: rIdx)
        }
        if pIdx == prefix.endIndex {
            return rIdx
        }
        return nil
    }

    private static func parseFreeText(from raw: String, startIndex: String.Index) -> (String, String.Index) {
        var curr = startIndex
        var text = ""
        while curr < raw.endIndex && !raw[curr].isWhitespace {
            text.append(raw[curr])
            curr = raw.index(after: curr)
        }
        return (text, curr)
    }
}
