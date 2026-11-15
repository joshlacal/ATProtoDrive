import Foundation
import Petrel

public extension PublicRepositoryService {
    struct Operations: Sendable {
        public let resolveHandle: @Sendable (String) async throws -> (
            responseCode: Int,
            data: ComAtprotoIdentityResolveHandle.Output?
        )
        public let describe: @Sendable (
            URL, ComAtprotoRepoDescribeRepo.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoDescribeRepo.Output?)
        public let listRecords: @Sendable (
            URL, ComAtprotoRepoListRecords.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoListRecords.Output?)
        public let getRecord: @Sendable (
            URL, ComAtprotoRepoGetRecord.Parameters
        ) async throws -> (responseCode: Int, data: ComAtprotoRepoGetRecord.Output?)

        public init(
            resolveHandle: @escaping @Sendable (String) async throws -> (
                responseCode: Int,
                data: ComAtprotoIdentityResolveHandle.Output?
            ),
            describe: @escaping @Sendable (
                URL, ComAtprotoRepoDescribeRepo.Parameters
            ) async throws -> (responseCode: Int, data: ComAtprotoRepoDescribeRepo.Output?),
            listRecords: @escaping @Sendable (
                URL, ComAtprotoRepoListRecords.Parameters
            ) async throws -> (responseCode: Int, data: ComAtprotoRepoListRecords.Output?),
            getRecord: @escaping @Sendable (
                URL, ComAtprotoRepoGetRecord.Parameters
            ) async throws -> (responseCode: Int, data: ComAtprotoRepoGetRecord.Output?)
        ) {
            self.resolveHandle = resolveHandle
            self.describe = describe
            self.listRecords = listRecords
            self.getRecord = getRecord
        }
    }
}

public extension PublicRepositoryService.Operations {
    static let live = Self(
        resolveHandle: { handle in
            let client = await ATProtoClient(baseURL: ATProtoClient.defaultBaseURL)
            let (code, output) = try await client.com.atproto.identity.resolveHandle(
                input: .init(handle: try Handle(handleString: handle))
            )
            return (code, output)
        },
        describe: { pdsURL, params in
            let client = await ATProtoClient(baseURL: pdsURL)
            let (code, output) = try await client.com.atproto.repo.describeRepo(input: params)
            return (code, output)
        },
        listRecords: { pdsURL, params in
            let client = await ATProtoClient(baseURL: pdsURL)
            let (code, output) = try await client.com.atproto.repo.listRecords(input: params)
            return (code, output)
        },
        getRecord: { pdsURL, params in
            let client = await ATProtoClient(baseURL: pdsURL)
            let (code, output) = try await client.com.atproto.repo.getRecord(input: params)
            return (code, output)
        }
    )
}

