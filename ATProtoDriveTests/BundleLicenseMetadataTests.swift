//
//  BundleLicenseMetadataTests.swift
//  ATProtoDriveTests
//

import Foundation
import Testing

@Suite("Bundle license metadata")
struct BundleLicenseMetadataTests {
    @Test("App bundle declares the MIT OR Apache-2.0 dual license in its copyright string")
    func appBundleDeclaresDualLicense() throws {
        let copyright = try #require(
            Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
        )
        #expect(copyright.contains("MIT OR Apache-2.0"))
        #expect(copyright.contains("Catbird Contributors"))
    }
}
