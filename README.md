# Airlock

Run Swift work in an **isolated child process** so crashes and `fatalError` stay contained, while you keep the same **UID**, entitlements, and environment as the parent. Results flow as **`Codable` values** through POSIX shared memory.

Airlock provides **two isolation mechanisms**:

| | **`run` (safe, preferred)** | **`runUnsafely` (fork-based)** |
|---|---|---|
| Mechanism | `posix_spawn` — fresh process | `fork()` — clone of current process |
| Child state | Clean: full runtime, threads, ARC | Fragile: only the forking thread survives |
| API style | Struct-based `AirlockTask` with `Codable` I/O | Closure-based |
| Swift safety | Full — no post-fork caveats | Unsafe — see warnings below |

## Requirements

- macOS 12+ (Monterey). **This package targets macOS only** — `fork(2)` / `posix_spawn` are not usable on iOS, tvOS, watchOS, etc.
- Swift 6.1+ (see `Package.swift` `swift-tools-version`)

## Safe approach: struct-based tasks (`Airlock.run`)

The preferred API. The current executable is re-launched via `posix_spawn`. A C-level `__attribute__((constructor))` detects the child argument before `main()` runs; on the Swift side, `register(_:)` matches the task and diverts execution.

I/O flows through an **anonymous shared-memory fd** — the parent creates the region with `shm_open`, unlinks the name **immediately** (before spawn), and passes only the fd number to the child. No task names, shmem names, or other identifying information appear in `argv` or the filesystem. Only the parent and child hold the fd.

Because the child is a **fresh process**, there are **no fork safety concerns** — threads, ARC, locks, and the full Swift runtime work normally.

The child process inherits `SWIFT_BACKTRACE=enable=no` in its environment, preventing Swift's crash handler from printing interactive backtraces or blocking on stdin when the child crashes.

### 1. Define a task

```swift
import Airlock

struct ParseTask: AirlockTask {
    struct Input: Codable  { var rawJSON: String }
    struct Output: Codable { var itemCount: Int }

    static func main(_ input: Input) throws -> Output {
        let items = try JSONDecoder().decode([Item].self, from: Data(input.rawJSON.utf8))
        return Output(itemCount: items.count)
    }
}
```

Each task is a struct conforming to `AirlockTask` with:
- `Input` — `Codable` value sent to the child
- `Output` — `Codable` value returned to the parent
- `static func main(_:)` — entry point executed in the child process

### 2. Register tasks at startup

At the top of your executable's entry point, register all task types and seal with `engage()`:

```swift
import Airlock

// Register tasks — required in both parent and child.
// In a child, the matching register call runs the task and _exit()s.
// In the parent, it records the identifier so run() can validate it.
Airlock.register(ParseTask.self)
Airlock.register(RenderTask.self)
Airlock.engage()  // safety net: exits child if no task matched

// Normal app code (only reached in the parent process)
// ...
```

`register(_:)` records the task identifier in both parent and child. In the parent, this enables a `precondition` in `run(_:input:)` that traps immediately if you try to run an unregistered task. In a child, it reads the task identifier from the shared memory header and, if it matches, runs the task and exits. `engage()` ensures a child never falls through into your app logic if no task matched.

### 3. Run a task

```swift
let output = try Airlock.run(ParseTask.self, input: .init(rawJSON: jsonString))
print("Parsed \(output.itemCount) items")
```

`run(_:input:)` is **synchronous and blocking** — the parent waits for the child to finish. Wrap in `Task { }` or `DispatchQueue` if you need async behavior.

Calling `run` with a task type that was never passed to `register` triggers a **precondition failure** with a descriptive message.

### 4. Handle errors

```swift
do {
    let output = try Airlock.run(ParseTask.self, input: myInput)
} catch let error as AirlockError {
    switch error {
    case .childExitedAbnormally(let status):
        // Child crashed (SIGABRT, EXC_BAD_ACCESS, etc.)
        break
    case .childExitCode(let code):
        // Child exited with non-zero code:
        // 2 = output too large, 3 = input decode failed,
        // 4 = task main() threw, 5 = output encode failed
        break
    case .decodingFailed(let underlying):
        // Parent could not decode the child's output
        break
    case .spawnFailed:
        // posix_spawn failed
        break
    default:
        break
    }
}
```

