import AppKit
import CryptoKit
import Security
import UniformTypeIdentifiers

extension Pref {
    // Upload (any S3-compatible storage). The secret key lives in the Keychain, see `S3Keychain`.
    static let s3Endpoint = PrefKey(name: "s3Endpoint", defaultValue: "")
    static let s3Region = PrefKey(name: "s3Region", defaultValue: "auto")
    static let s3Bucket = PrefKey(name: "s3Bucket", defaultValue: "")
    static let s3AccessKeyID = PrefKey(name: "s3AccessKeyID", defaultValue: "")
    static let s3PublicURL = PrefKey(name: "s3PublicURL", defaultValue: "")
}

/// AWS Signature Version 4, the part S3-compatible APIs (Cloudflare R2, Backblaze B2, AWS S3) need to authorize a request.
enum SigV4 {
    /// `20130524T000000Z`.
    static func amzDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter.string(from: date)
    }

    static func hex(_ digest: some Sequence<UInt8>) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of a file, read in chunks so a long recording is never held in memory.
    static func sha256Hex(ofFile url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hex(hasher.finalize())
    }

    /// Everything but unreserved characters is percent-encoded. `/` stays when encoding a path.
    static func encode(_ string: String, keepingSlash: Bool) -> String {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        if keepingSlash { allowed.insert("/") }
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }

    /// The value of the `Authorization` header. `headers` holds every header that is signed (at least `host` and
    /// `x-amz-date`), `path` is the unencoded path, `query` the already canonical query string.
    static func authorization(method: String, path: String, query: String = "", headers: [String: String], payloadHash: String,
                              amzDate: String, region: String, service: String, accessKey: String, secretKey: String) -> String {
        let lowered = headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespaces)) }.sorted { $0.0 < $1.0 }
        let canonicalHeaders = lowered.map { "\($0.0):\($0.1)\n" }.joined()
        let signedHeaders = lowered.map(\.0).joined(separator: ";")
        let canonicalRequest = [method, encode(path, keepingSlash: true), query, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")

        let day = String(amzDate.prefix(8))
        let scope = "\(day)/\(region)/\(service)/aws4_request"
        let stringToSign = ["AWS4-HMAC-SHA256", amzDate, scope, hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        var key = SymmetricKey(data: Data("AWS4\(secretKey)".utf8))
        for part in [day, region, service, "aws4_request"] {
            key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: Data(part.utf8), using: key)))
        }
        let signature = hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: key))
        return "AWS4-HMAC-SHA256 Credential=\(accessKey)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }
}

/// The Secret Access Key, in the Keychain as a generic password.
enum S3Keychain {
    private static let service = "dev.mariomiletta.Screenme.s3"
    private static let account = "secretAccessKey"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func read() -> String {
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 } as CFDictionary, &found)
        guard status == errSecSuccess, let data = found as? Data else { return "" }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Stores the secret, updating the item when there is one; an empty secret removes it. Throws a readable error
    /// when the Keychain refuses.
    static func write(_ secret: String) throws {
        guard !secret.isEmpty else {
            let deleted = SecItemDelete(query as CFDictionary)
            guard deleted == errSecSuccess || deleted == errSecItemNotFound else { throw Failure(status: deleted) }
            return
        }
        let value = [kSecValueData as String: Data(secret.utf8)]
        var status = SecItemUpdate(query as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(value) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw Failure(status: status) }
    }

    struct Failure: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Could not save to the Keychain: \(SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)")"
        }
    }
}

/// Where uploads go: the user's own S3-compatible bucket, addressed path-style (`<endpoint>/<bucket>/<key>`).
/// Only a complete, valid configuration exists: every field trimmed and filled in, both addresses real URLs.
struct UploadSettings {
    /// Without a trailing slash, with `https://` when it was typed without a scheme.
    let endpoint: URL
    /// The `Host` header value: the endpoint's host, with its port when it has one.
    let host: String
    let region: String
    let bucket: String
    let accessKeyID: String
    let secretKey: String
    /// Where the uploaded files are public, normalized like `endpoint`.
    let publicBase: URL

    struct Invalid: LocalizedError {
        let errorDescription: String?
    }

    /// The saved settings. Throws a message naming what to fix in Settings > Upload.
    static func load() throws -> UploadSettings {
        try UploadSettings(endpoint: Prefs[Pref.s3Endpoint], region: Prefs[Pref.s3Region], bucket: Prefs[Pref.s3Bucket],
                           accessKeyID: Prefs[Pref.s3AccessKeyID], secretKey: S3Keychain.read(), publicURL: Prefs[Pref.s3PublicURL])
    }

    init(endpoint: String, region: String, bucket: String, accessKeyID: String, secretKey: String, publicURL: String) throws {
        func filled(_ value: String, _ name: String) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { throw Invalid(errorDescription: "Set up Upload in Settings first: \(name) is empty") }
            return trimmed
        }
        func address(_ value: String, _ name: String) throws -> URL {
            var base = try filled(value, name)
            while base.hasSuffix("/") { base.removeLast() }
            guard let url = URL(string: base.contains("://") ? base : "https://" + base), url.host?.isEmpty == false else {
                throw Invalid(errorDescription: "\(name) is not a valid address")
            }
            return url
        }
        self.endpoint = try address(endpoint, "Endpoint URL")
        self.region = try filled(region, "Region")
        self.bucket = try filled(bucket, "Bucket")
        self.accessKeyID = try filled(accessKeyID, "Access Key ID")
        self.secretKey = try filled(secretKey, "Secret Access Key")
        self.publicBase = try address(publicURL, "Public URL")
        let host = self.endpoint.host ?? ""
        self.host = self.endpoint.port.map { "\(host):\($0)" } ?? host
    }

    /// The path that is signed: `/<bucket>/<key>`.
    func objectPath(key: String) -> String {
        "/\(bucket)/\(key)"
    }

    /// `<endpoint>/<bucket>/<key>`. Bucket names and the keys `S3Upload` makes hold only characters that need no encoding.
    func objectURL(key: String) -> URL {
        endpoint.appending(path: objectPath(key: key))
    }

    /// `<public base URL>/<key>`.
    func publicLink(key: String) -> String {
        publicBase.appending(path: key).absoluteString
    }
}

