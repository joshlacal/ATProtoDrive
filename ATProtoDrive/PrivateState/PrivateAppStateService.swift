//
//  PrivateAppStateService.swift
//  ATProtoDrive
//

import Foundation
import Observation
import Petrel

// MARK: - Preference Projection Models

public struct PreferenceSummaryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let typeIdentifier: String
    public let title: String
    public let symbolName: String
    public let subtitle: String
    public let details: [String]
    public let rawItemJSON: String

    public init(
        id: String,
        typeIdentifier: String,
        title: String,
        symbolName: String,
        subtitle: String,
        details: [String] = [],
        rawItemJSON: String = "{}"
    ) {
        self.id = id
        self.typeIdentifier = typeIdentifier
        self.title = title
        self.symbolName = symbolName
        self.subtitle = subtitle
        self.details = details
        self.rawItemJSON = rawItemJSON
    }
}

public enum PrivateAppStateResult: Equatable, Sendable {
    case loaded([PreferenceSummaryItem], rawJSON: String)
    case unsupported(reason: String)
    case failed(String)
}

// MARK: - Read-Only Private App State Service

public typealias PreferencesFetchTransport = @Sendable (AccountStore.Account) async throws -> (
    responseCode: Int,
    data: AppBskyActorGetPreferences.Output?
)

/// Strictly read-only service for inspecting authenticated Bluesky preferences via
/// `app.bsky.actor.getPreferences`. Never falls back to unauthenticated public endpoints
/// and exposes zero mutation APIs.
public struct PrivateAppStateService: Sendable {
    public static let providerID = "app.bsky.actor.getPreferences"
    public static let providerTitle = "Bluesky AppView Preferences"

    private let transport: PreferencesFetchTransport

    public init(transport: PreferencesFetchTransport? = nil) {
        self.transport = transport ?? Self.liveTransport
    }

    public static let liveTransport: PreferencesFetchTransport = { account in
        let info = await account.client.getActiveAccountInfo()
        if let activeDID = info.did, activeDID != account.id {
            throw BrowserFailure.identityMismatch(expected: account.id, actual: activeDID)
        }
        return try await account.client.app.bsky.actor.getPreferences(input: .init())
    }

    /// Fetches read-only Bluesky preferences for the exact owning account.
    /// Never falls back to public or unauthenticated endpoints.
    public func fetchPreferences(for account: AccountStore.Account) async -> PrivateAppStateResult {
        do {
            let (responseCode, output) = try await transport(account)

            if (200 ... 299).contains(responseCode) {
                guard let output else {
                    return .failed("The server returned HTTP \(responseCode) without a valid preferences payload.")
                }
                let items = Self.project(preferences: output.preferences)
                let rawJSON = Self.prettyPrintJSON(for: output.preferences)
                return .loaded(items, rawJSON: rawJSON)
            }

            if responseCode == 401 {
                return .failed("Authentication required or session expired (HTTP 401). Reconnect this account in Server & Account and try again.")
            }

            if responseCode == 403 {
                return .unsupported(
                    reason: "This server or OAuth session does not authorize app.bsky.actor.getPreferences (HTTP 403). ATProtoDrive will not fall back to public endpoints."
                )
            }

            if [400, 404, 405, 501].contains(responseCode) {
                return .unsupported(
                    reason: Self.unsupportedReason(statusCode: responseCode, errorCode: nil, serverMessage: nil)
                )
            }

            if responseCode == 429 {
                return .failed("Rate limited by server (HTTP 429). Try again shortly.")
            }

            return .failed("Server returned HTTP \(responseCode) while reading private preferences.")
        } catch is CancellationError {
            return .failed("Request cancelled.")
        } catch {
            return Self.classifyError(error)
        }
    }

    // MARK: - Error Classification

