//
//  PublicCrudAndSpacePolicyTests.swift
//  ATProtoDriveTests
//

import Foundation
import Petrel
import SwiftUI
import Testing
@testable import ATProtoDrive

private actor MutationSpy<Input: Sendable> {
    private(set) var inputs: [Input] = []

    func record(_ input: Input) {
        inputs.append(input)
    }

    var count: Int { inputs.count }
    var last: Input? { inputs.last }
}

@Suite("Public Repo CRUD and Space Policy Administration Tests")
struct PublicCrudAndSpacePolicyTests {
    private static let aliceDID = "did:plc:4hqjfn7m6n5hno3doamuhgef"
    private static let bobDID = "did:plc:z72i7hdynmk6r22z27h6tvur"
    private static let sampleCID1 = "bafyreigcxd76a5xqjzw2l6fq3u7d26hjtybdslqj2kxlzpvfyrvhycbr2a"
    private static let sampleCID2 = "bafyreif7h6gxlc6kpxthfclr3vkqffn4yixoqmmqr7m2kq4xfacgjnlvhm"

    private func makeTestAccount(
        id: String = PublicCrudAndSpacePolicyTests.aliceDID,
        handle: String = "alice.test"
    ) async -> AccountStore.Account {
        let client = await ATProtoClient(baseURL: URL(string: "https://example.com")!)
        let resolver = SpaceHostResolver(didResolver: ClientDIDResolver(client: client))
        let creds = SpaceCredentialManager(client: client, resolver: resolver)
        return AccountStore.Account(
            id: id,
            handle: handle,
            client: client,
            credentials: creds,
            authMode: .cab
        )
    }

    // MARK: - 1. Public Repo Owner-Only Guard & View Gating

