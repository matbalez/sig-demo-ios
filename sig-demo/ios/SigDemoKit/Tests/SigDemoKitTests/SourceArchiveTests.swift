import XCTest
@testable import SigDemoKit

@MainActor
final class SourceArchiveTests: XCTestCase {
    private let abcSHA = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sig-demo-source-tests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return url
    }

    private func archive(in directory: URL) throws -> SigDemoSourceArchive {
        let url = directory.appendingPathComponent("SigDemoSource.tar.gz")
        try Data("abc".utf8).write(to: url)
        return try SigDemoSourceArchive(url: url, expectedSHA256: abcSHA)
    }

    func testMetadataRejectsRemoteRoutesNamesAndInvalidDigests() throws {
        for digest in ["", abcSHA.uppercased(), String(abcSHA.dropLast()), abcSHA + "\n"] {
            XCTAssertThrowsError(try SigDemoSourceArchive(url: URL(fileURLWithPath: "/tmp/SigDemoSource.tar.gz"),
                                                        expectedSHA256: digest))
        }
        XCTAssertThrowsError(try SigDemoSourceArchive(url: URL(string: "https://example.com/SigDemoSource.tar.gz")!,
                                                    expectedSHA256: abcSHA))
        XCTAssertThrowsError(try SigDemoSourceArchive(url: URL(fileURLWithPath: "/tmp/Other.tar.gz"),
                                                    expectedSHA256: abcSHA))
    }

    func testKnownDigestAndChangedBytesFailClosed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = try archive(in: directory)
        XCTAssertEqual(try SigDemoSourceArchive.verify(value), value.url)
        try Data("abd".utf8).write(to: value.url)
        XCTAssertThrowsError(try SigDemoSourceArchive.verify(value)) { error in
            XCTAssertEqual(error as? SigDemoSourceArchiveError, .failedVerification)
        }
    }

    func testSymlinkIsNeverFollowed() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target")
        try Data("abc".utf8).write(to: target)
        let link = directory.appendingPathComponent("SigDemoSource.tar.gz")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let value = try SigDemoSourceArchive(url: link, expectedSHA256: abcSHA)
        XCTAssertThrowsError(try SigDemoSourceArchive.verify(value)) { error in
            XCTAssertEqual(error as? SigDemoSourceArchiveError, .unavailable)
        }
    }

    func testMissingOrDirectoryArchiveIsUnavailable() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("SigDemoSource.tar.gz")
        let value = try SigDemoSourceArchive(url: url, expectedSHA256: abcSHA)
        XCTAssertThrowsError(try SigDemoSourceArchive.verify(value))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        XCTAssertThrowsError(try SigDemoSourceArchive.verify(value))
    }

    func testConcurrentAndRepeatedShareUsesOneVerification() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = try archive(in: directory)
        let count = Counter()
        let verifier = SigDemoSourceArchiveVerifier { value in
            count.increment()
            return try SigDemoSourceArchive.verify(value)
        }
        async let first = verifier.verifiedURL(for: value)
        async let second = verifier.verifiedURL(for: value)
        let results = try await (first, second)
        XCTAssertEqual(results.0, value.url)
        XCTAssertEqual(results.1, value.url)
        let third = try await verifier.verifiedURL(for: value)
        XCTAssertEqual(third, value.url)
        XCTAssertEqual(count.value, 1)
    }

    func testFailedVerificationIsCachedAndDigestSeparatesIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let valid = try archive(in: directory)
        let invalid = try SigDemoSourceArchive(url: valid.url, expectedSHA256: String(repeating: "0", count: 64))
        let count = Counter()
        let verifier = SigDemoSourceArchiveVerifier { value in
            count.increment()
            return try SigDemoSourceArchive.verify(value)
        }
        for _ in 0..<2 {
            do {
                _ = try await verifier.verifiedURL(for: invalid)
                XCTFail("An unverified archive was returned.")
            } catch {
                XCTAssertEqual(error as? SigDemoSourceArchiveError, .failedVerification)
            }
        }
        XCTAssertEqual(count.value, 1)
        let result = try await verifier.verifiedURL(for: valid)
        XCTAssertEqual(result, valid.url)
        XCTAssertEqual(count.value, 2)
    }

    func testBundleContractRequiresMatchingMetadataAndResource() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        func bundle(name: String, metadata: [String: String], includeArchive: Bool = true) throws -> Bundle {
            let url = directory.appendingPathComponent(name + ".bundle")
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            var values = metadata
            values["CFBundleIdentifier"] = "dev.matbalez.sig-demo.source-test." + name
            values["CFBundlePackageType"] = "BNDL"
            let plist = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            try plist.write(to: url.appendingPathComponent("Info.plist"))
            if includeArchive { try Data("abc".utf8).write(to: url.appendingPathComponent("SigDemoSource.tar.gz")) }
            return try XCTUnwrap(Bundle(url: url))
        }
        let metadata = ["SigDemoSourceArchive": "SigDemoSource.tar.gz", "SigDemoSourceSHA256": abcSHA]
        let valid = try bundle(name: "valid", metadata: metadata)
        let value = try XCTUnwrap(SigDemoSourceArchive.bundled(in: valid))
        XCTAssertEqual(try SigDemoSourceArchive.verify(value), value.url)
        let absent = try bundle(name: "absent", metadata: metadata, includeArchive: false)
        XCTAssertNil(SigDemoSourceArchive.bundled(in: absent))
        let wrongName = try bundle(name: "wrong", metadata: ["SigDemoSourceArchive": "Other.tar.gz", "SigDemoSourceSHA256": abcSHA])
        XCTAssertNil(SigDemoSourceArchive.bundled(in: wrongName))
        let missing = try bundle(name: "missing", metadata: [:])
        XCTAssertNil(SigDemoSourceArchive.bundled(in: missing))
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
