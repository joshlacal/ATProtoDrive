import Foundation

public enum SearchToken: Hashable, Sendable {
    case source(String), account(String), space(String), owner(String)
    case collection(String), kind(String), mimeType(String), transferState(String)
}

public struct SearchQuery: Hashable, Sendable {
    public var text: String
    public var tokens: [SearchToken]

    public init(text: String = "", tokens: [SearchToken] = []) {
        self.text = text
        self.tokens = tokens
    }
}