public actor PublicRepositoryService: PublicRepositoryServing {
    private let operations: Operations
    private let pdsResolver: any DIDDocumentPDSResolving

    public init(
        operations: Operations = .live,
        pdsResolver: any DIDDocumentPDSResolving = DIDDocumentPDSResolver()
    ) {
        self.operations = operations
        self.pdsResolver = pdsResolver
    }

    private func requireOutput<Value>(
        endpoint: String,
        responseCode: Int,
        output: Value?
    ) throws -> Value {
        guard (200 ... 299).contains(responseCode) else {
            throw BrowserFailure.http(endpoint: endpoint, statusCode: responseCode)
        }
        guard let output else {
            throw BrowserFailure.decodeFailure(endpoint: endpoint, statusCode: responseCode)
        }
        return output
    }

    public func resolve(target: RepositoryTarget) async throws -> ResolvedRepository {
        switch target {
        case .connectedAccount(let rawDID):
            let did = rawDID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (try? DID(didString: did)) != nil else {
                throw BrowserFailure.invalidIdentifier(rawDID)
            }
            let pdsIdentity = try await pdsResolver.resolvePDS(for: did)
            return ResolvedRepository(
                did: pdsIdentity.did,
                handle: pdsIdentity.declaredHandle,
                pdsURL: pdsIdentity.pdsURL,
                connectedAccountDID: did,
                handleIsCorrect: nil
            )

        case .publicIdentifier(let rawInput):
            let input = rawInput.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !input.isEmpty else {
                throw BrowserFailure.invalidIdentifier(rawInput)
            }
            if input.hasPrefix("did:") {
                guard (try? DID(didString: input)) != nil else {
                    throw BrowserFailure.invalidIdentifier(rawInput)
                }
                let pdsIdentity = try await pdsResolver.resolvePDS(for: input)
                return ResolvedRepository(
                    did: pdsIdentity.did,
                    handle: pdsIdentity.declaredHandle,
                    pdsURL: pdsIdentity.pdsURL,
                    connectedAccountDID: nil,
                    handleIsCorrect: nil
                )
            } else {
                guard (try? Handle(handleString: input)) != nil else {
                    throw BrowserFailure.invalidIdentifier(rawInput)
                }
                let (code, output) = try await operations.resolveHandle(input)
                let resolveOutput = try requireOutput(
                    endpoint: "com.atproto.identity.resolveHandle",
                    responseCode: code,
                    output: output
                )
                let did = resolveOutput.did.didString()
                let pdsIdentity = try await pdsResolver.resolvePDS(for: did)
                return ResolvedRepository(
                    did: pdsIdentity.did,
                    handle: input,
                    pdsURL: pdsIdentity.pdsURL,
                    connectedAccountDID: nil,
                    handleIsCorrect: nil
                )
            }
        }
    }

    public func describe(_ repository: ResolvedRepository) async throws -> RepositoryDescription {
        let repo: ATIdentifier
        do {
            repo = try ATIdentifier(string: repository.did)
        } catch {
            throw BrowserFailure.invalidIdentifier(repository.did)
        }

        let params = ComAtprotoRepoDescribeRepo.Parameters(repo: repo)
        let (code, output) = try await operations.describe(repository.pdsURL, params)
        let describeOutput = try requireOutput(
            endpoint: "com.atproto.repo.describeRepo",
            responseCode: code,
            output: output
        )

        guard describeOutput.did.didString() == repository.did else {
            throw BrowserFailure.identityMismatch(
                expected: repository.did,
                actual: describeOutput.did.didString()
            )
        }
        guard describeOutput.didDoc.id == repository.did else {
            throw BrowserFailure.identityMismatch(
                expected: repository.did,
                actual: describeOutput.didDoc.id
            )
        }

        let validatedPDS = try await pdsResolver.validatePDSIdentity(
            from: describeOutput.didDoc,
            expectedDID: repository.did
        )

        guard validatedPDS.pdsURL == repository.pdsURL else {
            throw BrowserFailure.identityMismatch(
                expected: repository.pdsURL.absoluteString,
                actual: validatedPDS.pdsURL.absoluteString
            )
        }

        var seen = Set<String>()
        var uniqueCollections: [String] = []
        for col in describeOutput.collections {
            let colString = col.description
            if seen.insert(colString).inserted {
                uniqueCollections.append(colString)
            }
        }

        let updatedRepo = ResolvedRepository(
            did: repository.did,
            handle: describeOutput.handle.description,
            pdsURL: repository.pdsURL,
            connectedAccountDID: repository.connectedAccountDID,
            handleIsCorrect: describeOutput.handleIsCorrect
        )

        return RepositoryDescription(
            repository: updatedRepo,
            collections: uniqueCollections
        )
    }

    public func listRecords(
        in repository: ResolvedRepository,
        collection: String,
        cursor: String?,
        limit: Int,
        reverse: Bool
    ) async throws -> RepositoryRecordPage {
        let repoIdentifier: ATIdentifier
        do {
            repoIdentifier = try ATIdentifier(string: repository.did)
        } catch {
            throw BrowserFailure.invalidIdentifier(repository.did)
        }

        let collectionNSID: NSID
        do {
            collectionNSID = try NSID(nsidString: collection)
        } catch {
            throw BrowserFailure.invalidIdentifier(collection)
        }

        let params = ComAtprotoRepoListRecords.Parameters(
            repo: repoIdentifier,
            collection: collectionNSID,
            limit: limit > 0 ? limit : nil,
            cursor: cursor,
            reverse: reverse ? true : nil
        )

        let (code, output) = try await operations.listRecords(repository.pdsURL, params)
        let listOutput = try requireOutput(
            endpoint: "com.atproto.repo.listRecords",
            responseCode: code,
            output: output
        )

        var rows: [RecordRow] = []
        for record in listOutput.records {
            let atURI = record.uri
            guard atURI.authority == repository.did else {
                throw BrowserFailure.identityMismatch(
                    expected: repository.did,
                    actual: atURI.authority
                )
            }
            guard atURI.collection == collection else {
                throw BrowserFailure.identityMismatch(
                    expected: collection,
                    actual: atURI.collection ?? ""
                )
            }
            guard let rkey = atURI.recordKey, !rkey.isEmpty else {
                throw BrowserFailure.invalidIdentifier("Missing record key in URI: \(atURI.description)")
            }

            let json = RecordListModel.formatPrettyJSON(from: record.value)
            let blobEntries = RecordListModel.extractBlobEntries(from: record.value)
            let row = RecordRow(
                uri: atURI.description,
                collection: collection,
                rkey: rkey,
                cid: record.cid.string,
                json: json,
                blobEntries: blobEntries,
                origin: .publicRepository(did: repository.did)
            )
            rows.append(row)
        }

        return RepositoryRecordPage(records: rows, cursor: listOutput.cursor)
    }

    public func getRecord(
        in repository: ResolvedRepository,
        collection: String,
        rkey: String,
        cid: String?
    ) async throws -> RecordRow {
        let repoIdentifier: ATIdentifier
        do {
            repoIdentifier = try ATIdentifier(string: repository.did)
        } catch {
            throw BrowserFailure.invalidIdentifier(repository.did)
        }

        let collectionNSID: NSID
        do {
            collectionNSID = try NSID(nsidString: collection)
        } catch {
            throw BrowserFailure.invalidIdentifier(collection)
        }

        let recordKey: RecordKey
        do {
            recordKey = try RecordKey(keyString: rkey)
        } catch {
            throw BrowserFailure.invalidIdentifier(rkey)
        }

        var requestedCID: CIDString? = nil
        if let cid {
            do {
                requestedCID = CIDString(try CID.parse(cid))
            } catch {
                throw BrowserFailure.invalidIdentifier(cid)
            }
        }

        let params = ComAtprotoRepoGetRecord.Parameters(
            repo: repoIdentifier,
            collection: collectionNSID,
            rkey: recordKey,
            cid: requestedCID
        )

        let (code, output) = try await operations.getRecord(repository.pdsURL, params)
        let getOutput = try requireOutput(
            endpoint: "com.atproto.repo.getRecord",
            responseCode: code,
            output: output
        )

        let atURI = getOutput.uri
        guard atURI.authority == repository.did else {
            throw BrowserFailure.identityMismatch(
                expected: repository.did,
                actual: atURI.authority
            )
        }
        guard atURI.collection == collection else {
            throw BrowserFailure.identityMismatch(
                expected: collection,
                actual: atURI.collection ?? ""
            )
        }
        guard atURI.recordKey == rkey else {
            throw BrowserFailure.identityMismatch(
                expected: rkey,
                actual: atURI.recordKey ?? ""
            )
        }

        let finalCIDString: String
        if let reqCID = requestedCID {
            if let returnedCID = getOutput.cid {
                guard returnedCID.string == reqCID.string else {
                    throw BrowserFailure.identityMismatch(
                        expected: reqCID.string,
                        actual: returnedCID.string
                    )
                }
                finalCIDString = returnedCID.string
            } else {
                finalCIDString = reqCID.string
            }
        } else {
            guard let returnedCID = getOutput.cid else {
                throw BrowserFailure.decodeFailure(
                    endpoint: "com.atproto.repo.getRecord",
                    statusCode: code
                )
            }
            finalCIDString = returnedCID.string
        }

        let json = RecordListModel.formatPrettyJSON(from: getOutput.value)
        let blobEntries = RecordListModel.extractBlobEntries(from: getOutput.value)
        return RecordRow(
            uri: atURI.description,
            collection: collection,
            rkey: rkey,
            cid: finalCIDString,
            json: json,
            blobEntries: blobEntries,
            origin: .publicRepository(did: repository.did)
        )
    }
}
