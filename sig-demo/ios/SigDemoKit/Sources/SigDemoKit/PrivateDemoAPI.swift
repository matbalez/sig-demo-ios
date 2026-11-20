// Copyright 2026 Sig Demo contributors
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import CoreFoundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Security)
import Security
#endif

public protocol SigDemoHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// Uses an ephemeral URLSession, refuses redirects, and trusts only the bundled
/// private CA for localhost. It never disables TLS or accepts arbitrary trust.
public struct SigDemoURLSessionTransport: SigDemoHTTPTransport {
    private let caDER: Data

    public init(configuration: SigDemoConfiguration) throws {
        guard let der = SigDemoConfiguration.certificateDER(configuration.trust.certificateAuthority) else {
            throw SigDemoError.invalidConfiguration("Invalid private certificate.")
        }
        #if canImport(Security)
        guard SecCertificateCreateWithData(nil, der as CFData) != nil else {
            throw SigDemoError.invalidConfiguration("Invalid private certificate.")
        }
        #endif
        caDER = der
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        #if canImport(Security)
        guard request.url?.scheme == "https", request.url?.host == "localhost" else {
            throw SigDemoError.invalidConfiguration("The private transport only accepts localhost TLS requests.")
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: PrivateTrustDelegate(caDER: caDER), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw SigDemoError.invalidServerResponse }
        return (data, http)
        #else
        // Inject a transport for host tests; never silently use system CA trust.
        throw SigDemoError.unsupportedPlatform
        #endif
    }
}

#if canImport(Security)
private final class PrivateTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    let caDER: Data
    init(caDER: Data) { self.caDER = caDER }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == "localhost",
              let trust = challenge.protectionSpace.serverTrust,
              let anchor = SecCertificateCreateWithData(nil, caDER as CFData),
              SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetPolicies(trust, SecPolicyCreateSSL(true, "localhost" as CFString)) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif

/// Exact JSON produced from upstream Signal's locally generated public keys.
/// The body also contains the one-time invitation and generated auth/recovery
/// secrets: do not log it or write it to a plaintext file or preferences.
public struct SigDemoRegistrationPayload: Sendable, CustomStringConvertible {
    public let json: Data
    public var description: String { "SigDemoRegistrationPayload(<redacted>)" }

    public init(json: Data) throws {
        guard json.count <= 128 * 1024,
              let body = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              Set(body.keys) == Set(["inviteCode", "displayName", "password", "sessionId", "skipDeviceTransfer",
                "aciIdentityKey", "pniIdentityKey", "aciSignedPreKey", "aciPqLastResortPreKey",
                "pniSignedPreKey", "pniPqLastResortPreKey", "accountAttributes"]),
              let invitation = body["inviteCode"] as? String, (20...128).contains(invitation.count),
              let name = body["displayName"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              let password = body["password"] as? String, (20...256).contains(password.count),
              body["sessionId"] as? String == "", Self.boolean(body["skipDeviceTransfer"]) == true,
              Self.base64(body["aciIdentityKey"]), Self.base64(body["pniIdentityKey"]),
              ["aciSignedPreKey", "aciPqLastResortPreKey", "pniSignedPreKey", "pniPqLastResortPreKey"].allSatisfy({ Self.signedKey(body[$0]) }),
              let attributes = body["accountAttributes"] as? [String: Any],
              Set(attributes.keys) == Set(["fetchesMessages", "registrationId", "pniRegistrationId", "capabilities",
                "unidentifiedAccessKey", "unrestrictedUnidentifiedAccess", "discoverableByPhoneNumber", "recoveryPassword"]),
              Self.boolean(attributes["fetchesMessages"]) == true,
              Self.boolean(attributes["unrestrictedUnidentifiedAccess"]) == false,
              Self.boolean(attributes["discoverableByPhoneNumber"]) == false,
              Self.integer(attributes["registrationId"], range: 1...16383),
              Self.integer(attributes["pniRegistrationId"], range: 1...16383),
              Self.base64(attributes["recoveryPassword"]),
              let access = attributes["unidentifiedAccessKey"] as? [Any], access.count == 16,
              access.allSatisfy({ Self.integer($0, range: 0...255) }),
              let capabilities = attributes["capabilities"] as? [String: Any],
              Set(capabilities.keys) == Set(["attachmentBackfill", "spqr", "usernameChangeSyncMessage", "optionalPhoneNumber"]),
              capabilities.values.allSatisfy({ Self.boolean($0) != nil }) else {
            throw SigDemoError.invalidRegistrationPayload
        }
        self.json = json
    }

    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    private static func integer(_ value: Any?, range: ClosedRange<Int>) -> Bool {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { return false }
        return true
    }
    private static func base64(_ value: Any?) -> Bool {
        guard let text = value as? String, let data = Data(base64Encoded: text), !data.isEmpty else { return false }
        return true
    }
    private static func signedKey(_ value: Any?) -> Bool {
        guard let key = value as? [String: Any], Set(key.keys) == Set(["keyId", "publicKey", "signature"]) else { return false }
        return integer(key["keyId"], range: 0...Int(UInt32.max)) && base64(key["publicKey"]) && base64(key["signature"])
    }
}

public struct SigDemoAccount: Decodable, Equatable, Sendable {
    public let uuid: UUID
    public let pni: UUID
    public let number: String
    public let deviceId: Int
    public let storageCapable: Bool
    public let reregistration: Bool

