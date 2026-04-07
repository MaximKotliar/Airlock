import Darwin
import Foundation
import XCTest
import Airlock

/// Exercises ``Airlock/runIsolated(action:)`` and ``Airlock/runIsolated(shmemSize:action:)`` / ``AirlockIsolationError`` paths.
///
/// Not covered without fakes or environment tricks: `forkFailed`, `waitFailed`, `sharedMemoryMapFailed`, and
/// `invalidPayloadLength` (parent-only guard when the shared length prefix disagrees with the mapping).
final class AirlockTests: XCTestCase {

    private struct Sample: Codable, Equatable {
        var k: String
        var n: Int
    }

    private struct Empty: Codable, Equatable {}

    /// Encodes fine in the child; parent decode intentionally fails → ``AirlockIsolationError/decodingFailed``.
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

    /// `Codable` value whose encoding always fails (child should `_exit(3)`).
    private struct UnencodablePayload: Codable, Equatable {
        let marker: Int

        init(marker: Int) {
            self.marker = marker
        }

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

    // MARK: - AirlockIsolationError helpers

    private func assertError<T>(
        _ expression: @autoclosure () throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line,
        match: (AirlockIsolationError) -> Void
    ) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { err in
            guard let e = err as? AirlockIsolationError else {
                return XCTFail("expected AirlockIsolationError, got \(err)", file: file, line: line)
            }
            match(e)
        }
    }

    /// For assertions where type inference needs a multi-statement `throws` block.
    private func assertThrowsAirlock(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ body: () throws -> Void,
        match: (AirlockIsolationError) -> Void
    ) {
        XCTAssertThrowsError(try body(), file: file, line: line) { err in
            guard let e = err as? AirlockIsolationError else {
                return XCTFail("expected AirlockIsolationError, got \(err)", file: file, line: line)
            }
            match(e)
        }
    }

    // MARK: - runIsolated (Void)