    @Test("PublicRecordMutationService rejects create, update, and delete for foreign repository DID without invoking transport")
    func testOwnerOnlyRejectionOnForeignDID() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID, handle: "alice.test")
        let createSpy = MutationSpy<ComAtprotoRepoCreateRecord.Input>()
        let putSpy = MutationSpy<ComAtprotoRepoPutRecord.Input>()
        let deleteSpy = MutationSpy<ComAtprotoRepoDeleteRecord.Input>()

        let service = PublicRecordMutationService(
            operations: .init(
                createRecord: { _, input in
                    await createSpy.record(input)
                    return (200, nil)
                },
                putRecord: { _, input in
                    await putSpy.record(input)
                    return (200, nil)
                },
                deleteRecord: { _, input in
                    await deleteSpy.record(input)
                    return (200, nil)
                }
            )
        )

        await #expect(throws: PublicRecordMutationError.notRepositoryOwner(
            accountDID: Self.aliceDID,
            targetRepoDID: Self.bobDID
        )) {
            _ = try await service.createRecord(
                targetRepoDID: Self.bobDID,
                collection: "app.bsky.feed.post",
                rkey: "post1",
                json: #"{"text":"hello"}"#,
                account: alice
            )
        }

        await #expect(throws: PublicRecordMutationError.notRepositoryOwner(
            accountDID: Self.aliceDID,
            targetRepoDID: Self.bobDID
        )) {
            _ = try await service.updateRecord(
                targetRepoDID: Self.bobDID,
                collection: "app.bsky.feed.post",
                rkey: "post1",
                expectedCID: Self.sampleCID1,
                json: #"{"text":"updated"}"#,
                account: alice
            )
        }

        await #expect(throws: PublicRecordMutationError.notRepositoryOwner(
            accountDID: Self.aliceDID,
            targetRepoDID: Self.bobDID
        )) {
            _ = try await service.deleteRecord(
                targetRepoDID: Self.bobDID,
                collection: "app.bsky.feed.post",
                rkey: "post1",
                expectedCID: Self.sampleCID1,
                account: alice
            )
        }

        #expect(await createSpy.count == 0)
        #expect(await putSpy.count == 0)
        #expect(await deleteSpy.count == 0)
    }

    @Test("PublicRecordPresentation.isWriteEnabled enables writes only for matching repository owner")
    func testWriteEnablementGating() async {
        let aliceRepo = ResolvedRepository.fixture
        let aliceAccount = await makeTestAccount(id: aliceRepo.did, handle: "alice.test")
        let bobAccount = await makeTestAccount(id: Self.bobDID, handle: "bob.test")

        #expect(PublicRecordPresentation.isWriteEnabled(repository: aliceRepo, owningAccount: nil) == false)
        #expect(PublicRecordPresentation.isWriteEnabled(repository: aliceRepo, owningAccount: bobAccount) == false)
        #expect(PublicRecordPresentation.isWriteEnabled(repository: aliceRepo, owningAccount: aliceAccount) == true)
    }

    @MainActor
    @Test("PublicRecordTable and PublicRepositoryView keep backwards-compatible initializers without AccountStore environment")
    func testPublicViewsBackwardsCompatibleInit() async {
        let service = ScriptedPublicRepositoryService.successfulFixture()
        let repoStore = PublicRepositoryStore(service: service)
        let recordStore = PublicRecordStore(
            service: service,
            repository: .fixture,
            collection: "app.bsky.feed.post"
        )
        let session = BrowserSession()
        let aliceAccount = await makeTestAccount(id: ResolvedRepository.fixture.did)

        let readOnlyTable = PublicRecordTable(store: recordStore, session: session)
        let ownerTable = PublicRecordTable(store: recordStore, session: session, owningAccount: aliceAccount)
        let readOnlyRepoView = PublicRepositoryView(session: session, store: repoStore)
        let ownerRepoView = PublicRepositoryView(session: session, store: repoStore, owningAccount: aliceAccount)

        #expect(readOnlyTable.owningAccount == nil)
        #expect(ownerTable.owningAccount?.id == ResolvedRepository.fixture.did)
        #expect(readOnlyRepoView.owningAccount == nil)
        #expect(ownerRepoView.owningAccount?.id == ResolvedRepository.fixture.did)
    }

    // MARK: - 2. Public Repo JSON Validation & CRUD + CAS

    @Test("PublicRecordMutationService validates JSON root object and enforces $type matching collection")
    func testPublicJSONValidation() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)
        let createSpy = MutationSpy<ComAtprotoRepoCreateRecord.Input>()
        let service = PublicRecordMutationService(
            operations: .init(
                createRecord: { _, input in
                    await createSpy.record(input)
                    return (200, nil)
                }
            )
        )

        // Non-object root rejected
        do {
            _ = try await service.createRecord(
                targetRepoDID: Self.aliceDID,
                collection: "app.bsky.feed.post",
                json: "[1, 2, 3]",
                account: alice
            )
            Issue.record("Expected non-object JSON to fail validation")
        } catch let error as PublicRecordMutationError {
            guard case .invalidJSON = error else {
                Issue.record("Expected invalidJSON, got \(error)")
                return
            }
        }

        // Mismatched $type rejected
        do {
            _ = try await service.createRecord(
                targetRepoDID: Self.aliceDID,
                collection: "app.bsky.feed.post",
                json: #"{"$type":"app.bsky.actor.profile","displayName":"Alice"}"#,
                account: alice
            )
            Issue.record("Expected mismatched $type to fail validation")
        } catch let error as PublicRecordMutationError {
            guard case .invalidJSON(let message) = error else {
                Issue.record("Expected invalidJSON, got \(error)")
                return
            }
            #expect(message.contains("does not match collection"))
        }

        #expect(await createSpy.count == 0)

        // Missing $type is auto-injected to match collection
        let validInput = try PublicRecordMutationService.makeCreateRecordInput(
            targetRepoDID: Self.aliceDID,
            collection: "app.bsky.feed.post",
            rkey: nil,
            json: #"{"text":"Public note"}"#,
            accountDID: Self.aliceDID
        )
        let pretty = RecordListModel.formatPrettyJSON(from: validInput.record)
        #expect(pretty.contains("\"$type\" : \"app.bsky.feed.post\""))
        #expect(pretty.contains("Public note"))
    }

    @Test("createRecord sends com.atproto.repo.createRecord and returns URI, CID, and commit metadata")
    func testPublicCreateRecord() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)
        let spy = MutationSpy<ComAtprotoRepoCreateRecord.Input>()
        let expectedURI = try ATProtocolURI(uriString: "at://\(Self.aliceDID)/app.bsky.feed.post/post1")
        let expectedCID = try CIDString(cidString: Self.sampleCID1)
        let commitMeta = ComAtprotoRepoDefs.CommitMeta(
            cid: try CIDString(cidString: Self.sampleCID2),
            rev: try TID(tidString: "3l3vbfz2zsk22")
        )

        let service = PublicRecordMutationService(
            operations: .init(
                createRecord: { account, input in
                    #expect(account.id == Self.aliceDID)
                    await spy.record(input)
                    return (
                        200,
                        ComAtprotoRepoCreateRecord.Output(
                            uri: expectedURI,
                            cid: expectedCID,
                            commit: commitMeta,
                            validationStatus: "valid"
                        )
                    )
                }
            )
        )

        let result = try await service.createRecord(
            targetRepoDID: Self.aliceDID,
            collection: "app.bsky.feed.post",
            rkey: "post1",
            json: #"{"text":"Hello world"}"#,
            account: alice
        )

        #expect(await spy.count == 1)
        let sent = try #require(await spy.last)
        #expect(sent.repo.description == Self.aliceDID)
        #expect(sent.collection.description == "app.bsky.feed.post")
        #expect(sent.rkey?.description == "post1")

        #expect(result.uri == expectedURI.description)
        #expect(result.cid == Self.sampleCID1)
        #expect(result.commitCID == Self.sampleCID2)
        #expect(result.commitRev == "3l3vbfz2zsk22")
        #expect(result.validationStatus == "valid")
    }

    @Test("updateRecord passes atomic CAS swapRecord CID on putRecord and encodes swapRecord on wire")
    func testPublicUpdateRecordPassesSwapRecordCAS() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)
        let spy = MutationSpy<ComAtprotoRepoPutRecord.Input>()
        let updatedURI = try ATProtocolURI(uriString: "at://\(Self.aliceDID)/app.bsky.feed.post/post1")
        let updatedCID = try CIDString(cidString: Self.sampleCID2)

        let service = PublicRecordMutationService(
            operations: .init(
                putRecord: { _, input in
                    await spy.record(input)
                    return (
                        200,
                        ComAtprotoRepoPutRecord.Output(uri: updatedURI, cid: updatedCID)
                    )
                }
            )
        )

        let result = try await service.updateRecord(
            targetRepoDID: Self.aliceDID,
            collection: "app.bsky.feed.post",
            rkey: "post1",
            expectedCID: Self.sampleCID1,
            json: #"{"$type":"app.bsky.feed.post","text":"Edited"}"#,
            account: alice
        )

        #expect(result.cid == Self.sampleCID2)
        let sent = try #require(await spy.last)
        #expect(sent.repo.description == Self.aliceDID)
        #expect(sent.collection.description == "app.bsky.feed.post")
        #expect(sent.rkey.description == "post1")
        #expect(sent.swapRecord == .value(try CIDString(cidString: Self.sampleCID1)))

        let encoded = try JSONEncoder().encode(sent)
        let jsonObject = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(jsonObject["swapRecord"] as? String == Self.sampleCID1)
    }

    @Test("deleteRecord passes atomic CAS swapRecord CID on deleteRecord and encodes swapRecord on wire")
    func testPublicDeleteRecordPassesSwapRecordCAS() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)
        let spy = MutationSpy<ComAtprotoRepoDeleteRecord.Input>()
        let commitMeta = ComAtprotoRepoDefs.CommitMeta(
            cid: try CIDString(cidString: Self.sampleCID2),
            rev: try TID(tidString: "3l3vbfz2zsk77")
        )

        let service = PublicRecordMutationService(
            operations: .init(
                deleteRecord: { _, input in
                    await spy.record(input)
                    return (200, ComAtprotoRepoDeleteRecord.Output(commit: commitMeta))
                }
            )
        )

        let result = try await service.deleteRecord(
            targetRepoDID: Self.aliceDID,
            collection: "app.bsky.feed.post",
            rkey: "post1",
            expectedCID: Self.sampleCID1,
            account: alice
        )

        #expect(result.commitCID == Self.sampleCID2)
        #expect(result.commitRev == "3l3vbfz2zsk77")

        let sent = try #require(await spy.last)
        #expect(sent.repo.description == Self.aliceDID)
        #expect(sent.collection.description == "app.bsky.feed.post")
        #expect(sent.rkey.description == "post1")
        #expect(sent.swapRecord == (try CIDString(cidString: Self.sampleCID1)))

        let encoded = try JSONEncoder().encode(sent)
        let jsonObject = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(jsonObject["swapRecord"] as? String == Self.sampleCID1)
    }

    @Test("InvalidSwap (400) from putRecord and deleteRecord maps to conflictDetected")
    func testInvalidSwapMapsToConflictDetected() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)

        // 1. Typed ATProtoError<ComAtprotoRepoPutRecord.Error>.invalidSwap
        let typedPutService = PublicRecordMutationService(
            operations: .init(
                putRecord: { _, _ in
                    throw ATProtoError<ComAtprotoRepoPutRecord.Error>(
                        error: .invalidSwap,
                        message: "Record was at \(Self.sampleCID2)",
                        statusCode: 400
                    )
                }
            )
        )

        do {
            _ = try await typedPutService.updateRecord(
                targetRepoDID: Self.aliceDID,
                collection: "app.bsky.feed.post",
                rkey: "post1",
                expectedCID: Self.sampleCID1,
                json: #"{"text":"stale write"}"#,
                account: alice
            )
            Issue.record("Expected conflictDetected on typed putRecord InvalidSwap")
        } catch let error as PublicRecordMutationError {
            guard case .conflictDetected(let message) = error else {
                Issue.record("Expected conflictDetected, got \(error)")
                return
            }
            #expect(message.contains(Self.sampleCID2))
        }

        // 2. Typed ATProtoError<ComAtprotoRepoDeleteRecord.Error>.invalidSwap
        let typedDeleteService = PublicRecordMutationService(
            operations: .init(
                deleteRecord: { _, _ in
                    throw ATProtoError<ComAtprotoRepoDeleteRecord.Error>(
                        error: .invalidSwap,
                        message: "Current CID differs",
                        statusCode: 400
                    )
                }
            )
        )

        do {
            _ = try await typedDeleteService.deleteRecord(
                targetRepoDID: Self.aliceDID,
                collection: "app.bsky.feed.post",
                rkey: "post1",
                expectedCID: Self.sampleCID1,
                account: alice
            )
            Issue.record("Expected conflictDetected on typed deleteRecord InvalidSwap")
        } catch let error as PublicRecordMutationError {
            guard case .conflictDetected(let message) = error else {
                Issue.record("Expected conflictDetected, got \(error)")
                return
            }
            #expect(message.contains("Current CID differs"))
        }

        // 3. Generic ATProtoXRPCError("InvalidSwap", 400)
        let genericService = PublicRecordMutationService(
            operations: .init(
                putRecord: { _, _ in
                    throw ATProtoXRPCError(
                        error: "InvalidSwap",
                        message: "Concurrent edit detected",
                        statusCode: 400
                    )
                }
            )
        )

        do {
            _ = try await genericService.updateRecord(
                targetRepoDID: Self.aliceDID,
                collection: "app.bsky.feed.post",
                rkey: "post1",
                expectedCID: Self.sampleCID1,
                json: #"{"text":"stale"}"#,
                account: alice
            )
            Issue.record("Expected conflictDetected on generic InvalidSwap XRPC error")
        } catch let error as PublicRecordMutationError {
            guard case .conflictDetected(let message) = error else {
                Issue.record("Expected conflictDetected, got \(error)")
                return
            }
            #expect(message.contains("Concurrent edit detected"))
        }
    }

    // MARK: - 3. Space Policy Administration Tests

    @Test("EditableSpacePolicy.parseAllowedApps handles comma and newline separators, trimming, and deduplication")
    func testParseAllowedApps() {
        let raw = """
          https://catbird.blue/oauth-client-metadata.json,  https://atprotodrive.catbird.blue/oauth-client-metadata.json
        
        https://catbird.blue/oauth-client-metadata.json
        https://other.example/client.json ,
        """
        let parsed = EditableSpacePolicy.parseAllowedApps(from: raw)
        #expect(parsed == [
            "https://catbird.blue/oauth-client-metadata.json",
            "https://atprotodrive.catbird.blue/oauth-client-metadata.json",
            "https://other.example/client.json"
        ])
    }

    @Test("makeUpdateSpaceInput encodes Personal policy and rejects foreign spaces")
    func testMakeUpdateSpaceInputPersonalAndAuthorityGuard() throws {
        let ownSpace = try SpaceItem(
            uriString: "at://\(Self.aliceDID)/space/space.swan.drive/self",
            accountDID: Self.aliceDID
        )
        let input = try SpaceDetailModel.makeUpdateSpaceInput(space: ownSpace, policy: .personal)

        #expect(input.space.uriString() == ownSpace.ref.uriString())
        guard case .comAtprotoPersonalspacePolicy = input.policy else {
            Issue.record("Expected comAtprotoPersonalspacePolicy")
            return
        }

        let data = try JSONEncoder().encode(input)
        let jsonObject = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let policyObject = try #require(jsonObject["policy"] as? [String: Any])
        #expect(policyObject["$type"] as? String == "com.atproto.personalspace.policy")

        // Foreign space MUST be rejected
        let foreignSpace = try SpaceItem(
            uriString: "at://\(Self.bobDID)/space/space.swan.drive/shared",
            accountDID: Self.aliceDID
        )
        #expect(throws: SpaceAdminError.notSpaceAuthority(
            accountDID: Self.aliceDID,
            authorityDID: Self.bobDID
        )) {
            _ = try SpaceDetailModel.makeUpdateSpaceInput(space: foreignSpace, policy: .personal)
        }
    }

    @Test("makeUpdateSpaceInput encodes Member List policy with all flags and allowedApps URIs")
    func testMakeUpdateSpaceInputMemberListWithFlagsAndAllowedApps() throws {
        let ownSpace = try SpaceItem(
            uriString: "at://\(Self.aliceDID)/space/space.swan.drive/team",
            accountDID: Self.aliceDID
        )
        let policy = EditableSpacePolicy.memberList(
            publicRead: true,
            publicWrite: false,
            allowedApps: [
                "https://atprotodrive.catbird.blue/oauth-client-metadata.json",
                "https://catbird.blue/oauth-client-metadata.json"
            ],
            publishPolicy: true,
            publishMembers: true
        )

        let input = try SpaceDetailModel.makeUpdateSpaceInput(space: ownSpace, policy: policy)
        let data = try JSONEncoder().encode(input)
        let jsonObject = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let policyObject = try #require(jsonObject["policy"] as? [String: Any])

        #expect(policyObject["$type"] as? String == "com.atproto.memberspace.policy")
        #expect(policyObject["publicRead"] as? Bool == true)
        #expect(policyObject["publicWrite"] as? Bool == false)
        #expect(policyObject["publishPolicy"] as? Bool == true)
        #expect(policyObject["publishMembers"] as? Bool == true)
        #expect(policyObject["allowedApps"] as? [String] == [
            "https://atprotodrive.catbird.blue/oauth-client-metadata.json",
            "https://catbird.blue/oauth-client-metadata.json"
        ])

        // Empty allowedApps omits the allowedApps key so all apps are permitted
        let openAppsInput = try SpaceDetailModel.makeUpdateSpaceInput(
            space: ownSpace,
            policy: .memberList(
                publicRead: false,
                publicWrite: false,
                allowedApps: [],
                publishPolicy: false,
                publishMembers: false
            )
        )
        let openData = try JSONEncoder().encode(openAppsInput)
        let openObject = try #require(try JSONSerialization.jsonObject(with: openData) as? [String: Any])
        let openPolicy = try #require(openObject["policy"] as? [String: Any])
        #expect(openPolicy["allowedApps"] == nil)

        // Invalid URI rejected
        #expect(throws: SpaceAdminError.invalidAllowedAppURI("not a valid uri")) {
            _ = try SpaceDetailModel.makeUpdateSpaceInput(
                space: ownSpace,
                policy: .memberList(
                    publicRead: false,
                    publicWrite: false,
                    allowedApps: ["not a valid uri"],
                    publishPolicy: false,
                    publishMembers: false
                )
            )
        }
    }

    @MainActor
    @Test("updateSpacePolicy sends com.atproto.space.updateSpace and updates policySummary")
    func testUpdateSpacePolicyUpdatesPolicySummary() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)
        let ownSpace = try SpaceItem(
            uriString: "at://\(Self.aliceDID)/space/space.swan.drive/team",
            accountDID: Self.aliceDID
        )
        let spy = MutationSpy<ComAtprotoSpaceUpdateSpace.Input>()
        let model = SpaceDetailModel(
            members: [Self.bobDID],
            memberEntries: [SpaceMemberEntry(did: Self.bobDID, read: true, write: false)],
            policySummary: .personal
        )

        let memberPolicy = EditableSpacePolicy.memberList(
            publicRead: true,
            publicWrite: false,
            allowedApps: ["https://catbird.blue/oauth-client-metadata.json"],
            publishPolicy: true,
            publishMembers: false
        )

        try await model.updateSpacePolicy(
            space: ownSpace,
            policy: memberPolicy,
            account: alice,
            transport: { input in
                await spy.record(input)
                return 200
            }
        )

        #expect(await spy.count == 1)
        #expect(model.policySummary == .memberList(
            publicRead: true,
            publicWrite: false,
            allowedApps: ["https://catbird.blue/oauth-client-metadata.json"],
            publishPolicy: true,
            publishMembers: false
        ))

        // Switching back to Personal updates policySummary and clears member lists
        try await model.updateSpacePolicy(
            space: ownSpace,
            policy: .personal,
            account: alice,
            transport: { input in
                await spy.record(input)
                return 200
            }
        )

        #expect(await spy.count == 2)
        #expect(model.policySummary == .personal)
        #expect(model.members == nil)
        #expect(model.memberEntries == nil)
    }

    // MARK: - 4. Space Member Permission Administration Tests

    @MainActor
    @Test("updateMemberPermissions sends putMembers with updated read/write flags and updates memberEntries")
    func testUpdateMemberPermissionsUpdatesMemberEntries() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)
        let ownSpace = try SpaceItem(
            uriString: "at://\(Self.aliceDID)/space/space.swan.drive/team",
            accountDID: Self.aliceDID
        )
        let spy = MutationSpy<ComAtprotoMemberspacePutMembers.Input>()
        let model = SpaceDetailModel(
            members: [Self.bobDID],
            memberEntries: [SpaceMemberEntry(did: Self.bobDID, read: true, write: true)],
            policySummary: .memberList(
                publicRead: false,
                publicWrite: false,
                allowedApps: [],
                publishPolicy: false,
                publishMembers: false
            )
        )

        try await model.updateMemberPermissions(
            did: Self.bobDID,
            read: true,
            write: false,
            space: ownSpace,
            account: alice,
            transport: { input in
                await spy.record(input)
                return 200
            }
        )

        #expect(await spy.count == 1)
        let sent = try #require(await spy.last)
        #expect(sent.space.uriString() == ownSpace.ref.uriString())
        #expect(sent.members.count == 1)
        let sentMember = try #require(sent.members.first)
        #expect(sentMember.did.description == Self.bobDID)
        #expect(sentMember.read == true)
        #expect(sentMember.write == false)

        #expect(model.memberEntries == [SpaceMemberEntry(did: Self.bobDID, read: true, write: false)])
        #expect(model.members == [Self.bobDID])
    }

    @MainActor
    @Test("updateMemberPermissions rejects foreign spaces and invalid DIDs without calling transport")
    func testUpdateMemberPermissionsValidationAndAuthorityGuard() async throws {
        let alice = await makeTestAccount(id: Self.aliceDID)
        let foreignSpace = try SpaceItem(
            uriString: "at://\(Self.bobDID)/space/space.swan.drive/team",
            accountDID: Self.aliceDID
        )
        let ownSpace = try SpaceItem(
            uriString: "at://\(Self.aliceDID)/space/space.swan.drive/team",
            accountDID: Self.aliceDID
        )
        let spy = MutationSpy<ComAtprotoMemberspacePutMembers.Input>()
        let model = SpaceDetailModel()

        await #expect(throws: SpaceAdminError.notSpaceAuthority(
            accountDID: Self.aliceDID,
            authorityDID: Self.bobDID
        )) {
            try await model.updateMemberPermissions(
                did: Self.bobDID,
                read: true,
                write: false,
                space: foreignSpace,
                account: alice,
                transport: { input in
                    await spy.record(input)
                    return 200
                }
            )
        }

        await #expect(throws: SpaceAdminError.invalidMemberDID("not-a-did")) {
            try await model.updateMemberPermissions(
                did: "not-a-did",
                read: true,
                write: false,
                space: ownSpace,
                account: alice,
                transport: { input in
                    await spy.record(input)
                    return 200
                }
            )
        }

        #expect(await spy.count == 0)
    }
}
