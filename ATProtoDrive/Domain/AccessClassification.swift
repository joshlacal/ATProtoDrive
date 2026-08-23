import Foundation

public indirect enum AccessClassification: Hashable, Codable, Sendable {
    case publicRepository(did: String)
    case permissionedSpace(spaceURI: String, writerDID: String)
    case privateAppState(provider: String, accountDID: String)
    case localBackup(backupID: UUID, original: AccessClassification)
}
