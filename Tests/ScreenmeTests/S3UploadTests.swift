import XCTest
@testable import Screenme

/// Upload & Copy Link: the request signature, key and URL building, and error messages. The network call is not tested.
final class S3UploadTests: XCTestCase {
    private let access = "AKIAIOSFODNN7EXAMPLE"
    private let secret = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    private let emptyHash = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

    // The "GET Object" example from the AWS Signature Version 4 documentation for S3.
    func testSignatureMatchesTheAWSGetObjectExample() {
        let header = SigV4.authorization(
            method: "GET", path: "/test.txt",
            headers: ["host": "examplebucket.s3.amazonaws.com", "range": "bytes=0-9", "x-amz-content-sha256": emptyHash, "x-amz-date": "20130524T000000Z"],
            payloadHash: emptyHash, amzDate: "20130524T000000Z", region: "us-east-1", service: "s3", accessKey: access, secretKey: secret)
        XCTAssertEqual(header, "AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20130524/us-east-1/s3/aws4_request, "
            + "SignedHeaders=host;range;x-amz-content-sha256;x-amz-date, "
            + "Signature=f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41")
    }

    // The "PUT Object" example: a path with a character that must be percent-encoded, and extra signed headers.
    func testSignatureMatchesTheAWSPutObjectExample() {
        let hash = "44ce7dd67c959e0d3524ffac1771dfbba87d2b6b4b4e99e42034a8b803f8b072"
        let header = SigV4.authorization(
            method: "PUT", path: "/test$file.text",
            headers: ["date": "Fri, 24 May 2013 00:00:00 GMT", "host": "examplebucket.s3.amazonaws.com", "x-amz-date": "20130524T000000Z",
                      "x-amz-storage-class": "REDUCED_REDUNDANCY", "x-amz-content-sha256": hash],
            payloadHash: hash, amzDate: "20130524T000000Z", region: "us-east-1", service: "s3", accessKey: access, secretKey: secret)
        XCTAssertTrue(header.hasSuffix("Signature=98ad721746da40c64f1a55b78f14c238d841ea1380cd77a1b5971af0ece108bd"), header)
    }

    func testAmzDateIsUTC() {
        XCTAssertEqual(SigV4.amzDate(Date(timeIntervalSince1970: 1_369_353_600)), "20130524T000000Z")
    }

    func testRandomKeyIsLongUnguessableAndKeepsTheExtension() {
        let key = S3Upload.randomKey(extension: "PNG")
        XCTAssertTrue(key.hasSuffix(".png"))
        let name = String(key.dropLast(4))
        XCTAssertEqual(name.count, 24)
        XCTAssertNil(name.rangeOfCharacter(from: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").inverted))
        XCTAssertNotEqual(key, S3Upload.randomKey(extension: "png"))
    }

    func testContentTypes() {
        XCTAssertEqual(S3Upload.contentType(forExtension: "png"), "image/png")
        XCTAssertEqual(S3Upload.contentType(forExtension: "gif"), "image/gif")
        XCTAssertEqual(S3Upload.contentType(forExtension: "mp4"), "video/mp4")
    }

    private func settings(endpoint: String, region: String = "auto", publicURL: String) -> UploadSettings {
        UploadSettings(endpoint: endpoint, region: region, bucket: "shots", accessKeyID: "id", secretKey: "secret", publicURL: publicURL)
    }

    func testURLsForR2() {
        let s = settings(endpoint: "https://abc123.r2.cloudflarestorage.com", publicURL: "https://pub-xyz.r2.dev")
        XCTAssertEqual(s.objectURL(key: "k.png")?.absoluteString, "https://abc123.r2.cloudflarestorage.com/shots/k.png")
        XCTAssertEqual(s.host, "abc123.r2.cloudflarestorage.com")
        XCTAssertEqual(s.publicLink(key: "k.png"), "https://pub-xyz.r2.dev/k.png")
    }

    func testURLsForBackblazeAndAWSWithRegions() {
        let b2 = settings(endpoint: "https://s3.us-west-004.backblazeb2.com/", region: "us-west-004", publicURL: "https://f004.backblazeb2.com/file/shots/")
        XCTAssertEqual(b2.objectURL(key: "k.gif")?.absoluteString, "https://s3.us-west-004.backblazeb2.com/shots/k.gif")
        XCTAssertEqual(b2.publicLink(key: "k.gif"), "https://f004.backblazeb2.com/file/shots/k.gif")

        let aws = settings(endpoint: "s3.eu-central-1.amazonaws.com", region: "eu-central-1", publicURL: "cdn.example.com")
        XCTAssertEqual(aws.objectURL(key: "k.mp4")?.absoluteString, "https://s3.eu-central-1.amazonaws.com/shots/k.mp4")
        XCTAssertEqual(aws.publicLink(key: "k.mp4"), "https://cdn.example.com/k.mp4")
    }

    func testHostKeepsACustomPort() {
        XCTAssertEqual(settings(endpoint: "http://localhost:9000", publicURL: "x").host, "localhost:9000")
    }

    func testCompletenessNeedsEveryField() {
        XCTAssertTrue(settings(endpoint: "https://a.b", publicURL: "https://c.d").isComplete)
        XCTAssertFalse(settings(endpoint: " ", publicURL: "https://c.d").isComplete)
        XCTAssertFalse(settings(endpoint: "https://a.b", region: "", publicURL: "https://c.d").isComplete)
    }

    func testErrorCodesBecomeReadableMessages() {
        func message(_ code: String, status: Int = 403) -> String {
            S3Upload.message(status: status, body: Data("<?xml version=\"1.0\"?><Error><Code>\(code)</Code><Message>x</Message></Error>".utf8))
        }
        XCTAssertEqual(message("SignatureDoesNotMatch"), "Wrong Secret Access Key or Region")
        XCTAssertEqual(message("InvalidAccessKeyId"), "Access Key ID not found")
        XCTAssertEqual(message("NoSuchBucket", status: 404), "Bucket not found")
        XCTAssertTrue(message("AccessDenied").hasPrefix("Access denied"))
        XCTAssertEqual(message("AuthorizationHeaderMalformed"), "Wrong Region for this endpoint")
        XCTAssertEqual(message("SlowDown", status: 503), "Upload failed (SlowDown)")
        XCTAssertEqual(S3Upload.message(status: 403, body: Data()), "Access denied: check the keys")
        XCTAssertEqual(S3Upload.message(status: 500, body: Data()), "Upload failed (HTTP 500)")
    }

    func testNetworkErrorsBecomeReadableMessages() {
        XCTAssertEqual(S3Upload.message(for: URLError(.notConnectedToInternet)), "No internet connection")
        XCTAssertEqual(S3Upload.message(for: URLError(.cannotFindHost)), "Endpoint not found")
    }
}
