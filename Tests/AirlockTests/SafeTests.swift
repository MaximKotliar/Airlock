import Darwin
import Foundation
import XCTest
import Airlock

/// Tests for the safe re-exec task API (`Airlock.run`).
final class SafeTests: XCTestCase {

    /// Path to the TestHelper binary built alongside the test bundle.
    private nonisolated(unsafe) static var helperPath: String!

    override class func setUp() {
        super.setUp()

        Airlock.register(EchoTask.self)
        Airlock.register(PIDTask.self)
        Airlock.register(UnicodeTask.self)
        Airlock.register(LargePayloadTask.self)
        Airlock.register(ThrowingTask.self)
        Airlock.register(FatalTask.self)
        Airlock.register(SIGKILLTask.self)
        Airlock.register(SlowTask.self)
        Airlock.register(EmptyIOTask.self)

        let bundle = Bundle(for: SafeTests.self)
        let buildDir = URL(fileURLWithPath: bundle.bundlePath).deletingLastPathComponent()
        let candidate = buildDir.appendingPathComponent("TestHelper").path

        guard FileManager.default.isExecutableFile(atPath: candidate) else {
            fatalError("TestHelper not found at \(candidate). Run `swift build` first.")
        }
        helperPath = candidate
    }

    private var helper: String { Self.helperPath }

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

    // MARK: - Basic round-trip

    func testEchoRoundtrip() throws {
        let input = EchoTask.Input(text: "hello", number: 42)
        let output = try Airlock.run(EchoTask.self, input: input, executable: helper)
        XCTAssertEqual(output.text, "hello")
        XCTAssertEqual(output.number, 42)
    }

    func testChildRunsInSeparateProcess() throws {
        let parent = getpid()
        let output = try Airlock.run(PIDTask.self,
                                     input: .init(parentPID: parent),
                                     executable: helper)
        XCTAssertEqual(output.parentPID, parent)
        XCTAssertNotEqual(output.childPID, parent, "child must be a different PID")
        XCTAssertGreaterThan(output.childPID, 0)
    }

    // MARK: - Unicode

    func testUnicodeRoundtrip() throws {
        let text = "Hello 日本語 🎉 ñ ü"
        let output = try Airlock.run(UnicodeTask.self,
                                     input: .init(text: text),
                                     executable: helper)
        XCTAssertEqual(output.text, text)
    }

    // MARK: - Empty I/O

    func testEmptyIOTask() throws {
        let output = try Airlock.run(EmptyIOTask.self,
                                     input: .init(),
                                     executable: helper)
        XCTAssertEqual(output, EmptyIOTask.Output())
    }

    // MARK: - shmemSize validation

    func testInvalidShmemSize_tooSmall_throws() {
        assertError(
            try Airlock.run(EchoTask.self,
                            input: .init(text: "", number: 0),
                            shmemSize: 8,
                            executable: helper)
        ) { e in
            guard case .invalidShmemSize = e else {
                return XCTFail("expected invalidShmemSize, got \(e)")
            }
        }
    }

    func testInvalidShmemSize_zero_throws() {
        assertError(
            try Airlock.run(EchoTask.self,
                            input: .init(text: "", number: 0),
                            shmemSize: 0,
                            executable: helper)
        ) { e in
            guard case .invalidShmemSize = e else {
                return XCTFail("expected invalidShmemSize, got \(e)")
            }
        }
    }

    // MARK: - Large payload

    func testLargePayload() throws {
        let output = try Airlock.run(
            LargePayloadTask.self,
            input: .init(repeatedChar: "z", count: 50_000),
            shmemSize: 1024 * 1024,
            executable: helper
        )
        XCTAssertEqual(output.payload.count, 50_000)
        XCTAssertTrue(output.payload.allSatisfy { $0 == "z" })
    }

    // MARK: - Child failure modes

    func testThrowingTask_throwsChildExitCode4() {
        assertError(
            try Airlock.run(ThrowingTask.self, input: .init(), executable: helper)
        ) { e in
            guard case .childExitCode(let code) = e else {
                return XCTFail("expected childExitCode, got \(e)")
            }
            XCTAssertEqual(code, 4, "exit code 4 = task main() threw")
        }
    }

    func testFatalError_throwsChildExitedAbnormally() {
        assertError(
            try Airlock.run(FatalTask.self, input: .init(), executable: helper)
        ) { e in
            guard case .childExitedAbnormally = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
        }
    }

    func testSIGKILL_throwsChildExitedAbnormally() {
        assertError(
            try Airlock.run(SIGKILLTask.self, input: .init(), executable: helper)
        ) { e in
            guard case .childExitedAbnormally(let st) = e else {
                return XCTFail("expected childExitedAbnormally, got \(e)")
            }
            XCTAssertNotEqual(st & 0x7f, 0, "status should indicate signal termination")
        }
    }

    // MARK: - Stress

    func testStress_100ParallelTasks() async throws {
        executionTimeAllowance = 120
        let count = 100

        let results = try await withThrowingTaskGroup(of: Int.self) { group in
            for i in 0..<count {
                let path = helper
                group.addTask(priority: .userInitiated) {
                    let out = try Airlock.run(
                        SlowTask.self,
                        input: .init(index: i, delayMs: 50),
                        executable: path
                    )
                    return out.index
                }
            }
            var collected: [Int] = []
            collected.reserveCapacity(count)
            for try await v in group { collected.append(v) }
            return collected
        }

        XCTAssertEqual(results.count, count)
        XCTAssertEqual(Set(results), Set(0..<count))
    }
}
