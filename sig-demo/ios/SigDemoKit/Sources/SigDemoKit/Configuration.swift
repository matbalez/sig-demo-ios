// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

enum SigDemoRelayApproval {
    static let host: String = {
        guard let url = Bundle.module.url(forResource: "ApprovedRelay", withExtension: "txt"),
              let contents = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return contents.trimmingCharacters(in: .whitespacesAndNewlines)
    }()
}

public enum SigDemoError: Error, Equatable, Sendable {
    case invalidConfiguration(String)
    case invalidRegistrationPayload
    case invalidCredentials
    case invalidServerResponse
    case rejected(status: Int)
    case registrationAlreadyRunning
    case draftBelongsToAnotherEnvironment
    case unsupportedDraftVersion
    case unsupportedPlatform
}

/// These identifiers must also be applied to every upstream app/extension target,
/// entitlement, keychain access group, and database location before networking starts.
public struct SigDemoAppIdentity: Codable, Equatable, Sendable {
    public static let namespace = "dev.matbalez.sig-demo.ios"
    public let bundleIdentifier: String
    public let appGroupIdentifier: String
    public let keychainService: String

    public init(bundleIdentifier: String, appGroupIdentifier: String, keychainService: String) throws {
        guard bundleIdentifier == Self.namespace || bundleIdentifier.hasPrefix(Self.namespace + "."),
              ["group." + Self.namespace + ".signal.group", "group." + Self.namespace + ".signal.group.staging"].contains(appGroupIdentifier),
              keychainService == Self.namespace || keychainService.hasPrefix(Self.namespace + "."),
              [bundleIdentifier, appGroupIdentifier, keychainService].allSatisfy({
                  !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
              }) else {
            throw SigDemoError.invalidConfiguration("A separate sig-demo iOS app, app group, and keychain service are required.")
        }
        self.bundleIdentifier = bundleIdentifier
        self.appGroupIdentifier = appGroupIdentifier
        self.keychainService = keychainService
    }

    private enum CodingKeys: String, CodingKey { case bundleIdentifier, appGroupIdentifier, keychainService }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            bundleIdentifier: values.decode(String.self, forKey: .bundleIdentifier),
            appGroupIdentifier: values.decode(String.self, forKey: .appGroupIdentifier),
            keychainService: values.decode(String.self, forKey: .keychainService)
        )
    }

    /// A native app must use the identities in its signed target entitlements,
    /// rather than merely presenting a separate identifier in configuration.
    public func validateCurrentProcess() throws {
        #if os(iOS)
        guard Bundle.main.bundleIdentifier == bundleIdentifier,
              FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier) != nil else {
            throw SigDemoError.invalidConfiguration("The running app must have the isolated demo bundle and app-group entitlements.")
        }
        #endif
    }
}

public struct SigDemoRelayConfiguration: Decodable, Equatable, Sendable {
    public let host: String
    public let port: Int
}

public struct SigDemoTrustMaterial: Codable, Equatable, Sendable {
    public let certificateAuthority: String
    public let serverTrustRoots: [String]
    public let serverPublicParams: String
    public let genericServerPublicParams: String
    public let backupServerPublicParams: String
}

/// Decodes the existing *public* desktop client configuration. It contains no
/// server keys, account credentials, invitations, or inference credentials.
public struct SigDemoConfiguration: Decodable, Sendable {
    public let serverURL: URL
    public let storageURL: URL
    public let cdn: [String: URL]
    public let relay: SigDemoRelayConfiguration?
    public let trust: SigDemoTrustMaterial

