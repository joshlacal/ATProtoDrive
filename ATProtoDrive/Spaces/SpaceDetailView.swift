//
//  SpaceDetailView.swift
//  ATProtoDrive
//

import SwiftUI
import Petrel

public struct SpaceDetailView: View {
    let space: SpaceItem
    let account: AccountStore.Account?
    @State private var model = SpaceDetailModel()

    public init(space: SpaceItem, account: AccountStore.Account?) {
        self.space = space
        self.account = account
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                if account == nil {
                    ContentUnavailableView(
                        "No Active Account",
                        systemImage: "person.crop.circle.badge.exclamationmark",
                        description: Text("Sign in with an active account to load space details.")
                    )
                    .padding(.top, 24)
                } else if model.isLoading && model.repos.isEmpty && model.errorState == nil {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Loading space details…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 32)
                } else if let errorState = model.errorState {
                    errorStateView(errorState)
                } else {
                    reposSection

                    if let members = model.members {
                        Divider()
                        membersSection(members)
                    }
                }
            }
            .padding()
        }
        .navigationTitle(space.skey)
        .task(id: "\(space.id.uriString())-\(account?.id ?? "")") {
            if let account {
                await model.load(space: space, account: account)
            }
        }
        .refreshable {
            if let account {
                await model.load(space: space, account: account)
            }
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(space.skey)
                    .font(.title2.bold())
                Spacer()
                Text(space.isOwnAuthority ? "Owned Space" : "Shared Space")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(space.isOwnAuthority ? Color.blue.opacity(0.15) : Color.purple.opacity(0.15))
                    .foregroundStyle(space.isOwnAuthority ? .blue : .purple)
                    .clipShape(Capsule())
            }

            Text(space.spaceType)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Authority", value: space.authorityDID)
                LabeledContent("Type", value: space.spaceType)
                LabeledContent("Key", value: space.skey)
                LabeledContent("URI", value: space.ref.uriString())
            }
            .font(.caption)
            .padding(.top, 4)
        }
    }

    // MARK: - Error State Views

    @ViewBuilder
    private func errorStateView(_ errorState: SpaceDetailModel.ErrorState) -> some View {
        switch errorState {
        case .tombstone(let message):
            ContentUnavailableView {
                Label("Space Deleted", systemImage: "trash.slash.fill")
            } description: {
                Text("This space has been deleted by its authority.")
            } actions: {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)

        case .reconsentNeeded(let message):
            ContentUnavailableView {
                Label("Re-consent Required", systemImage: "lock.trianglebadge.exclamationmark.fill")
            } description: {
                Text("Your account requires updated authorization scopes to access this space.")
            } actions: {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 24)

        case .general(let message):
            VStack(spacing: 12) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)

                if let account {
                    Button("Retry") {
                        Task {
                            await model.load(space: space, account: account)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
        }
    }

    // MARK: - Repos Section

    private var reposSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Writer Repos")
                    .font(.headline)
                Spacer()
                Text("\(model.repos.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if model.repos.isEmpty {
                Text("No repos have written to this space yet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 8) {
                    ForEach(model.repos) { repo in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(repo.did)
                                .font(.system(.body, design: .monospaced))

                            HStack(spacing: 12) {
                                Label(repo.rev, systemImage: "clock.arrow.circlepath")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)

                                Label(repo.hash, systemImage: "number")
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }

    // MARK: - Members Section

    private func membersSection(_ members: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Members")
                    .font(.headline)
                Spacer()
                Text("\(members.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if members.isEmpty {
                Text("No members in this space.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 6) {
                    ForEach(members, id: \.self) { memberDID in
                        HStack(spacing: 8) {
                            Image(systemName: "person.circle.fill")
                                .foregroundStyle(.secondary)
                            Text(memberDID)
                                .font(.system(.body, design: .monospaced))
                            Spacer()
                        }
                        .padding(8)
                        .background(Color.secondary.opacity(0.08))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
        }
    }
}