    public static func classifyError(_ error: any Error) -> PrivateAppStateResult {
        if let xrpc = error as? ATProtoXRPCError {
            if isAuthFailure(statusCode: xrpc.statusCode, errorCode: xrpc.error, message: xrpc.message) {
                let detail = xrpc.errorDescription ?? "HTTP \(xrpc.statusCode)"
                return .failed("Authentication error (\(detail)). Reconnect this account in Server & Account and retry.")
            }

            if isUnsupportedError(statusCode: xrpc.statusCode, errorCode: xrpc.error, message: xrpc.message) {
                return .unsupported(
                    reason: unsupportedReason(
                        statusCode: xrpc.statusCode,
                        errorCode: xrpc.error,
                        serverMessage: xrpc.message
                    )
                )
            }

            return .failed(xrpc.errorDescription ?? "Server error (HTTP \(xrpc.statusCode)).")
        }

        if let networkError = error as? NetworkError {
            switch networkError {
            case .expiredToken, .authenticationRequired, .unauthorized, .authenticationFailed:
                return .failed(networkError.errorDescription ?? "Authentication failed. Reconnect this account and retry.")
            case .responseError(let statusCode):
                if statusCode == 401 {
                    return .failed("Authentication required (HTTP 401). Reconnect this account and retry.")
                }
                if [400, 403, 404, 405, 501].contains(statusCode) {
                    return .unsupported(
                        reason: unsupportedReason(statusCode: statusCode, errorCode: nil, serverMessage: nil)
                    )
                }
                return .failed(networkError.errorDescription ?? "Server returned HTTP \(statusCode).")
            case .badRequest(let description):
                if isAuthFailure(statusCode: 400, errorCode: nil, message: description) {
                    return .failed("Authentication error: \(description)")
                }
                return .unsupported(
                    reason: unsupportedReason(statusCode: 400, errorCode: "BadRequest", serverMessage: description)
                )
            case .serverError(let code, let message):
                if isUnsupportedError(statusCode: code, errorCode: nil, message: message) {
                    return .unsupported(
                        reason: unsupportedReason(statusCode: code, errorCode: nil, serverMessage: message)
                    )
                }
                return .failed("Server error (\(code)): \(message)")
            default:
                return .failed(networkError.errorDescription ?? error.localizedDescription)
            }
        }

        if let authError = error as? AuthError {
            return .failed(authError.errorDescription ?? authError.localizedDescription)
        }

        if let decodingError = error as? XRPCResponseDecodingError {
            return .failed(decodingError.errorDescription ?? "Failed to decode Bluesky preferences response.")
        }

        if let browserFailure = error as? BrowserFailure {
            if case .unsupported(let reason) = browserFailure {
                return .unsupported(reason: reason)
            }
            return .failed(browserFailure.errorDescription ?? browserFailure.localizedDescription)
        }

        if let urlError = error as? URLError {
            return .failed(urlError.localizedDescription)
        }

        return .failed(error.localizedDescription)
    }

    private static func isAuthFailure(statusCode: Int, errorCode: String?, message: String?) -> Bool {
        let code = errorCode?.lowercased() ?? ""
        let msg = message?.lowercased() ?? ""
        let authTokens = ["expiredtoken", "invalidtoken", "authmissing", "authenticationrequired"]
        if authTokens.contains(where: { code.contains($0) }) {
            return true
        }
        if statusCode == 401 && !isScopeOnlyToken(code: code, message: msg) {
            return true
        }
        return false
    }

    private static func isScopeOnlyToken(code: String, message: String) -> Bool {
        let combined = "\(code) \(message)"
        return combined.contains("scopemissing")
            || combined.contains("insufficientscope")
            || combined.contains("invalidscope")
            || combined.contains("missing scope")
            || combined.contains("missing required scope")
    }

    private static func isUnsupportedError(statusCode: Int, errorCode: String?, message: String?) -> Bool {
        let code = errorCode?.lowercased() ?? ""
        let msg = message?.lowercased() ?? ""
        let combined = "\(code) \(msg)"

        if [400, 403, 404, 405, 501].contains(statusCode) {
            return true
        }

        let unsupportedKeywords = [
            "methodnotimplemented",
            "xrpcnotsupported",
            "notimplemented",
            "scopemissing",
            "invalidscope",
            "insufficientscope",
            "missingscope",
            "appview",
            "unable to proxy",
            "unknown service",
            "service not found",
            "not supported",
            "unsupported"
        ]
        return unsupportedKeywords.contains(where: { combined.contains($0) })
    }

    private static func unsupportedReason(statusCode: Int, errorCode: String?, serverMessage: String?) -> String {
        let suffix: String
        if let errorCode, !errorCode.isEmpty, let serverMessage, !serverMessage.isEmpty {
            suffix = " (\(errorCode): \(serverMessage))"
        } else if let errorCode, !errorCode.isEmpty {
            suffix = " (\(errorCode), HTTP \(statusCode))"
        } else if let serverMessage, !serverMessage.isEmpty {
            suffix = " (HTTP \(statusCode): \(serverMessage))"
        } else {
            suffix = " (HTTP \(statusCode))"
        }

        if statusCode == 403 || isScopeOnlyToken(code: errorCode?.lowercased() ?? "", message: serverMessage?.lowercased() ?? "") {
            return "Bluesky AppView preferences are not authorized for this OAuth session\(suffix)."
        }
        return "This server does not expose Bluesky AppView preferences via app.bsky.actor.getPreferences\(suffix)."
    }

