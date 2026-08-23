import SwiftUI

public struct InlineErrorBanner: View {
    public let message: String
    public let actionTitle: String
    public let retry: (() -> Void)?

    public init(
        message: String,
        actionTitle: String = "Retry",
        retry: (() -> Void)? = nil
    ) {
        self.message = message
        self.actionTitle = actionTitle
        self.retry = retry
    }

    public var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.callout)
                .lineLimit(2)
            Spacer()
            if let retry {
                Button(actionTitle) {
                    retry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.background.secondary)
        .overlay(
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(Color.secondary.opacity(0.2)),
            alignment: .bottom
        )
    }
}

public struct UnavailableStateView: View {
    public let failure: BrowserFailure
    public let retry: (() -> Void)?

    public init(failure: BrowserFailure, retry: (() -> Void)? = nil) {
        self.failure = failure
        self.retry = retry
    }

    public var body: some View {
        ContentUnavailableView {
            Label("Unavailable", systemImage: "exclamationmark.triangle")
        } description: {
            Text(failure.localizedDescription)
        } actions: {
            if let retry {
                Button("Retry") {
                    retry()
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}

public struct BrowserTableShell<T: Sendable, Content: View>: View {
    public let state: LoadState<T>
    public let retry: (() -> Void)?
    @ViewBuilder public let content: (T) -> Content

    public init(
        state: LoadState<T>,
        retry: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (T) -> Content
    ) {
        self.state = state
        self.retry = retry
        self.content = content
    }

    public var body: some View {
        switch state {
        case .idle, .loading(previous: nil):
            ProgressView("Loading repository…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded(let snapshot):
            content(snapshot)
        case .loading(previous: let snapshot?):
            content(snapshot)
                .overlay(alignment: .topTrailing) {
                    ProgressView()
                        .controlSize(.small)
                        .padding(12)
                }
        case .failed(previous: let snapshot?, failure: let failure):
            content(snapshot)
                .safeAreaInset(edge: .top) {
                    InlineErrorBanner(message: failure.localizedDescription, actionTitle: "Retry", retry: retry)
                }
        case .failed(previous: nil, failure: let failure):
            UnavailableStateView(failure: failure, retry: retry)
        }
    }
}