    func testRunIsolatedVoid_noOp_succeedsAndReaps() throws {
        try Airlock.runIsolated { }

        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD)
    }

    func testRunIsolatedVoid_executesActionInChildProcess() throws {
        let path = NSTemporaryDirectory() + "airlock-test-\(UUID().uuidString).txt"
        defer { try? FileManager.default.removeItem(atPath: path) }

        try Airlock.runIsolated {
            try! "ok".write(toFile: path, atomically: true, encoding: .utf8)
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertEqual(content, "ok")

        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "child should already be reaped before return")
    }

    func testRunIsolatedVoid_childCallsExitWithNonZero_throwsChildExitCode() {
        assertError(try Airlock.runIsolated { _exit(42) }) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 42)
        }
    }

    /// Low 8 bits of wait-status exit code (contrast with reserved `2` / `3` in the Codable path).
    func testRunIsolatedVoid_childExit255_throwsChildExitCode() {
        assertError(try Airlock.runIsolated { _exit(255) }) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 255)
        }
    }

    func testRunIsolatedVoid_childReceivesSIGKILL_throwsChildExitedAbnormally() {
        assertError(
            try Airlock.runIsolated {
                kill(getpid(), SIGKILL)
            }
        ) { e in
            guard case .childExitedAbnormally(let st) = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
            XCTAssertNotEqual(st & 0x7f, 0, "status should indicate signal or non-normal exit")
        }
    }

    func testRunIsolatedVoid_fatalErrorInChildDoesNotKillParent() {
        let parentPID = getpid()

        assertError(
            try Airlock.runIsolated {
                fatalError("deliberate isolation test")
            }
        ) { e in
            guard case .childExitedAbnormally = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
        }

        XCTAssertEqual(getpid(), parentPID)

        var status: Int32 = 0
        errno = 0
        XCTAssertEqual(waitpid(-1, &status, WNOHANG), -1)
        XCTAssertEqual(errno, ECHILD, "child should already be reaped before return")
    }

    // MARK: - runIsolated (Codable): success & payload shape

    func testRunIsolated_roundtripsPrimitivesAndOptionals() throws {
        XCTAssertNil(try Airlock.runIsolated { nil as Int? })
        XCTAssertEqual(try Airlock.runIsolated { 99 as Int? }, 99 as Int?)
        XCTAssertEqual(try Airlock.runIsolated { true }, true)
        XCTAssertEqual(try Airlock.runIsolated { [Int]() }, [])
        XCTAssertEqual(try Airlock.runIsolated { ["a", "b"] }, ["a", "b"])
    }

    func testRunIsolated_roundtripsUnicode() throws {
        let s = "Hello 日本語 🎉"
        XCTAssertEqual(try Airlock.runIsolated { s }, s)
        XCTAssertEqual(try Airlock.runIsolated { Sample(k: s, n: -1) }, Sample(k: s, n: -1))
    }

    func testRunIsolated_decodesCodableResultFromSharedMemory() throws {
        let r = try Airlock.runIsolated { Sample(k: "a", n: 7) }
        XCTAssertEqual(r, Sample(k: "a", n: 7))
    }

    func testRunIsolated_roundtripsNestedAndCollections() throws {
        struct Box: Codable, Equatable {
            var items: [Int]
            var top: [String: String]
        }
        let value = Box(items: [1, 2, 3], top: ["x": "y"])
        let out = try Airlock.runIsolated { value }
        XCTAssertEqual(out, value)
    }

    // MARK: - runIsolated (Codable): shmemSize

    func testRunIsolated_invalidShmemSize_throws() {
        assertError(try Airlock.runIsolated(shmemSize: 8) { Sample(k: "x", n: 1) }) { e in
            guard case .invalidShmemSize = e else {
                return XCTFail("expected invalidShmemSize, got \(e)")
            }
        }
    }

    func testRunIsolated_invalidShmemSize_zero_throws() {
        assertError(try Airlock.runIsolated(shmemSize: 0) { true }) { e in
            guard case .invalidShmemSize = e else {
                return XCTFail("expected invalidShmemSize, got \(e)")
            }
        }
    }

    func testRunIsolated_invalidShmemSize_negative_throws() {
        assertError(try Airlock.runIsolated(shmemSize: -1) { true }) { e in
            guard case .invalidShmemSize = e else {
                return XCTFail("expected invalidShmemSize, got \(e)")
            }
        }
    }

    /// `{}` JSON is 2 bytes; header is 8 → needs 10 bytes total.
    func testRunIsolated_minimumShmemSize_exactFit_succeeds() throws {
        let v = try Airlock.runIsolated(shmemSize: 10) { Empty() }
        XCTAssertEqual(v, Empty())
    }

    func testRunIsolated_minimumShmemSize_oneByteShort_throwsChildExitCode2() {
        assertError(try Airlock.runIsolated(shmemSize: 9) { Empty() }) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode(2), got \(e)")
            }
            XCTAssertEqual(code, 2)
        }
    }

    func testRunIsolated_respectsCustomShmemSizeForLargePayload() throws {
        let big = String(repeating: "z", count: 50_000)
        let r = try Airlock.runIsolated(shmemSize: 1024 * 1024) { Sample(k: big, n: 99) }
        XCTAssertEqual(r, Sample(k: big, n: 99))
    }

    // MARK: - runIsolated (Codable): child failure modes

    func testRunIsolated_payloadTooLarge_throwsChildExitCode2() {
        assertError(
            try Airlock.runIsolated(shmemSize: 64) {
                Sample(k: String(repeating: "x", count: 256), n: 0)
            }
        ) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 2)
        }
    }

    func testRunIsolated_encodingFailureInChild_throwsChildExitCode3() {
        assertError(try Airlock.runIsolated { UnencodablePayload(marker: 1) }) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 3)
        }
    }

    func testRunIsolated_fatalErrorInChild_throwsChildExitedAbnormally() {
        assertThrowsAirlock({
            let _: Sample = try Airlock.runIsolated {
                fatalError("deliberate fatal error in isolated child")
            }
        }) { e in
            guard case .childExitedAbnormally = e else {
                return XCTFail("expected childExitedAbnormally(waitStatus:), got \(e)")
            }
        }
    }

    func testRunIsolated_parentDecodeThrows_throwsDecodingFailed() {
        assertThrowsAirlock({
            let _: UndecodablePayload = try Airlock.runIsolated { UndecodablePayload(n: 7) }
        }) { e in
            guard case .decodingFailed = e else {
                return XCTFail("expected decodingFailed, got \(e)")
            }
        }
    }

    func testRunIsolated_sigkillInCodableChild_throwsChildExitedAbnormally() {
        assertError(
            try Airlock.runIsolated {
                kill(getpid(), SIGKILL)
                return Sample(k: "", n: 0)
            }
        ) { e in
            guard case .childExitedAbnormally(let st) = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
            XCTAssertNotEqual(st & 0x7f, 0)
        }
    }

    func testRunIsolated_childExplicitNonZeroExit_throwsChildExitCode() {
        assertError(
            try Airlock.runIsolated {
                _exit(88)
            }
        ) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 88)
        }
    }

    // MARK: - Stress

    /// 1000 overlapping isolations: each child sleeps 100 ms then returns its index; parent waits for all.
    func testStress_1000ParallelForksEachWaits100ms_returnsAllIndices() async throws {
        executionTimeAllowance = 600

        let count = 1000
        let childDelay: TimeInterval = 0.1

        let values = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<count {
                group.addTask(priority: .userInitiated) {
                    try Airlock.runIsolated {
                        Thread.sleep(forTimeInterval: childDelay)
                        return i
                    }
                }
            }
            var collected: [Int] = []
            collected.reserveCapacity(count)
            for try await v in group {
                collected.append(v)
            }
            return collected
        }

        XCTAssertEqual(values.count, count)
        XCTAssertEqual(Set(values), Set(0..<count))
    }
}