    // MARK: - Projection of AppBskyActorDefs.Preferences

    public static func project(preferences: AppBskyActorDefs.Preferences) -> [PreferenceSummaryItem] {
        preferences.items.enumerated().map { index, entry in
            projectItem(entry, index: index)
        }
    }

    public static func projectItem(
        _ entry: AppBskyActorDefs.PreferencesForUnionArray,
        index: Int
    ) -> PreferenceSummaryItem {
        let rawItemJSON = prettyPrintJSON(for: entry)

        switch entry {
        case .adultContentPref(let pref):
            let typeID = "app.bsky.actor.defs#adultContentPref"
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Adult Content",
                symbolName: "eye.trianglebadge.exclamationmark",
                subtitle: pref.enabled ? "Enabled" : "Disabled",
                details: ["Adult content visibility: \(pref.enabled ? "Enabled" : "Disabled")"],
                rawItemJSON: rawItemJSON
            )

        case .contentLabelPref(let pref):
            let typeID = "app.bsky.actor.defs#contentLabelPref"
            var details = [
                "Label: \(pref.label)",
                "Visibility: \(pref.visibility)"
            ]
            if let labelerDid = pref.labelerDid {
                details.append("Labeler: \(labelerDid.didString())")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)-\(pref.label)",
                typeIdentifier: typeID,
                title: "Content Label",
                symbolName: "tag",
                subtitle: "\(pref.label) → \(pref.visibility)",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .savedFeedsPref(let pref):
            let typeID = "app.bsky.actor.defs#savedFeedsPref"
            var details: [String] = []
            if let timelineIndex = pref.timelineIndex {
                details.append("Timeline index: \(timelineIndex)")
            }
            details.append(contentsOf: pref.pinned.prefix(5).map { "Pinned: \($0.uriString())" })
            if pref.pinned.count > 5 {
                details.append("… and \(pref.pinned.count - 5) more pinned")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Saved Feeds (v1)",
                symbolName: "list.bullet.rectangle",
                subtitle: "\(pref.saved.count) saved · \(pref.pinned.count) pinned",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .savedFeedsPrefV2(let pref):
            let typeID = "app.bsky.actor.defs#savedFeedsPrefV2"
            let pinnedCount = pref.items.filter(\.pinned).count
            var details = pref.items.prefix(6).map { item in
                let prefix = item.pinned ? "Pinned" : "Saved"
                return "\(prefix) (\(item.type)): \(item.value)"
            }
            if pref.items.count > 6 {
                details.append("… and \(pref.items.count - 6) more feeds")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Saved Feeds",
                symbolName: "pin.square",
                subtitle: "\(pref.items.count) \(pref.items.count == 1 ? "feed" : "feeds") (\(pinnedCount) pinned)",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .personalDetailsPref(let pref):
            let typeID = "app.bsky.actor.defs#personalDetailsPref"
            let subtitle: String
            let details: [String]
            if let birthDate = pref.birthDate {
                let formatted = birthDate.date.formatted(date: .abbreviated, time: .omitted)
                subtitle = "Birth date set"
                details = ["Birth date: \(formatted)"]
            } else {
                subtitle = "No personal details recorded"
                details = []
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Personal Details",
                symbolName: "person.text.rectangle",
                subtitle: subtitle,
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .declaredAgePref(let pref):
            let typeID = "app.bsky.actor.defs#declaredAgePref"
            var flags: [String] = []
            if let over13 = pref.isOverAge13 { flags.append("Over 13: \(over13 ? "Yes" : "No")") }
            if let over16 = pref.isOverAge16 { flags.append("Over 16: \(over16 ? "Yes" : "No")") }
            if let over18 = pref.isOverAge18 { flags.append("Over 18: \(over18 ? "Yes" : "No")") }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Declared Age",
                symbolName: "person.badge.shield.checkmark",
                subtitle: flags.isEmpty ? "No age declarations" : flags.joined(separator: " · "),
                details: flags,
                rawItemJSON: rawItemJSON
            )

        case .feedViewPref(let pref):
            let typeID = "app.bsky.actor.defs#feedViewPref"
            var details: [String] = ["Feed: \(pref.feed)"]
            if let hideReplies = pref.hideReplies {
                details.append("Hide replies: \(hideReplies ? "Yes" : "No")")
            }
            if let hideUnfollowed = pref.hideRepliesByUnfollowed {
                details.append("Hide replies by unfollowed: \(hideUnfollowed ? "Yes" : "No")")
            }
            if let minLikes = pref.hideRepliesByLikeCount {
                details.append("Minimum reply likes: \(minLikes)")
            }
            if let hideReposts = pref.hideReposts {
                details.append("Hide reposts: \(hideReposts ? "Yes" : "No")")
            }
            if let hideQuotes = pref.hideQuotePosts {
                details.append("Hide quote posts: \(hideQuotes ? "Yes" : "No")")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)-\(pref.feed)",
                typeIdentifier: typeID,
                title: "Feed View Preferences",
                symbolName: "rectangle.grid.1x2",
                subtitle: "Feed: \(pref.feed)",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .threadViewPref(let pref):
            let typeID = "app.bsky.actor.defs#threadViewPref"
            let sortValue = pref.sort ?? "default"
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Thread View Preferences",
                symbolName: "text.alignleft",
                subtitle: "Sort: \(sortValue)",
                details: ["Thread sort order: \(sortValue)"],
                rawItemJSON: rawItemJSON
            )

        case .interestsPref(let pref):
            let typeID = "app.bsky.actor.defs#interestsPref"
            var details = pref.tags.prefix(10).map { "#\($0)" }
            if pref.tags.count > 10 {
                details.append("… and \(pref.tags.count - 10) more tags")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Interests",
                symbolName: "sparkles",
                subtitle: "\(pref.tags.count) \(pref.tags.count == 1 ? "interest" : "interests")",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .mutedWordsPref(let pref):
            let typeID = "app.bsky.actor.defs#mutedWordsPref"
            var details = pref.items.prefix(8).map { word in
                let targetSummary = word.targets.map(\.rawValue).joined(separator: ", ")
                if targetSummary.isEmpty {
                    return word.value
                }
                return "\(word.value) (\(targetSummary))"
            }
            if pref.items.count > 8 {
                details.append("… and \(pref.items.count - 8) more muted words")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Muted Words",
                symbolName: "speaker.slash",
                subtitle: "\(pref.items.count) muted \(pref.items.count == 1 ? "word" : "words")",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .hiddenPostsPref(let pref):
            let typeID = "app.bsky.actor.defs#hiddenPostsPref"
            var details = pref.items.prefix(5).map { $0.uriString() }
            if pref.items.count > 5 {
                details.append("… and \(pref.items.count - 5) more hidden posts")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Hidden Posts",
                symbolName: "eye.slash",
                subtitle: "\(pref.items.count) hidden \(pref.items.count == 1 ? "post" : "posts")",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .bskyAppStatePref(let pref):
            let typeID = "app.bsky.actor.defs#bskyAppStatePref"
            var details: [String] = []
            if let guide = pref.activeProgressGuide {
                details.append("Active progress guide: \(guide.guide)")
            }
            if let isBeta = pref.isBetaUser {
                details.append("Beta user: \(isBeta ? "Yes" : "No")")
            }
            if let nudges = pref.queuedNudges, !nudges.isEmpty {
                details.append("Queued nudges: \(nudges.joined(separator: ", "))")
            }
            if let nuxs = pref.nuxs {
                details.append("NUX entries: \(nuxs.count)")
            }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Bluesky App State",
                symbolName: "app.badge",
                subtitle: details.first ?? "App state metadata",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .labelersPref(let pref):
            let typeID = "app.bsky.actor.defs#labelersPref"
            let details = pref.labelers.map { $0.did.didString() }
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Subscribed Labelers",
                symbolName: "shield.lefthalf.filled",
                subtitle: "\(pref.labelers.count) \(pref.labelers.count == 1 ? "labeler" : "labelers")",
                details: details,
                rawItemJSON: rawItemJSON
            )

        case .postInteractionSettingsPref(let pref):
            let typeID = "app.bsky.actor.defs#postInteractionSettingsPref"
            let threadRulesCount = pref.threadgateAllowRules?.count ?? 0
            let postRulesCount = pref.postgateEmbeddingRules?.count ?? 0
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Post Interaction Settings",
                symbolName: "bubble.left.and.exclamationmark.bubble.right",
                subtitle: "\(threadRulesCount) reply rules · \(postRulesCount) quote rules",
                details: [
                    "Default threadgate allow rules: \(threadRulesCount)",
                    "Default postgate embedding rules: \(postRulesCount)"
                ],
                rawItemJSON: rawItemJSON
            )

        case .verificationPrefs(let pref):
            let typeID = "app.bsky.actor.defs#verificationPrefs"
            let hidden = pref.hideBadges == true
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Verification Preferences",
                symbolName: "checkmark.seal",
                subtitle: hidden ? "Verification badges hidden" : "Verification badges visible",
                details: ["Hide verification badges: \(hidden ? "Yes" : "No")"],
                rawItemJSON: rawItemJSON
            )

        case .liveEventPreferences(let pref):
            let typeID = "app.bsky.actor.defs#liveEventPreferences"
            let hideAll = pref.hideAllFeeds == true
            let hiddenCount = pref.hiddenFeedIds?.count ?? 0
            return PreferenceSummaryItem(
                id: "\(index)-\(typeID)",
                typeIdentifier: typeID,
                title: "Live Event Preferences",
                symbolName: "dot.radiowaves.left.and.right",
                subtitle: hideAll ? "All live feeds hidden" : "\(hiddenCount) hidden live feeds",
                details: [
                    "Hide all live feeds: \(hideAll ? "Yes" : "No")",
                    "Hidden feed IDs: \(hiddenCount)"
                ],
                rawItemJSON: rawItemJSON
            )

        case .unexpected(let container):
            let fallbackType = extractTypeIdentifier(from: container)
            let shortTitle = shortFallbackTitle(for: fallbackType)
            return PreferenceSummaryItem(
                id: "\(index)-\(fallbackType)",
                typeIdentifier: fallbackType,
                title: shortTitle,
                symbolName: "puzzlepiece.extension",
                subtitle: fallbackType,
                details: ["Unrecognized preference union preserved verbatim in Raw JSON."],
                rawItemJSON: rawItemJSON
            )
        }
    }