    private enum CodingKeys: String, CodingKey {
        case sigDemoEnabled, sigDemoNetworkMode, updatesEnabled, storageProfile
        case serverUrl, storageUrl, resourcesUrl, sfuUrl, contentProxyUrl, updatesUrl
        case challengeUrl, registrationChallengeUrl, cdn, sigDemoRelay
        case certificateAuthority, serverTrustRoots, serverPublicParams
        case genericServerPublicParams, backupServerPublicParams
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Bool.self, forKey: .sigDemoEnabled),
              try values.decode(String.self, forKey: .sigDemoNetworkMode) == "localhost",
              try !values.decode(Bool.self, forKey: .updatesEnabled),
              try values.decode(String.self, forKey: .storageProfile) == "demo" else {
            throw SigDemoError.invalidConfiguration("Only the isolated private demo environment is allowed.")
        }
        let server = try Self.localURL(values.decode(String.self, forKey: .serverUrl), root: true)
        let storage = try Self.localURL(values.decode(String.self, forKey: .storageUrl), origin: server)
        for key in [CodingKeys.resourcesUrl, .sfuUrl, .contentProxyUrl, .updatesUrl, .challengeUrl, .registrationChallengeUrl] {
            _ = try Self.localURL(values.decode(String.self, forKey: key), origin: server)
        }
        let cdnValues = try values.decode([String: String].self, forKey: .cdn)
        var cdnURLs: [String: URL] = [:]
        for index in ["0", "2", "3"] {
            guard let value = cdnValues[index] else {
                throw SigDemoError.invalidConfiguration("All private attachment endpoints are required.")
            }
            cdnURLs[index] = try Self.localURL(value, origin: server)
        }
        let relay = try values.decodeIfPresent(SigDemoRelayConfiguration.self, forKey: .sigDemoRelay)
        if let relay {
            guard !relay.host.isEmpty,
                  [SigDemoRelayApproval.host, "localhost", "127.0.0.1"].contains(relay.host),
                  (1...65535).contains(relay.port) else {
                throw SigDemoError.invalidConfiguration("The relay must target the approved private demo server.")
            }
        }
        let trust = SigDemoTrustMaterial(
            certificateAuthority: try values.decode(String.self, forKey: .certificateAuthority),
            serverTrustRoots: try values.decode([String].self, forKey: .serverTrustRoots),
            serverPublicParams: try values.decode(String.self, forKey: .serverPublicParams),
            genericServerPublicParams: try values.decode(String.self, forKey: .genericServerPublicParams),
            backupServerPublicParams: try values.decode(String.self, forKey: .backupServerPublicParams)
        )
        // Reject known official production and staging roots from Desktop and
        // iOS; only this deployment's independently generated roots belong here.
        let officialSignalRoots: Set<String> = [
            "BXu6QIKVz5MA8gstzfOgRQGqyLqOwNKHL6INkv3IHWMF",
            "BUkY0I+9+oPgDCn4+Ac6Iu813yvqkDr/ga8DzLxFxuk6",
            "BbqY1DzohE4NUZoVF+L18oUPrK3kILllLEJh2UnPSsEx",
            "BYhU6tPjqP46KGZEzRs1OL4U39V5dlPJ/X09ha4rErkm",
        ]
        guard Self.certificateDER(trust.certificateAuthority) != nil,
              !trust.serverTrustRoots.isEmpty,
              trust.serverTrustRoots.allSatisfy({
                  Data(base64Encoded: $0)?.count == 33 && !officialSignalRoots.contains($0)
              }),
              [trust.serverPublicParams, trust.genericServerPublicParams, trust.backupServerPublicParams]
                .allSatisfy({ !(Data(base64Encoded: $0)?.isEmpty ?? true) }) else {
            throw SigDemoError.invalidConfiguration("Explicit private CA and Signal server trust material are required.")
        }
        self.serverURL = server
        self.storageURL = storage
        self.cdn = cdnURLs
        self.relay = relay
        self.trust = trust
    }

    private static func localURL(_ value: String, origin: URL? = nil, root: Bool = false) throws -> URL {
        guard let parts = URLComponents(string: value),
              parts.scheme == "https", parts.host == "localhost",
              let port = parts.port, (1...65535).contains(port),
              parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil,
              !parts.percentEncodedPath.contains("%"),
              !parts.path.contains(".."), !parts.path.contains("\\"),
              !parts.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !root || parts.path.isEmpty || parts.path == "/",
              let url = parts.url,
              origin == nil || (origin?.scheme == url.scheme && origin?.host == url.host && origin?.port == url.port) else {
            throw SigDemoError.invalidConfiguration("Every service must use the configured https://localhost:<port> private transport.")
        }
        return url
    }

    static func certificateDER(_ pem: String) -> Data? {
        let begin = "-----BEGIN CERTIFICATE-----"
        let end = "-----END CERTIFICATE-----"
        let trimmed = pem.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix(begin), trimmed.hasSuffix(end) else { return nil }
        let body = trimmed.dropFirst(begin.count).dropLast(end.count)
        guard !body.contains("-----") else { return nil }
        let base64 = body.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: base64), !data.isEmpty else { return nil }
        return data
    }
}
