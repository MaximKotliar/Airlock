import Darwin
import Foundation
import libAirlock

// MARK: - Errors

public enum AirlockError: Error {
    case forkFailed(errno: Int32)
    case spawnFailed
    case waitFailed(errno: Int32)
    /// Child terminated by signal or stopped; `waitStatus` is the raw `waitpid` status.
    case childExitedAbnormally(waitStatus: Int32)
    /// Child called `_exit` with a non-zero code.
    ///
    /// Reserved codes:
    /// - `2` — output JSON too large for `shmemSize`
    /// - `3` — input decoding failed in child
    /// - `4` — task `main` threw
    /// - `5` — output encoding failed in child
    /// - `10` — child setup failed (shmem / fd / mmap)
    /// - `11` — no registered task matched (``engage()`` safety exit)
    case childExitCode(Int32)
    case sharedMemoryFailed
    case invalidShmemSize
    case inputTooLarge
    case invalidPayloadLength(UInt64)
    case encodingFailed(any Error)
    case decodingFailed(any Error)
}

// MARK: - Airlock

/// Process isolation for macOS — two mechanisms:
///
/// 1. **`runUnsafely`** — lightweight `fork()`-based isolation.
///    Run a closure in a forked child; crashes stay in the child.
///    Ideal for quick, bounded work with C / struct-heavy code.
///    ⚠️ All `fork` caveats apply (threads, locks, ARC).
///
/// 2. **`run(_:input:)`** — struct-based task isolation via `posix_spawn`.
///    Re-launches the current executable with `--airlock <fd> <size>`.
///    A C-level `__attribute__((constructor))` detects the argument;
///    ``register(_:)`` matches the task and diverts execution.
///    I/O flows through an anonymous shared-memory fd (name unlinked
///    before spawn — only parent and child can access it).
///    Fully safe — the child is a fresh process.
public enum Airlock {

    /// Identifiers of tasks registered via ``register(_:)``.
    private nonisolated(unsafe) static var registeredTasks: Set<String> = []

    // MARK: - fork-based isolation (runUnsafely)

    /// Runs `action` in a forked child.  The parent blocks on `waitpid`
    /// until the child exits and is reaped (no return value).
    ///
    /// A crash or `fatalError` inside `action` ends the child, not the parent.
    ///
    /// - Warning: Uses `fork()`. All POSIX post-fork caveats apply — threads,
    ///   locks, ARC, and the Swift runtime are **not** safe after fork in a
    ///   multithreaded process. Prefer ``run(_:input:shmemSize:executable:)``
    ///   for safe isolation.
    @inline(never)
    public static func runUnsafely(action: () -> Void) throws {
        let pid = airlock_fork()
        if pid == 0 {
            defer { _exit(0) }
            autoreleasepool { action() }
            return
        }
        guard pid > 0 else { throw AirlockError.forkFailed(errno: errno) }

        let status = try airlockWait(pid: pid)
        let exitedNormally = (status & 0x7f) == 0
        guard exitedNormally else {
            throw AirlockError.childExitedAbnormally(waitStatus: status)
        }
        let exitCode = (status >> 8) & 0xff
        guard exitCode == 0 else {
            throw AirlockError.childExitCode(Int32(exitCode))
        }
    }

    /// Runs `action` in a forked child and returns its `Codable` result
    /// via anonymous shared memory (`MAP_ANON | MAP_SHARED`).
    ///
    /// - Warning: Uses `fork()`. See ``runUnsafely(action:)`` for caveats.
    @inline(never)
    public static func runUnsafely<Result: Codable>(
        shmemSize: Int = 1024 * 1024,
        action: () -> Result
    ) throws -> Result {
        let header = MemoryLayout<UInt64>.size
        guard shmemSize > header else { throw AirlockError.invalidShmemSize }

        guard let baseRaw = airlock_mmap_shared_anon(shmemSize) else {
            throw AirlockError.sharedMemoryFailed
        }
        let base = UnsafeMutableRawPointer(baseRaw)
        defer { airlock_munmap(baseRaw, shmemSize) }

        let forkedPID = airlock_fork()
        if forkedPID == 0 {
            let result = autoreleasepool(invoking: action)
            guard let data = try? JSONEncoder().encode(result) else { _exit(3) }
            guard data.count <= shmemSize - header else { _exit(2) }
            data.withUnsafeBytes { raw in
                guard let src = raw.baseAddress else { _exit(3) }
                memcpy(base.advanced(by: header), src, data.count)
            }
            var lenBE = UInt64(data.count).bigEndian
            memcpy(base, &lenBE, header)
            msync(base, shmemSize, MS_SYNC)
            _exit(0)
        }
        guard forkedPID > 0 else { throw AirlockError.forkFailed(errno: errno) }

        let status = try airlockWait(pid: forkedPID)
        let exitedNormally = (status & 0x7f) == 0
        guard exitedNormally else {
            throw AirlockError.childExitedAbnormally(waitStatus: status)
        }
        let exitCode = (status >> 8) & 0xff
        guard exitCode == 0 else {
            throw AirlockError.childExitCode(Int32(exitCode))
        }

        var lenBE: UInt64 = 0
        memcpy(&lenBE, base, header)
        let payloadLength = UInt64(bigEndian: lenBE)
        guard payloadLength <= UInt64(shmemSize - header) else {
            throw AirlockError.invalidPayloadLength(payloadLength)
        }
        guard let n = Int(exactly: payloadLength) else {
            throw AirlockError.invalidPayloadLength(payloadLength)
        }
        let json = Data(bytes: base.advanced(by: header), count: n)
        do {
            return try JSONDecoder().decode(Result.self, from: json)
        } catch {
            throw AirlockError.decodingFailed(error)
        }
    }

