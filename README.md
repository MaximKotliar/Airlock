# Airlock

Run Swift work in a **forked child process** so crashes and `fatalError` stay isolated from your main process, while you keep the same **UID**, entitlements, and environment as the parent. Results can be returned to the parent as **`Codable` values** (JSON over a small shared anonymous mapping) or you can run a block with **no return value**.

## Before you use this

**Use Airlock only if you understand how `fork` works** and how to reason about **shared state** in a multiprocess model: what is inherited across the split (file descriptors, memory mappings, code), what is logically private after copy-on-write, and how that interacts with **threads, locks, and runtime services** in a real macOS app. This package does not paper over POSIX or Swift-runtime foot-guns.

If those topics are new to you, start with documentation or a dedicated helper process / **XPC** design aimed at isolation—those approaches encode clearer boundaries than ad hoc `fork` in a large codebase.

**Inspired by:** [Core Dumped — "The Weird Way Linux Creates Processes"](https://www.youtube.com/watch?v=SwIPOf2YAgI&t=903s)

## Why fork instead of a separate service?

Sometimes you need to run **risky or “unsafe” logic**—parsers, plug-ins, experimental code—where a bug might trap or abort, but you still want the **main app to keep running** with its normal permissions.

Spawning a dedicated **XPC helper** or another app target is often the right long-term design, but it is **more moving parts**: signing, plist services, Mach ports, and IPC protocols. For **crash containment** alone, **`fork`** gives you a separate address space and PID with far less ceremony: the child is a disposable clone of your process that can exit without taking the parent down.

## Memory: why this is not a full duplicate RAM spike

After `fork`, the kernel does **not** immediately copy every physical page of your process. Parent and child share the same **read-only** view of existing mappings, and writable pages are handled with **copy-on-write (COW)** when one side actually modifies them. So you get a **new process and virtual address space** without an instant **2× resident memory** snapshot of everything you had mapped. Memory use grows as **each side touches and dirties** pages, not up front as a naive “clone all RAM” would suggest.

The **return-value** API also uses a **small explicit `mmap`** region for JSON; that is separate from “how big your app already was” at fork time.

## What works well inside an isolated block

- **Produce new data** from inputs: parse, transform, validate, run algorithms, call libraries you do not fully trust.
- **Side effects that are explicitly yours**: write to a path you pass in, use APIs that are fine in a short‑lived child (mind file locks and network semantics if you share resources with the parent).

## What does *not* work / what to avoid

- **Do not treat global or shared mutable process state as authoritative** for the parent. The child is a **different process** after `fork`. Mutations to in‑memory singletons, caches, or `static` data **do not** update the parent. If it is not part of the **`Codable` return value** (or an intentional file/IPC side effect you design), assume the parent **never sees it**.
- **Do not rely on other threads** that existed in the parent. Only the forking thread’s logical flow continues in the child; locks held by other threads at `fork` time are a classic source of subtle deadlock or corruption if you run rich runtime code in the child. Airlock trades **strict POSIX “async‑signal‑safe only after fork”** rules for **practical Swift usage**—keep isolated work **bounded** and **simple** when you can.
- **Returning a value:** only what you encode as **JSON** via `Codable` crosses back (subject to `shmemSize`). Huge payloads need a larger `shmemSize` or a different IPC strategy.

## Good vs bad usage examples

These are illustrative patterns—not exhaustively safe in every app without thinking through FDs, Mach ports, and your own globals.

### Good (typical)

**Pure-ish work from inputs you capture before `runIsolated`, result returned as `Codable`:**

```swift
func parseUntrustedJSON(_ data: Data) throws -> MyModel {
    try Airlock.runIsolated {
        let obj = try JSONDecoder().decode(MyModel.self, from: data)
        return validateAndNormalize(obj)  // might fatal in buggy code paths—child dies, parent survives
    }
}
```

**Void isolation with a deliberate, explicit side effect (path decided in the parent):**

```swift
let outputURL = temporaryOutputFile()
try Airlock.runIsolated {
    renderRiskyGraphToPath(outputURL)  // crash here does not kill the app process
}
let pngData = try Data(contentsOf: outputURL)
```

**Third-party image decoder that sometimes crashes (trap / `EXC_BAD_ACCESS` on hostile bytes):**

Decode in the child and hand bytes back through a **temp file** the parent chose (`Void` `runIsolated`), so a vendor bug does not take down your app. If the child dies, the parent gets `AirlockIsolationError.childExitedAbnormally` (or a missing output file if you need to distinguish success—check the error from `runIsolated` first).

```swift
import AppKit
import Airlock

/// Stand-in for a real SDK whose native code may trap on corrupt input instead of returning an error.
enum VendorImageKit {
    static func makeImage(from data: Data) -> NSImage {
        // Replace with your vendor decode. This stub compiles; a real decoder might crash here.
        NSImage(data: data)!
    }
}

func pngData(fromUntrustedImageBytes data: Data) throws -> Data {
    let output = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString + ".png")
    defer { try? FileManager.default.removeItem(at: output) }

    try Airlock.runIsolated {
        let image = VendorImageKit.makeImage(from: data)
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try png.write(to: output, options: .atomic)
    }

    return try Data(contentsOf: output)
}
```

Replace `VendorImageKit` with your dependency; keep the **decode and encode inside** `runIsolated` so only the child executes its native stack.

### Bad (common mistakes)

**Expecting in-memory singleton / cache updates to “sync back” to the parent:**

```swift
// After fork, this runs in the CHILD. The parent's `AppModel.shared` is untouched.
// The UI will never see `items` unless you return them (e.g. Codable) or write them somewhere the parent reads.
try Airlock.runIsolated {
    AppModel.shared.items = loadItems()  // wrong mental model
}
```

**Treating `runIsolated` like “async drop-in” for anything touching shared runtime state you do not understand:**

```swift
// May touch dispatch sources, objc runtime state, half‑initialized SDK singletons, etc.
// Without auditing fork safety, this can deadlock or corrupt—not a generic “sandbox my whole app” switch.
try Airlock.runIsolated {
    MySDK.shared.doStuffThatAssumesSingleProcess()
}
```

**Assuming other threads in the parent help the child:**

```swift
// The child's process image is not “your whole app with all threads”; other threads did not fork along
// as independent runnable peers. Keep the isolated block small and self‑contained.
try Airlock.runIsolated {
    backgroundImporter.waitUntilFinished()  // fragile: who owns the queue / lock across fork?
}
```

## Contributing / Git branches

CI and git-flow (**PR → `develop` → `main`**) are described in [`.github/BRANCHING.md`](.github/BRANCHING.md) and [`.github/GITHUB_SETUP.md`](.github/GITHUB_SETUP.md).

## Requirements

- macOS 12+ (Monterey). **This package targets macOS only**—`fork(2)` is not usable on iOS, tvOS, watchOS, etc.
- Swift 6.1+ (see `Package.swift` `swift-tools-version`)

## Blocking behavior

Both `runIsolated` overloads are **synchronous and blocking** on the thread that calls them: the parent **`waitpid`**-waits until the child process exits and is reaped. The isolated work runs **off** that call stack (in the child), but the **caller does not return** until the child is done.

If you need **async** behavior—UI responsiveness, structured concurrency, background QoS—**wrap the call** yourself: e.g. `Task { … }`, `DispatchQueue.global().async { … }`, an operation queue, or your app’s own executor. Airlock stays deliberately simple; it does not ship an async wrapper.

```swift
import Airlock

struct Report: Codable, Equatable {
    var summary: String
}

// `runIsolated` still blocks the task’s thread until the child exits, but the caller can `await` without blocking the main actor.
func loadReport() async throws -> Report {
    try await Task(priority: .userInitiated) {
        try Airlock.runIsolated { Report(summary: makeReport()) }
    }.value
}

// Usage from a view / main actor:
// Task { let r = try await loadReport(); … }
```

```swift
// Example: don’t block the main thread (GCD)
DispatchQueue.global(qos: .userInitiated).async {
    let report = try? Airlock.runIsolated { makeReport() }
    DispatchQueue.main.async {
        // update UI with report
    }
}
```

## Add the package

In your `Package.swift`:

```swift
dependencies: [
    .package(path: "../Airlock") // or a Git URL / version
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "Airlock", package: "Airlock")
    ])
]
```

## Usage

### 1. Isolate side effects, no return value

The parent **waits** for the child and **reaps** it; errors map to `AirlockIsolationError` (`forkFailed`, `waitFailed`, `childExitedAbnormally`, `childExitCode`, …).

```swift
import Airlock

try Airlock.runIsolated {
    // If this fatalError runs in the child, the parent gets an error—not a crash.
    processUntrustedInput(data)
}
```

### 2. Isolate and return a `Codable` result

Default shared buffer is 1 MB; increase `shmemSize` if JSON might be larger.

```swift
import Airlock

struct Report: Codable, Equatable {
    var ok: Bool
    var summary: String
}

let report = try Airlock.runIsolated {
    Report(ok: true, summary: analyze())
}

let big = try Airlock.runIsolated(shmemSize: 4 * 1024 * 1024) {
    Report(ok: true, summary: String(repeating: "x", count: 500_000))
}
```

### 3. Handle errors

```swift
import Airlock

do {
    try Airlock.runIsolated { riskyWork() }
} catch let error as AirlockIsolationError {
    switch error {
    case .childExitedAbnormally(let status):
        // e.g. SIGABRT / trap in child
        break
    case .childExitCode(let code):
        // reserved in Codable path: 2 = JSON too large for shmemSize, 3 = encode/copy failure
        break
    case .decodingFailed(let underlying):
        break
    default:
        break
    }
}
```

## License

[Zero-Clause BSD (0BSD)](https://opensource.org/licenses/0BSD) — see [`LICENSE`](LICENSE). You may use, modify, and distribute this software **without** retaining copyright or license notices in your own distributions (permissive “no notice” open source).