enum S3Upload {
    /// 24 random URL-safe characters (18 bytes of entropy) and the file extension: the link cannot be guessed.
    static func randomKey(extension ext: String) -> String {
        let bytes = (0..<18).map { _ in UInt8.random(in: 0...255) }
        let name = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
        return ext.isEmpty ? name : "\(name).\(ext.lowercased())"
    }

    static func contentType(forExtension ext: String) -> String {
        UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
    }

    /// A readable message for a failed request: the S3 error `<Code>` when the body has one, else the HTTP status.
    static func message(status: Int, body: Data) -> String {
        let text = String(data: body, encoding: .utf8) ?? ""
        let code = text.range(of: "<Code>(.*?)</Code>", options: .regularExpression)
            .map { String(text[$0]).replacingOccurrences(of: "<Code>", with: "").replacingOccurrences(of: "</Code>", with: "") }
        switch code {
        case "SignatureDoesNotMatch": return "Wrong Secret Access Key or Region"
        case "InvalidAccessKeyId": return "Access Key ID not found"
        case "NoSuchBucket": return "Bucket not found"
        case "AccessDenied": return "Access denied: the key needs read and write access to this bucket"
        case "InvalidBucketName": return "Invalid bucket name"
        case "AuthorizationHeaderMalformed", "InvalidRegion": return "Wrong Region for this endpoint"
        case "EntityTooLarge": return "File too large"
        case let code?: return "Upload failed (\(code))"
        case nil: return status == 403 ? "Access denied: check the keys" : status == 404 ? "Bucket not found" : "Upload failed (HTTP \(status))"
        }
    }

    /// A readable message for a request that never got an answer.
    static func message(for error: Error) -> String {
        guard let error = error as? URLError else { return error.localizedDescription }
        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut: return "No internet connection"
        case .cannotFindHost, .dnsLookupFailed, .unsupportedURL: return "Endpoint not found"
        default: return error.localizedDescription
        }
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
    }

    /// What a request sends: a file streamed from disk, a few bytes, or nothing.
    private enum Body {
        case file(URL)
        case data(Data)
        case none
    }

    /// Uploads `file` as `key` and returns the public link. Throws a `Failure` with a readable message.
    /// `progress` gets the share of the file sent so far, from 0 to 1, on URLSession's queue.
    static func put(_ file: URL, key: String, settings: UploadSettings,
                    progress: (@Sendable (Double) -> Void)? = nil) async throws -> String {
        try await send("PUT", key: key, settings: settings, body: .file(file),
                       contentType: contentType(forExtension: file.pathExtension), progress: progress)
        return settings.publicLink(key: key)
    }

    /// Uploads a tiny text object and deletes it again, to check the settings.
    static func test(settings: UploadSettings) async throws {
        let key = ".screenme-test-\(randomKey(extension: "txt"))"
        try await send("PUT", key: key, settings: settings, body: .data(Data("Screenme connection test".utf8)), contentType: "text/plain")
        try await send("DELETE", key: key, settings: settings, body: .none)
    }

    /// Signs and sends one request for the object `key`.
    private static func send(_ method: String, key: String, settings: UploadSettings, body: Body, contentType: String? = nil,
                             progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let payloadHash = switch body {
        case .file(let file): try SigV4.sha256Hex(ofFile: file)
        case .data(let data): SigV4.hex(SHA256.hash(data: data))
        case .none: SigV4.hex(SHA256.hash(data: Data()))
        }
        let date = SigV4.amzDate(Date())
        let headers = ["host": settings.host, "x-amz-content-sha256": payloadHash, "x-amz-date": date]
        var request = URLRequest(url: settings.objectURL(key: key))
        request.httpMethod = method
        for (name, value) in headers where name != "host" { request.setValue(value, forHTTPHeaderField: name) }
        request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        request.setValue(SigV4.authorization(method: method, path: settings.objectPath(key: key), headers: headers, payloadHash: payloadHash,
                                             amzDate: date, region: settings.region, service: "s3",
                                             accessKey: settings.accessKeyID, secretKey: settings.secretKey),
                         forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = switch body {
            case .file(let file): try await URLSession.shared.upload(for: request, fromFile: file, delegate: progress.map(UploadProgress.init))
            case .data(let data): try await URLSession.shared.upload(for: request, from: data)
            case .none: try await URLSession.shared.data(for: request)
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else { throw Failure(errorDescription: message(status: status, body: data)) }
        } catch let failure as Failure {
            throw failure
        } catch {
            throw Failure(errorDescription: message(for: error))
        }
    }
}

/// Passes on the bytes sent of one upload as a share of the file.
private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let report: @Sendable (Double) -> Void

    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
                    totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}