    // MARK: - re-exec task API

    // MARK: Task registration (child-side hook)

    /// Register a task type for child dispatch.
    ///
    /// If this process was spawned as a child for the given task, it runs
    /// immediately and **the process exits** — subsequent code is never reached.
    /// In the parent process this records the identifier for validation.
    ///
    /// Call once per task type at app startup, **before** ``engage()``.
    public static func register<T: AirlockTask>(_ type: T.Type) {
        registeredTasks.insert(T.identifier)

        guard airlock_is_child() != 0 else { return }

        // mmap the inherited fd and read the task identifier from the header.
        let fd   = airlock_child_fd()
        let size = airlock_child_shmem_size()
        guard fd >= 0, size > 0 else { return }

        guard let base = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_SHARED, Int32(fd), 0),
              base != MAP_FAILED else { return }
        let ptr = UnsafeMutableRawPointer(base)

        // Header: [task_id_len: UInt32 BE][task_id bytes][input_len: UInt64 BE][input...]
        let u32 = MemoryLayout<UInt32>.size
        guard size >= u32 else {
            munmap(base, size)
            return
        }

        var idLenBE: UInt32 = 0
        memcpy(&idLenBE, ptr, u32)
        let idLen = Int(UInt32(bigEndian: idLenBE))
        guard idLen > 0, size >= u32 + idLen else {
            munmap(base, size)
            return
        }

        let idBytes = Data(bytes: ptr.advanced(by: u32), count: idLen)
        guard let taskID = String(data: idBytes, encoding: .utf8),
              taskID == T.identifier else {
            munmap(base, size)
            return
        }