    func validate() throws {
        guard deviceId == 1, !storageCapable, !reregistration,
              number.range(of: "^\\+999[0-9]{9}$", options: .regularExpression) != nil else {
            throw SigDemoError.invalidServerResponse
        }
    }
}

public struct SigDemoDirectoryAccount: Decodable, Equatable, Sendable {
    public let uuid: UUID
    public let displayName: String
}

public struct SigDemoCredentials: Sendable, CustomStringConvertible {
    public let accountID: UUID
    private let password: String
    public var description: String { "SigDemoCredentials(<redacted>)" }

    public init(accountID: UUID, generatedPassword: String) throws {
        guard (20...256).contains(generatedPassword.count),
              !generatedPassword.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw SigDemoError.invalidCredentials
        }
        self.accountID = accountID
        self.password = generatedPassword
    }

    var authorization: String {
        "Basic " + Data("\(accountID.uuidString.lowercased()).1:\(password)".utf8).base64EncodedString()
    }
}

public protocol SigDemoAccountAPI: Sendable {
    func register(_ payload: SigDemoRegistrationPayload) async throws -> SigDemoAccount
}

public struct SigDemoPrivateAPI: SigDemoAccountAPI, Sendable {
    public let configuration: SigDemoConfiguration
    public let identity: SigDemoAppIdentity
    private let transport: any SigDemoHTTPTransport

    public init(configuration: SigDemoConfiguration, identity: SigDemoAppIdentity, transport: (any SigDemoHTTPTransport)? = nil) throws {
        try identity.validateCurrentProcess()
        self.configuration = configuration
        self.identity = identity
        self.transport = try transport ?? SigDemoURLSessionTransport(configuration: configuration)
    }

    public func register(_ payload: SigDemoRegistrationPayload) async throws -> SigDemoAccount {
        var request = makeRequest(path: "/v1/sig-demo/accounts", method: "POST")
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = payload.json
        let account = try JSONDecoder().decode(SigDemoAccount.self, from: await execute(request))
        try account.validate()
        return account
    }

    public func directory(credentials: SigDemoCredentials) async throws -> [SigDemoDirectoryAccount] {
        var request = makeRequest(path: "/v1/sig-demo/directory", method: "GET")
        request.setValue(credentials.authorization, forHTTPHeaderField: "Authorization")
        struct Directory: Decodable { let accounts: [SigDemoDirectoryAccount] }
        let accounts = try JSONDecoder().decode(Directory.self, from: await execute(request)).accounts
        guard accounts.allSatisfy({ !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.displayName.count <= 100 }),
              Set(accounts.map(\.uuid)).count == accounts.count else { throw SigDemoError.invalidServerResponse }
        return accounts
    }

    public func demoInferenceCredentials(credentials: SigDemoCredentials) async throws -> SigDemoInferenceCredentialProvision {
        var request = makeRequest(path: "/v1/sig-demo/demo-credentials", method: "GET")
        request.timeoutInterval = 15
        request.setValue(credentials.authorization, forHTTPHeaderField: "Authorization")
        let data = try await execute(request)
        guard data.count <= 8_192 else { throw SigDemoError.invalidServerResponse }
        do { return try JSONDecoder().decode(SigDemoInferenceCredentialProvision.self, from: data) }
        catch { throw SigDemoError.invalidServerResponse }
    }

    private func makeRequest(path: String, method: String) -> URLRequest {
        let url = configuration.serverURL.appendingPathComponent(String(path.dropFirst()))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func execute(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await transport.send(request)
        guard response.url == request.url, data.count <= 1024 * 1024 else { throw SigDemoError.invalidServerResponse }
        guard response.statusCode == 200 else {
            #if DEBUG && targetEnvironment(simulator)
            if request.httpMethod == "POST" {
                // Emit only a fixed diagnostic label, never the response body,
                // invitation, generated password, or registration key material.
                let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                let labels = [
                    "Invalid invite": "INVALID_INVITE",
                    "Invite expired": "EXPIRED_INVITE",
                    "Invite already used by another registration": "INVITE_ALREADY_USED",
                    "Invalid public registration key material": "INVALID_REGISTRATION_PAYLOAD",
                    "Public key decoding or signature verification failed": "INVALID_PUBLIC_KEYS",
                    "Invalid PNI registration ID": "INVALID_PNI_REGISTRATION_ID",
                    "Invalid unidentified access key": "INVALID_ACCESS_KEY",
                ]
                let label = reason.flatMap { labels[$0] } ?? "UNCLASSIFIED"
                let marker = "SIG_DEMO_REGISTRATION_HTTP_\(response.statusCode)_\(label)\n"
                try? FileHandle.standardOutput.write(contentsOf: Data(marker.utf8))
                NSLog("%@", marker.trimmingCharacters(in: .newlines))
            }
            #endif
            throw SigDemoError.rejected(status: response.statusCode)
        }
        return data
    }
}
