// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum SigDemoSourceArchiveError: Error, Equatable, Sendable {
    case unavailable
    case invalidMetadata
    case failedVerification
}

/// The build generator supplies the digest externally. The source archive does
/// not contain its own digest or recursively embed itself.
struct SigDemoSourceArchive: Hashable, Sendable {
    let url: URL
    let expectedSHA256: String

    init(url: URL, expectedSHA256: String) throws {
        guard url.isFileURL, url.lastPathComponent == "SigDemoSource.tar.gz",
              expectedSHA256.utf8.count == 64,
              expectedSHA256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw SigDemoSourceArchiveError.invalidMetadata
        }
        self.url = url.standardizedFileURL
        self.expectedSHA256 = expectedSHA256
    }

    static func bundled(in bundle: Bundle) -> Self? {
        guard bundle.object(forInfoDictionaryKey: "SigDemoSourceArchive") as? String == "SigDemoSource.tar.gz",
              let digest = bundle.object(forInfoDictionaryKey: "SigDemoSourceSHA256") as? String,
              let url = bundle.url(forResource: "SigDemoSource", withExtension: "tar.gz"),
              let resources = bundle.resourceURL,
              url.deletingLastPathComponent().standardizedFileURL == resources.standardizedFileURL else { return nil }
        return try? Self(url: url, expectedSHA256: digest)
    }

    static func verify(_ archive: Self) throws -> URL {
        let descriptor = archive.url.withUnsafeFileSystemRepresentation { path -> Int32 in
            guard let path else { return -1 }
            return open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { throw SigDemoSourceArchiveError.unavailable }
        let input = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? input.close() }
        var initial = stat()
        guard fstat(descriptor, &initial) == 0,
              (initial.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG), initial.st_size > 0 else {
            throw SigDemoSourceArchiveError.unavailable
        }
        do {
            var hash = SHA256()
            var size: Int64 = 0
            while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty {
                size += Int64(chunk.count)
                hash.update(data: chunk)
            }
            var final = stat()
            guard fstat(descriptor, &final) == 0, size == initial.st_size,
                  initial.st_dev == final.st_dev, initial.st_ino == final.st_ino,
                  initial.st_size == final.st_size else { throw SigDemoSourceArchiveError.failedVerification }
            #if canImport(Darwin)
            guard initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
                  initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec,
                  initial.st_ctimespec.tv_sec == final.st_ctimespec.tv_sec,
                  initial.st_ctimespec.tv_nsec == final.st_ctimespec.tv_nsec else {
                throw SigDemoSourceArchiveError.failedVerification
            }
            #else
            guard initial.st_mtim.tv_sec == final.st_mtim.tv_sec,
                  initial.st_mtim.tv_nsec == final.st_mtim.tv_nsec,
                  initial.st_ctim.tv_sec == final.st_ctim.tv_sec,
                  initial.st_ctim.tv_nsec == final.st_ctim.tv_nsec else {
                throw SigDemoSourceArchiveError.failedVerification
            }
            #endif
            let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
            guard digest == archive.expectedSHA256 else { throw SigDemoSourceArchiveError.failedVerification }
            return archive.url
        } catch let error as SigDemoSourceArchiveError {
            throw error
        } catch {
            throw SigDemoSourceArchiveError.unavailable
        }
    }
}

/// Coalesces verification and caches its outcome for this immutable signed
/// bundle resource. Hashing is streamed on a detached task, never on UIKit's
/// actor. Dismissing the UI does not create another hash pass on the next tap.
actor SigDemoSourceArchiveVerifier {
    static let shared = SigDemoSourceArchiveVerifier()
    typealias Operation = @Sendable (SigDemoSourceArchive) throws -> URL
    private let operation: Operation
    private var tasks: [SigDemoSourceArchive: Task<URL, any Error>] = [:]

    init(operation: @escaping Operation = SigDemoSourceArchive.verify) {
        self.operation = operation
    }

    func verifiedURL(for archive: SigDemoSourceArchive) async throws -> URL {
        if let existing = tasks[archive] { return try await existing.value }
        let operation = operation
        let task = Task.detached(priority: .userInitiated) { try operation(archive) }
        tasks[archive] = task
        return try await task.value
    }
}
