import XCTest
@testable import UCASCore

final class CloudPushEntitlementTests: XCTestCase {
    func testSignedScalarPushEnvironmentIsReadWithoutTreatingArraysAsScalars() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: [
            "aps-environment": "development",
            "com.apple.developer.icloud-services": ["CloudKit"]
        ], format: .xml, options: 0)
        let executable = signature(xml: xml)
        XCTAssertEqual(SignedEntitlementReader.strings(from: executable), ["aps-environment": "development"])
        XCTAssertEqual(SignedEntitlementReader.stringArrays(from: executable),
                       ["com.apple.developer.icloud-services": ["CloudKit"]])
    }

    func testDERScalarOverridesLegacyXMLPushEnvironment() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["aps-environment": "development"],
                                                       format: .xml, options: 0)
        let entry = der(0x30, der(0x0c, Data("aps-environment".utf8)) + der(0x0c, Data("production".utf8)))
        let encoded = der(0x70, der(2, Data([1])) + der(0xb0, entry))
        XCTAssertEqual(SignedEntitlementReader.strings(from: signature(xml: xml, encodedDER: encoded)),
                       ["aps-environment": "production"])
        XCTAssertEqual(SignedEntitlementReader.derStrings(encoded), ["aps-environment": "production"])
    }

    func testInvalidDERNeverFallsBackToLegacyXMLPushEnvironment() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["aps-environment": "production"],
                                                       format: .xml, options: 0)
        XCTAssertTrue(SignedEntitlementReader.strings(from: signature(xml: xml, encodedDER: Data([0x70, 0xff]))).isEmpty)
        XCTAssertTrue(SignedEntitlementReader.strings(from: Data()).isEmpty)
        XCTAssertNil(SignedEntitlementReader.derStrings(Data([0x70, 0x80])))
    }

    func testArrayPushEnvironmentCannotAuthorizeRegistration() throws {
        let xml = try PropertyListSerialization.data(fromPropertyList: ["aps-environment": ["production"]],
                                                       format: .xml, options: 0)
        XCTAssertNil(SignedEntitlementReader.strings(from: signature(xml: xml))["aps-environment"])
    }

    private func der(_ tag: UInt8, _ body: Data) -> Data {
        precondition(body.count < 128)
        return Data([tag, UInt8(body.count)]) + body
    }

    private func signature(xml: Data? = nil, encodedDER: Data? = nil) -> Data {
        func words(_ values: [UInt32], bigEndian: Bool) -> Data {
            Data(values.flatMap { value in
                (bigEndian ? [24, 16, 8, 0] : [0, 8, 16, 24]).map { UInt8(truncatingIfNeeded: value >> $0) }
            })
        }
        var entries: [(UInt32, UInt32, Data)] = []
        if let xml { entries.append((5, 0xfade7171, xml)) }
        if let encodedDER { entries.append((7, 0xfade7172, encodedDER)) }
        var offset = 12 + entries.count * 8
        var indexes = Data()
        var blobs = Data()
        for (slot, magic, payload) in entries {
            indexes += words([slot, UInt32(offset)], bigEndian: true)
            blobs += words([magic, UInt32(payload.count + 8)], bigEndian: true) + payload
            offset += payload.count + 8
        }
        let signed = words([0xfade0cc0, UInt32(offset), UInt32(entries.count)], bigEndian: true) + indexes + blobs
        return words([0xfeedfacf, 0x0100000c, 0, 2, 1, 16, 0, 0, 0x1d, 16, 48, UInt32(signed.count)], bigEndian: false) + signed
    }
}
