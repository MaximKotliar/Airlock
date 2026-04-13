import Darwin
import Foundation
import XCTest
import Airlock

/// Tests for the unsafe fork-based API (`Airlock.runUnsafely`).
final class UnsafeTests: XCTestCase {

    private struct Sample: Codable, Equatable {
        var k: String
        var n: Int
    }

    private struct Empty: Codable, Equatable {}

    /// Encodes fine in the child; parent decode intentionally fails.
    private struct UndecodablePayload: Codable, Equatable {
        var n: Int
        init(n: Int) { self.n = n }
        init(from decoder: Decoder) throws {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "test decode failure")
            )
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(n, forKey: .n)
        }
        private enum CodingKeys: String, CodingKey { case n }
    }

    /// Encoding always fails (child should `_exit(3)`).
    private struct UnencodablePayload: Codable, Equatable {
        let marker: Int
        init(marker: Int) { self.marker = marker }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            marker = try c.decode(Int.self, forKey: .marker)
        }
        func encode(to encoder: Encoder) throws {
            throw EncodingError.invalidValue(
                marker,
                .init(codingPath: encoder.codingPath, debugDescription: "test encoding failure")
            )
        }
        private enum CodingKeys: String, CodingKey { case marker }
    }

    // MARK: - Helpers

    private func assertError<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        match: (AirlockError) -> Void
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { err in
            guard let e = err as? AirlockError else {
                return XCTFail("expected AirlockError, got \(err)", file: file, line: line)
            }
            match(e)
        }
    }

    private func assertThrowsAirlock(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void,
        match: (AirlockError) -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { err in
            guard let e = err as? AirlockError else {
                return XCTFail("expected AirlockError, got \(err)", file: file, line: line)
            }
            match(e)
        }
    }

    // MARK: - runUnsafely (Void)

    func testRunUnsafelyVoid_noOp_succeeds() throws {
        try Airlock.runUnsafely { }

        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testRunUnsafelyVoid_executesActionInChildProcess() throws {
        let path = NSTemporaryDirectory() + "airlock-test-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try Airlock.runUnsafely {
            try! "ok".write(toFile: path, atomically: true, encoding: .utf8)
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(content, "ok")
    }

    func testRunUnsafelyVoid_childExitNonZero_throwsChildExitCode() {
        assertError(try Airlock.runUnsafely { _exit(42) }) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 42)
        }
    }

    func testRunUnsafelyVoid_childSIGKILL_throwsChildExitedAbnormally() {
        assertError(
            try Airlock.runUnsafely { kill(getpid(), SIGKILL) }
        ) { e in
            guard case .childExitedAbnormally(let st) = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
            XCTAssertNotEqual(st & 0x7f, 0)
        }
    }

    func testRunUnsafelyVoid_fatalErrorDoesNotKillParent() {
        let parentPID = getpid()

        assertError(
            try Airlock.runUnsafely { fatalError("deliberate isolation test") }
        ) { e in
            guard case .childExitedAbnormally = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
        }

        XCTAssertEqual(getpid(), parentPID)
    }

    // MARK: - runUnsafely (Codable)

    func testRunUnsafely_roundtripsCodable() throws {
        let r = try Airlock.runUnsafely { Sample(k: "a", n: 7) }
        XCTAssertEqual(r, Sample(k: "a", n: 7))
    }

    func testRunUnsafely_roundtripsUnicode() throws {
        let s = "Hello 日本語 🎉"
        XCTAssertEqual(try Airlock.runUnsafely { s }, s)
    }

    func testRunUnsafely_roundtripsPrimitivesAndOptionals() throws {
        XCTAssertNil(try Airlock.runUnsafely { nil as Int? })
        XCTAssertEqual(try Airlock.runUnsafely { 99 as Int? }, 99 as Int?)
        XCTAssertEqual(try Airlock.runUnsafely { true }, true)
        XCTAssertEqual(try Airlock.runUnsafely { ["a", "b"] }, ["a", "b"])
    }

    // MARK: - runUnsafely (Codable): shmemSize

    func testRunUnsafely_invalidShmemSize_throws() {
        assertError(try Airlock.runUnsafely(shmemSize: 8) { Sample(k: "x", n: 1) }) { e in
            guard case .invalidShmemSize = e else {
                return XCTFail("expected invalidShmemSize, got \(e)")
            }
        }
    }

    func testRunUnsafely_minimumShmemSize_exactFit_succeeds() throws {
        let v = try Airlock.runUnsafely(shmemSize: 10) { Empty() }
        XCTAssertEqual(v, Empty())
    }

    func testRunUnsafely_minimumShmemSize_oneByteShort_throwsExitCode2() {
        assertError(try Airlock.runUnsafely(shmemSize: 9) { Empty() }) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode(2), got \(e)")
            }
            XCTAssertEqual(code, 2)
        }
    }

    func testRunUnsafely_largePayload() throws {
        let big = String(repeating: "z", count: 50_000)
        let r = try Airlock.runUnsafely(shmemSize: 1024 * 1024) { Sample(k: big, n: 99) }
        XCTAssertEqual(r, Sample(k: big, n: 99))
    }

    // MARK: - runUnsafely (Codable): child failure modes

    func testRunUnsafely_payloadTooLarge_throwsExitCode2() {
        assertError(
            try Airlock.runUnsafely(shmemSize: 64) {
                Sample(k: String(repeating: "x", count: 256), n: 0)
            }
        ) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 2)
        }
    }

    func testRunUnsafely_encodingFailure_throwsExitCode3() {
        assertError(try Airlock.runUnsafely { UnencodablePayload(marker: 1) }) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 3)
        }
    }

    func testRunUnsafely_decodingFailure_throwsDecodingFailed() {
        assertThrowsAirlock({
            let _: UndecodablePayload = try Airlock.runUnsafely { UndecodablePayload(n: 7) }
        }) { e in
            guard case .decodingFailed = e else {
                return XCTFail("expected decodingFailed, got \(e)")
            }
        }
    }

    func testRunUnsafely_fatalInCodableChild_throwsChildExitedAbnormally() {
        assertThrowsAirlock({
            let _: Sample = try Airlock.runUnsafely {
                fatalError("deliberate fatal error in isolated child")
            }
        }) { e in
            guard case .childExitedAbnormally = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
        }
    }

    // MARK: - Stress

    func testStress_1000ParallelForks() async throws {
        executionTimeAllowance = 600
        let count = 1000
        let childDelay: TimeInterval = 0.1

        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<count {
                group.addTask(priority: .userInitiated) {
                    try Airlock.runUnsafely {
                        Thread.sleep(forTimeInterval: childDelay)
                        return i
                    }
                }
            }
            var collected: [Int] = []
            collected.reserveCapacity(count)
            for try await v in group { collected.append(v) }
            return collected
        }

        XCTAssertEqual(values.count, count)
        XCTAssertEqual(Set(values), Set(0..<count))
    }
}
