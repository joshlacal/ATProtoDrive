//
//  SpacePolicyEditorSheet.swift
//  ATProtoDrive
//

import Foundation
import Petrel
import SwiftUI
#if os(macOS)
import AppKit
#endif

public struct SpacePolicyEditorSheet: View {
    public enum PolicyKind: String, CaseIterable, Identifiable, Sendable {
        case personal
        case memberList

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .personal: return "Personal Space"
            case .memberList: return "Member List Policy"
            }
        }

        public var summary: String {
            switch self {
            case .personal:
                return "Only your account and authorized apps can access records in this Space."
            case .memberList:
                return "Permissions are controlled by an explicit member list, with optional public read/write flags and allowed OAuth app restrictions."
            }
        }
    }

    @Environment(\.dismiss) private var dismiss

    public let space: SpaceItem
    public let currentPolicy: SpacePolicySummary?
    public let account: AccountStore.Account
    public let model: SpaceDetailModel
    public var onSaved: (() -> Void)?

    @State private var policyKind: PolicyKind
    @State private var publicRead: Bool
    @State private var publicWrite: Bool
    @State private var publishPolicy: Bool
    @State private var publishMembers: Bool
    @State private var allowedAppsText: String
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    public init(
        space: SpaceItem,
        currentPolicy: SpacePolicySummary?,
        account: AccountStore.Account,
        model: SpaceDetailModel,
        onSaved: (() -> Void)? = nil
    ) {
        self.space = space
        self.currentPolicy = currentPolicy
        self.account = account
        self.model = model
        self.onSaved = onSaved

        switch currentPolicy {
        case .personal:
            _policyKind = State(initialValue: .personal)
            _publicRead = State(initialValue: false)
            _publicWrite = State(initialValue: false)
            _publishPolicy = State(initialValue: false)
            _publishMembers = State(initialValue: false)
            _allowedAppsText = State(initialValue: "")
        case let .memberList(pubRead, pubWrite, apps, pubPolicy, pubMembers):
            _policyKind = State(initialValue: .memberList)
            _publicRead = State(initialValue: pubRead)
            _publicWrite = State(initialValue: pubWrite)
            _publishPolicy = State(initialValue: pubPolicy)
            _publishMembers = State(initialValue: pubMembers)
            _allowedAppsText = State(initialValue: apps.joined(separator: "\n"))
        case .managed, .other, nil:
            _policyKind = State(initialValue: .memberList)
            _publicRead = State(initialValue: false)
            _publicWrite = State(initialValue: false)
            _publishPolicy = State(initialValue: false)
            _publishMembers = State(initialValue: false)
            _allowedAppsText = State(initialValue: "")
        }
    }

    private var parsedAllowedApps: [String] {
        EditableSpacePolicy.parseAllowedApps(from: allowedAppsText)
    }

    private var invalidAllowedAppURI: String? {
        guard policyKind == .memberList else { return nil }
        return parsedAllowedApps.first(where: { !URI.isValidURI($0) })
    }

    private var omitsATProtoDriveClient: Bool {
        guard policyKind == .memberList else { return false }
        let apps = parsedAllowedApps
        guard !apps.isEmpty else { return false }
        return !apps.contains(AccountStore.cabClientId) && !apps.contains(AccountStore.publicClientId)
    }

    private var managedSpaceApp: String? {
        if case let .managed(managingApp, _) = currentPolicy {
            return managingApp
        }
        return nil
    }

    private var willDiscardMemberList: Bool {
        if case .memberList = currentPolicy, policyKind == .personal {
            return true
        }
        return false
    }

    private var editedPolicy: EditableSpacePolicy {
        switch policyKind {
        case .personal:
            return .personal
        case .memberList:
            return .memberList(
                publicRead: publicRead,
                publicWrite: publicWrite,
                allowedApps: parsedAllowedApps,
                publishPolicy: publishPolicy,
                publishMembers: publishMembers
            )
        }
    }

    private var canSave: Bool {
        !isSubmitting
            && space.isOwnAuthority
            && account.id == space.authorityDID
            && invalidAllowedAppURI == nil
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Edit Space Policy")
                        .font(.headline)
                    Text("\(space.spaceType) / \(space.skey)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding()

            Divider()

            Form {
                if let managingApp = managedSpaceApp {
                    Section {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Currently Managed by External App")
                                    .font(.subheadline.weight(.semibold))
                                Text("This Space is currently managed by \(managingApp). Saving a new policy replaces the managed policy and disconnects that app's access checks.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section {
                    Picker("Policy Type", selection: $policyKind) {
                        ForEach(PolicyKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .pickerStyle(.radioGroup)

                    Text(policyKind.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if willDiscardMemberList {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Switching from Member List Policy to Personal Space discards the existing member list on the server.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Policy")
                        .font(.subheadline.bold())
                } footer: {
                    Text("Space policies control server-enforced read and write permissions for authority \(space.authorityDID).")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if policyKind == .memberList {
                    Section {
                        Toggle("Public Read", isOn: $publicRead)
                        Text("Allow any account to read records in this Space without being listed as a member.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Public Write", isOn: $publicWrite)
                        Text("Allow any account's writes to be tracked in this Space unless explicitly denied on the member list.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Open Access Flags")
                            .font(.subheadline.bold())
                    }

                    Section {
                        Toggle("Publish Policy Record", isOn: $publishPolicy)
                        Text("Publish this policy as a com.atproto.space.policy record inside the Space.")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        Toggle("Publish Member List", isOn: $publishMembers)
                        Text("Publish members as com.atproto.memberspace.member records inside the Space.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } header: {
                        Text("Publication")
                            .font(.subheadline.bold())
                    }

                    Section {
                        TextEditor(text: $allowedAppsText)
                            .font(.system(.caption, design: .monospaced))
                            .scrollContentBackground(.hidden)
                            .padding(6)
                            .background(editorBackgroundColor)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(
                                        invalidAllowedAppURI != nil ? Color.red.opacity(0.75) : Color.secondary.opacity(0.25),
                                        lineWidth: 1
                                    )
                            )
                            .frame(minHeight: 74)

                        if let invalidURI = invalidAllowedAppURI {
                            Label("Invalid URI: \(invalidURI)", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }

                        if omitsATProtoDriveClient {
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(.orange)
                                Text("ATProtoDrive's OAuth client ID is not in Allowed Apps; reading writers via Space credentials from this app may be restricted.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Text("Allowed Apps (Optional)")
                            .font(.subheadline.bold())
                    } footer: {
                        Text("Enter OAuth client ID URIs separated by commas or new lines (for example, https://example.com/oauth-client-metadata.json). Leave empty to allow all apps.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            if let errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.leading)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.red.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal)
                .padding(.bottom, 8)
            }

            Divider()

            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .padding(.trailing, 4)
                }

                Button("Save Policy") {
                    Task {
                        await submit()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canSave)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 480, idealWidth: 540, minHeight: 460, idealHeight: 560)
    }

    private var editorBackgroundColor: Color {
        #if os(macOS)
        Color(NSColor.textBackgroundColor)
        #else
        Color.secondary.opacity(0.08)
        #endif
    }

    private func submit() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await model.updateSpacePolicy(
                space: space,
                policy: editedPolicy,
                account: account
            )
            onSaved?()
            dismiss()
        } catch {
            if let xrpc = error as? ATProtoXRPCError {
                errorMessage = xrpc.errorDescription ?? xrpc.error
            } else {
                errorMessage = error.localizedDescription
            }
        }
    }
}