        childExecute(T.self, ptr: ptr, size: size, inputOffset: u32 + idLen)
    }

    /// Safety net: if this process is a child and no registered task matched,
    /// exits immediately with code 11.  No-op in the parent.
    ///
    /// Place after all ``register(_:)`` calls.
    public static func engage() {
        guard airlock_is_child() != 0 else { return }
        _exit(11)
    }

    // MARK: Running a task (parent side)

    /// Run a task in an isolated child process.  Blocks until the child exits.
    ///
    /// The current executable (or `executable`, if provided) is launched via
    /// `posix_spawn`. The task identifier and encoded input are packed into
    /// an anonymous shared-memory region whose fd is inherited by the child.
    /// No names or task identifiers appear in `argv` — only the fd number
    /// and region size.
    ///
    /// - Parameters:
    ///   - type: The ``AirlockTask`` conforming type.
    ///   - input: Value to send to the child.
    ///   - shmemSize: Byte budget for the shared memory region (must fit the
    ///     task identifier, encoded input, **and** the encoded output).
    ///   - executable: Absolute path to the binary to spawn.
    ///     Pass `nil` (default) to re-exec the current process.
    public static func run<T: AirlockTask>(
        _ type: T.Type,
        input: T.Input,
        shmemSize: Int = 1024 * 1024,
        executable: String? = nil
    ) throws -> T.Output {
        precondition(
            registeredTasks.contains(T.identifier),
            "Airlock.run(\(T.self)): task \"\(T.identifier)\" was never registered. Call Airlock.register(\(T.self).self) at startup."
        )

        let u32 = MemoryLayout<UInt32>.size
        let u64 = MemoryLayout<UInt64>.size
        guard shmemSize > u32 + u64 else { throw AirlockError.invalidShmemSize }

        // Create anonymous shmem (name already unlinked inside C).
        let fd = airlock_shmem_create(shmemSize)
        guard fd >= 0 else { throw AirlockError.sharedMemoryFailed }
        defer { close(fd) }

        // mmap.
        guard let base = mmap(nil, shmemSize, PROT_READ | PROT_WRITE,
                              MAP_SHARED, fd, 0),
              base != MAP_FAILED else {
            throw AirlockError.sharedMemoryFailed
        }
        let ptr = UnsafeMutableRawPointer(base)
        defer { munmap(base, shmemSize) }

        // Encode input.
        let inputData: Data
        do {
            inputData = try JSONEncoder().encode(input)
        } catch {
            throw AirlockError.encodingFailed(error)
        }

        // Pack header: [task_id_len: u32 BE][task_id][input_len: u64 BE][input]
        let idBytes = Array(T.identifier.utf8)
        let headerSize = u32 + idBytes.count + u64
        guard headerSize + inputData.count <= shmemSize else {
            throw AirlockError.inputTooLarge
        }

        var idLenBE = UInt32(idBytes.count).bigEndian
        memcpy(ptr, &idLenBE, u32)
        _ = idBytes.withUnsafeBufferPointer { buf in
            memcpy(ptr.advanced(by: u32), buf.baseAddress!, idBytes.count)
        }
        var inputLenBE = UInt64(inputData.count).bigEndian
        memcpy(ptr.advanced(by: u32 + idBytes.count), &inputLenBE, u64)
        inputData.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                memcpy(ptr.advanced(by: headerSize), src, inputData.count)
            }
        }

        // Spawn child — only passes fd number and size in argv.
        let pid = airlock_spawn(executable, fd, shmemSize)
        guard pid > 0 else { throw AirlockError.spawnFailed }

        // Wait for exit.
        let status = try airlockWait(pid: pid)

        let exitedNormally = (status & 0x7f) == 0
        guard exitedNormally else {
            throw AirlockError.childExitedAbnormally(waitStatus: status)
        }
        let exitCode = (status >> 8) & 0xff
        guard exitCode == 0 else {
            throw AirlockError.childExitCode(Int32(exitCode))
        }

        // Decode output — child overwrote buffer with [output_len: u64 BE][output].
        var outLenBE: UInt64 = 0
        memcpy(&outLenBE, ptr, u64)
        let outLen = UInt64(bigEndian: outLenBE)
        guard outLen <= UInt64(shmemSize - u64) else {
            throw AirlockError.invalidPayloadLength(outLen)
        }
        guard let n = Int(exactly: outLen) else {
            throw AirlockError.invalidPayloadLength(outLen)
        }

        let json = Data(bytes: ptr.advanced(by: u64), count: n)
        do {
            return try JSONDecoder().decode(T.Output.self, from: json)
        } catch {
            throw AirlockError.decodingFailed(error)
        }
    }
}

// MARK: - Child execution (never returns)

private extension Airlock {

    static func childExecute<T: AirlockTask>(
        _ type: T.Type,
        ptr: UnsafeMutableRawPointer,
        size: Int,
        inputOffset: Int
    ) -> Never {
        let u64 = MemoryLayout<UInt64>.size

        guard inputOffset + u64 <= size else { _exit(10) }

        // Read input length.
        var inputLenBE: UInt64 = 0
        memcpy(&inputLenBE, ptr.advanced(by: inputOffset), u64)
        let inputLen = UInt64(bigEndian: inputLenBE)
        let dataOffset = inputOffset + u64
        guard inputLen <= UInt64(size - dataOffset),
              let n = Int(exactly: inputLen) else { _exit(10) }

        let inputJSON = Data(bytes: ptr.advanced(by: dataOffset), count: n)

        guard let input = try? JSONDecoder().decode(T.Input.self, from: inputJSON) else {
            _exit(3)
        }

        let output: T.Output
        do {
            output = try T.main(input)
        } catch {
            _exit(4)
        }

        guard let outputData = try? JSONEncoder().encode(output) else { _exit(5) }
        guard outputData.count + u64 <= size else { _exit(2) }

        // Overwrite buffer: [output_len: u64 BE][output JSON]
        var outLenBE = UInt64(outputData.count).bigEndian
        memcpy(ptr, &outLenBE, u64)
        outputData.withUnsafeBytes { raw in
            guard let src = raw.baseAddress else { _exit(5) }
            memcpy(ptr.advanced(by: u64), src, outputData.count)
        }

        msync(ptr, size, MS_SYNC)
        munmap(ptr, size)
        close(Int32(airlock_child_fd()))
        _exit(0)
    }
}

// MARK: - waitpid helper

/// Blocks until `pid` exits, retrying on `EINTR`.
private func airlockWait(pid: pid_t) throws -> Int32 {
    var status: Int32 = 0
    while true {
        let reaped = waitpid(pid, &status, 0)
        if reaped == pid { return status }
        if reaped == -1 {
            let err = errno
            if err == EINTR { continue }
            throw AirlockError.waitFailed(errno: err)
        }
        throw AirlockError.waitFailed(errno: errno)
    }
}