### Custom task identifier

By default, the task identifier is the Swift type name. Override it if you need stability across modules:

```swift
struct ParseTask: AirlockTask {
    static var identifier: String { "com.myapp.parse" }
    // ...
}
```

### Custom executable path

By default, `run` re-execs the current process. You can point to a different binary:

```swift
let output = try Airlock.run(ParseTask.self,
                             input: myInput,
                             executable: "/path/to/helper")
```

The target binary must register the same task types.

### Shared memory size

Default is 1 MB. The region must fit the task identifier, the encoded input, **and** the encoded output (each with a small length header). Increase `shmemSize` if needed:

```swift
let output = try Airlock.run(BigTask.self,
                             input: bigInput,
                             shmemSize: 8 * 1024 * 1024)
```

## Unsafe approach: fork-based (`Airlock.runUnsafely`)

A lightweight `fork()`-based API for quick isolation without defining task structs. The parent forks, the child runs a closure, and crashes stay in the child.

### Before you use this

**Use `runUnsafely` only if you understand how `fork` works** and how to reason about **shared state** in a multiprocess model: what is inherited across the split (file descriptors, memory mappings, code), what is logically private after copy-on-write, and how that interacts with **threads, locks, and the Swift runtime** (ARC, allocators, libdispatch).

After `fork`, only the forking thread survives in the child. Locks held by other threads at fork time become permanently locked. The Swift runtime (ARC, allocators, libdispatch) is **not** safe to use freely in the child. The **ideal** shape is a **C library** behind a Swift **`struct`** wrapper on a path where **ARC is not involved**.

If those constraints are too restrictive, use the safe `Airlock.run` API instead.

### Void isolation

```swift
try Airlock.runUnsafely {
    processUntrustedInput(data)
    // If this crashes, the parent gets an error — not a crash.
}
```

### Returning a Codable result

```swift
struct Report: Codable { var ok: Bool; var summary: String }

let report = try Airlock.runUnsafely {
    Report(ok: true, summary: analyze())
}
```

### What works inside a fork-based isolated block

- **Ideal:** a **C library** behind a **`struct`** type in Swift — **no ARC** in the child work (no classes, no `String`/`Array`/`Data` in hot paths unless you accept refcount traffic).
- **Riskier outliers:** pure-ish or allocation-bounded Swift — value-heavy code you have **audited** — still **not** a guarantee for arbitrary Swift.
- **Side effects that are explicitly yours**: write to a path you pass in, use APIs that are fine in a short-lived child.

### What does not work / what to avoid

- **Global or shared mutable process state** — mutations to in-memory singletons, caches, or `static` data do **not** update the parent.
- **Other threads** — only the forking thread continues in the child. Locks held by other threads at fork time are a classic source of deadlock.
- **Large Codable payloads** — subject to `shmemSize`. Use a file or different IPC for huge data.

## Blocking behavior

Both `run` and `runUnsafely` are **synchronous and blocking**: the parent waits until the child exits. If you need async behavior, wrap the call yourself:

```swift
func loadReport() async throws -> Report {
    try await Task(priority: .userInitiated) {
        try Airlock.run(ReportTask.self, input: .init())
    }.value
}
```

## Why not XPC?

Spawning a dedicated **XPC helper** or another app target is often the right long-term design, but it involves more moving parts: signing, plist services, Mach ports, and IPC protocols. Airlock gives you a separate process with less ceremony — especially the safe `run` API, which gives you full process isolation with just a struct definition and a `register` call.

## Inspiration

**Inspired by:** [Core Dumped — "The Weird Way Linux Creates Processes"](https://www.youtube.com/watch?v=SwIPOf2YAgI)

## Contributing / Git branches

CI and git-flow (**PR -> `develop` -> `main`**) are described in [`.github/BRANCHING.md`](.github/BRANCHING.md) and [`.github/GITHUB_SETUP.md`](.github/GITHUB_SETUP.md).

## License

[Zero-Clause BSD (0BSD)](https://opensource.org/licenses/0BSD) — see [`LICENSE`](LICENSE). You may use, modify, and distribute this software **without** retaining copyright or license notices in your own distributions.
