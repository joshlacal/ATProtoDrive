import Foundation

public enum BrowserFailure: Error, LocalizedError, Equatable, Sendable {
    case offline
    case rateLimited(retryAfter: Date?)
    case authorizationRefused
    case notFound(resource: String)
    case http(endpoint: String, statusCode: Int)
    case decodeFailure(endpoint: String, statusCode: Int)
    case invalidIdentifier(String)
    case identityMismatch(expected: String, actual: String)
    case invalidDIDDocument(String)
    case unsupported(String)
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .offline:
            return "The network connection is offline."
        case .rateLimited(let retryAfter):
            if let retryAfter {
                return "Rate limited. Please retry after \(retryAfter)."
            }
            return "Rate limited. Please try again later."
        case .authorizationRefused:
            return "Authorization was refused."
        case .notFound(let resource):
            return "Resource not found: \(resource)"
        case .http(let endpoint, let statusCode):
            return "HTTP error \(statusCode) from \(endpoint)"
        case .decodeFailure(let endpoint, let statusCode):
            return "Decode failure from \(endpoint) (status \(statusCode))"
        case .invalidIdentifier(let identifier):
            return "Invalid identifier: \(identifier)"
        case .identityMismatch(let expected, let actual):
            return "Identity mismatch: expected \(expected), got \(actual)"
        case .invalidDIDDocument(let reason):
            return "Invalid DID document: \(reason)"
        case .unsupported(let feature):
            return "Unsupported: \(feature)"
        case .transport(let summary):
            return "Transport error: \(summary)"
        }
    }
}

public extension BrowserFailure {
    static func normalize(_ error: any Error) -> BrowserFailure {
        if let failure = error as? BrowserFailure { return failure }
        if let urlError = error as? URLError,
           [.notConnectedToInternet, .networkConnectionLost].contains(urlError.code) {
            return .offline
        }
        return .transport(String(describing: type(of: error)))
    }
}
