import Darwin
import Foundation
import Shims

/// Errors from ``Airlock/runIsolated(shmemSize:action:)``. For ``childExitCode``, this package uses
/// `2` when the JSON result does not fit in `shmemSize` (after the 8-byte length prefix) and `3` when encoding or copying the payload fails.
public enum AirlockIsolationError: Error {
    case sharedMemoryMapFailed
    case forkFailed(errno: Int32)
    case waitFailed(errno: Int32)
    /// Child terminated by signal or stopped; `waitStatus` is the raw `waitpid` status.
    case childExitedAbnormally(waitStatus: Int32)
    /// Child called `_exit` with a non-zero code (see enum documentation for reserved codes).
    case childExitCode(Int32)
    case invalidPayloadLength(UInt64)
    case decodingFailed(Swift.Error)
    /// `shmemSize` was not larger than the 8-byte on-wire length prefix.
    case invalidShmemSize
}

public enum Airlock {

    /// Runs `action` in a forked child. The parent blocks on `waitpid` until the child exits and is reaped (no return value).
    ///
    /// The child ends with `_exit(0)` after `action`.
    public static func runIsolated(action: @escaping () -> Void) throws {
        let pid = airlock_fork()
        if pid == 0 {
            defer { _exit(0) }
            action()
            return
        }
        guard pid > 0 else { throw AirlockIsolationError.forkFailed(errno: errno) }

        let status = try airlockWaitForChild(pid: pid)
        let exitedNormally = (status & 0x7f) == 0
        guard exitedNormally else { throw AirlockIsolationError.childExitedAbnormally(waitStatus: status) }
        let exitCode = (status >> 8) & 0xff
        guard exitCode == 0 else { throw AirlockIsolationError.childExitCode(Int32(exitCode)) }
    }
}

public extension Airlock {

    /// Runs `action` in a forked child and returns its value in the parent via anonymous shared memory (`MAP_ANON` | `MAP_SHARED`).
    ///
    /// The mapping is created before `fork` so parent and child share the same region: 8-byte big-endian payload length, then JSON.
    ///
    /// `fork` in a multithreaded Swift process is POSIX-unsafe between `fork` and `exec`; running arbitrary Swift in the child can fail if other threads held locks at fork time. This API intentionally trades strict POSIX semantics for convenience.
    ///
    /// - Note: To run `action` in a child without returning a decoded value, use ``Airlock/runIsolated(action:)``.
    static func runIsolated<Result: Codable>(shmemSize: Int = 1024 * 1024, action: @escaping () -> Result) throws -> Result {
        let header = MemoryLayout<UInt64>.size
        guard shmemSize > header else {
            throw AirlockIsolationError.invalidShmemSize
        }

        guard let baseRaw = airlock_mmap_shared_anon(shmemSize) else {
            throw AirlockIsolationError.sharedMemoryMapFailed
        }
        let base = UnsafeMutableRawPointer(baseRaw)
        defer { airlock_munmap(baseRaw, shmemSize) }

        let forkedPID = airlock_fork()
        if forkedPID == 0 {
            // Child path: write JSON after header, then length prefix so the parent never sees a claimed size before data is present.
            let result = action()
            guard let resultData = try? JSONEncoder().encode(result) else { _exit(3) }
            // Compare without `count + header` to avoid Int overflow for huge `Data`.
            guard resultData.count <= shmemSize - header else { _exit(2) }
            resultData.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else {
                    _exit(3)
                }
                memcpy(base.advanced(by: header), src, resultData.count)
            }
            var lenBE = UInt64(resultData.count).bigEndian
            memcpy(base, &lenBE, header)
            msync(base, shmemSize, MS_SYNC)
            _exit(0)
        }

        guard forkedPID > 0 else {
            throw AirlockIsolationError.forkFailed(errno: errno)
        }

        let status = try airlockWaitForChild(pid: forkedPID)

        let exitedNormally = (status & 0x7f) == 0
        guard exitedNormally else {
            throw AirlockIsolationError.childExitedAbnormally(waitStatus: status)
        }
        let exitCode = (status >> 8) & 0xff
        guard exitCode == 0 else {
            throw AirlockIsolationError.childExitCode(Int32(exitCode))
        }

        var lenBE: UInt64 = 0
        memcpy(&lenBE, base, header)
        let payloadLength = UInt64(bigEndian: lenBE)
        guard payloadLength <= UInt64(shmemSize - header) else {
            throw AirlockIsolationError.invalidPayloadLength(payloadLength)
        }
        guard let n = Int(exactly: payloadLength) else {
            throw AirlockIsolationError.invalidPayloadLength(payloadLength)
        }
        let json = Data(bytes: base.advanced(by: header), count: n)
        do {
            return try JSONDecoder().decode(Result.self, from: json)
        } catch {
            throw AirlockIsolationError.decodingFailed(error)
        }
    }
}

/// Blocks until `pid` exits, retrying on `EINTR` (signal-interrupted `waitpid`).
fileprivate func airlockWaitForChild(pid: pid_t) throws -> Int32 {
    var status: Int32 = 0
    while true {
        let reaped = waitpid(pid, &status, 0)
        if reaped == pid {
            return status
        }
        if reaped == -1 {
            let err = errno
            if err == EINTR {
                continue
            }
            throw AirlockIsolationError.waitFailed(errno: err)
        }
        throw AirlockIsolationError.waitFailed(errno: errno)
    }
}
