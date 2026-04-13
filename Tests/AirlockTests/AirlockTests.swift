import Darwin
import Foundation
import XCTest
import Airlock

// Task I/O types that mirror the TestHelper definitions.
// Only the Codable shapes matter — the task logic lives in the TestHelper binary.

enum Tasks {
    enum Echo {
        struct Input: Codable, Equatable  { var text: String; var number: Int }
        struct Output: Codable, Equatable { var text: String; var number: Int }
    }
    enum PID {
        struct Input: Codable  { var parentPID: Int32 }
        struct Output: Codable { var childPID: Int32; var parentPID: Int32 }
    }
    enum Unicode {
        struct Input: Codable, Equatable  { var text: String }
        struct Output: Codable, Equatable { var text: String }
    }
    enum LargePayload {
        struct Input: Codable, Equatable  { var repeatedChar: String; var count: Int }
        struct Output: Codable, Equatable { var payload: String }
    }
    enum Throwing {
        struct Input: Codable {}
        struct Output: Codable { var x: Int }
    }
    enum Fatal {
        struct Input: Codable {}
        struct Output: Codable { var x: Int }
    }
    enum SIGKILL {
        struct Input: Codable {}
        struct Output: Codable { var x: Int }
    }
    enum Slow {
        struct Input: Codable  { var index: Int; var delayMs: Int }
        struct Output: Codable { var index: Int }
    }
    enum EmptyIO {
        struct Input: Codable, Equatable {}
        struct Output: Codable, Equatable {}
    }
}

// Lightweight stubs that satisfy AirlockTask so we can call Airlock.run
// from the parent (test) process.  main() is never called here — it runs
// in the TestHelper child.

struct EchoTask: AirlockTask {
    typealias Input  = Tasks.Echo.Input
    typealias Output = Tasks.Echo.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct PIDTask: AirlockTask {
    typealias Input  = Tasks.PID.Input
    typealias Output = Tasks.PID.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct UnicodeTask: AirlockTask {
    typealias Input  = Tasks.Unicode.Input
    typealias Output = Tasks.Unicode.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct LargePayloadTask: AirlockTask {
    typealias Input  = Tasks.LargePayload.Input
    typealias Output = Tasks.LargePayload.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct ThrowingTask: AirlockTask {
    typealias Input  = Tasks.Throwing.Input
    typealias Output = Tasks.Throwing.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct FatalTask: AirlockTask {
    typealias Input  = Tasks.Fatal.Input
    typealias Output = Tasks.Fatal.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct SIGKILLTask: AirlockTask {
    typealias Input  = Tasks.SIGKILL.Input
    typealias Output = Tasks.SIGKILL.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct SlowTask: AirlockTask {
    typealias Input  = Tasks.Slow.Input
    typealias Output = Tasks.Slow.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
struct EmptyIOTask: AirlockTask {
    typealias Input  = Tasks.EmptyIO.Input
    typealias Output = Tasks.EmptyIO.Output
    static func main(_ input: Input) throws -> Output { fatalError() }
}
