import Foundation
import OpenAI
import XCTest

final class HTTPRetryPolicyTests: XCTestCase {
    func testServerDelayPrecedenceDateAndCap() throws {
        XCTAssertEqual(
            try HTTPRetryPolicy.delay(
                attempt: 0,
                headers: ["retry-after-ms": "1250", "Retry-After": "5"], initialDelay: 0, maxDelay: 8), 1.25)
        XCTAssertEqual(
            try HTTPRetryPolicy.delay(
                attempt: 0,
                headers: ["Retry-After": "1000"], initialDelay: 0, maxDelay: 8), 8)
        XCTAssertEqual(
            try HTTPRetryPolicy.delay(
                attempt: 0,
                headers: ["Retry-After": "Tue, 14 Nov 2023 22:13:25 GMT"], initialDelay: 0, maxDelay: 8,
                now: Date(timeIntervalSince1970: 1_700_000_000)), 5)
        XCTAssertEqual(
            try HTTPRetryPolicy.delay(
                attempt: 0,
                headers: ["Retry-After": "nan"], initialDelay: 0, maxDelay: 8), 0)
    }

    func testCancellationAndTLSFailuresAreNotRetryable() {
        XCTAssertTrue(HTTPRetryPolicy.shouldRetry(error: URLError(.networkConnectionLost)))
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(error: CancellationError()))
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(error: URLError(.serverCertificateUntrusted)))
        XCTAssertFalse(HTTPRetryPolicy.shouldRetry(status: 503, headers: ["X-Should-Retry": "false"]))
        XCTAssertTrue(HTTPRetryPolicy.shouldRetry(status: 400, headers: ["X-Should-Retry": "true"]))
    }
}
