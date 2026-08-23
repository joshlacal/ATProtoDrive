import Foundation

public enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading(previous: Value?)
    case loaded(Value)
    case failed(previous: Value?, failure: BrowserFailure)

    public var snapshot: Value? {
        switch self {
        case .idle: nil
        case .loading(let previous), .failed(let previous, _): previous
        case .loaded(let value): value
        }
    }

    public var isStale: Bool {
        if case .failed(previous: .some, failure: _) = self { return true }
        return false
    }
}