    public static func prettyPrintJSON<T: Encodable>(for value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    private static func extractTypeIdentifier(from container: ATProtocolValueContainer) -> String {
        switch container {
        case .unknownType(let typeName, _):
            return typeName
        case .object(let dict):
            if case .string(let typeName)? = dict["$type"] {
                return typeName
            }
            return "unknown"
        case .knownType(let value):
            let typeID = Swift.type(of: value).typeIdentifier
            return typeID.isEmpty ? String(describing: Swift.type(of: value)) : typeID
        default:
            return "unknown"
        }
    }

    private static func shortFallbackTitle(for typeIdentifier: String) -> String {
        if let hashIndex = typeIdentifier.lastIndex(of: "#") {
            let fragment = String(typeIdentifier[typeIdentifier.index(after: hashIndex)...])
            if !fragment.isEmpty {
                return fragment
            }
        }
        if let dotIndex = typeIdentifier.lastIndex(of: ".") {
            let suffix = String(typeIdentifier[typeIdentifier.index(after: dotIndex)...])
            if !suffix.isEmpty {
                return suffix
            }
        }
        return typeIdentifier == "unknown" ? "Unknown Preference" : typeIdentifier
    }
}

// MARK: - Per-Account Observable Read-Only Store

@MainActor
@Observable
public final class PrivateAppStateModel {
    public private(set) var resultsByDID: [String: PrivateAppStateResult] = [:]
    public private(set) var loadingDIDs: Set<String> = []
    public private(set) var checkedAtByDID: [String: Date] = [:]

    private let service: PrivateAppStateService
    private let now: @Sendable () -> Date
    private var generationByDID: [String: Int] = [:]

    public init(
        service: PrivateAppStateService = PrivateAppStateService(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.now = now
    }

    public func result(for accountDID: String) -> PrivateAppStateResult? {
        resultsByDID[accountDID]
    }

    public func isLoading(for accountDID: String) -> Bool {
        loadingDIDs.contains(accountDID)
    }

    public func checkedAt(for accountDID: String) -> Date? {
        checkedAtByDID[accountDID]
    }

    public func accessClassification(for accountDID: String) -> AccessClassification {
        .privateAppState(
            provider: PrivateAppStateService.providerID,
            accountDID: accountDID
        )
    }

    public func load(account: AccountStore.Account) async {
        let did = account.id
        let generation = (generationByDID[did] ?? 0) &+ 1
        generationByDID[did] = generation
        loadingDIDs.insert(did)

        defer {
            if generationByDID[did] == generation {
                loadingDIDs.remove(did)
            }
        }

        let fetched = await service.fetchPreferences(for: account)
        guard !Task.isCancelled, generationByDID[did] == generation else { return }

        resultsByDID[did] = fetched
        checkedAtByDID[did] = now()
    }
}
