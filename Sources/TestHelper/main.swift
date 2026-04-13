import Foundation
import Airlock

// Shared task definitions used by AirlockTests.
// This executable is spawned as the child process during tests.

struct EchoTask: AirlockTask {
    struct Input: Codable, Equatable  { var text: String; var number: Int }
    struct Output: Codable, Equatable { var text: String; var number: Int }

    static func main(_ input: Input) throws -> Output {
        Output(text: input.text, number: input.number)
    }
}

struct PIDTask: AirlockTask {
    struct Input: Codable  { var parentPID: Int32 }
    struct Output: Codable { var childPID: Int32; var parentPID: Int32 }

    static func main(_ input: Input) throws -> Output {
        Output(childPID: getpid(), parentPID: input.parentPID)
    }
}

struct UnicodeTask: AirlockTask {
    struct Input: Codable, Equatable  { var text: String }
    struct Output: Codable, Equatable { var text: String }

    static func main(_ input: Input) throws -> Output {
        Output(text: input.text)
    }
}

struct LargePayloadTask: AirlockTask {
    struct Input: Codable, Equatable  { var repeatedChar: String; var count: Int }
    struct Output: Codable, Equatable { var payload: String }

    static func main(_ input: Input) throws -> Output {
        Output(payload: String(repeating: input.repeatedChar, count: input.count))
    }
}

struct ThrowingTask: AirlockTask {
    struct Input: Codable {}
    struct Output: Codable { var x: Int }

    static func main(_ input: Input) throws -> Output {
        struct E: Error {}
        throw E()
    }
}

struct FatalTask: AirlockTask {
    struct Input: Codable {}
    struct Output: Codable { var x: Int }

    static func main(_ input: Input) throws -> Output {
        fatalError("deliberate crash in isolated child")
    }
}

struct SIGKILLTask: AirlockTask {
    struct Input: Codable {}
    struct Output: Codable { var x: Int }

    static func main(_ input: Input) throws -> Output {
        kill(getpid(), SIGKILL)
        return Output(x: 0)
    }
}

struct SlowTask: AirlockTask {
    struct Input: Codable  { var index: Int; var delayMs: Int }
    struct Output: Codable { var index: Int }

    static func main(_ input: Input) throws -> Output {
        Thread.sleep(forTimeInterval: Double(input.delayMs) / 1000.0)
        return Output(index: input.index)
    }
}

struct EmptyIOTask: AirlockTask {
    struct Input: Codable, Equatable {}
    struct Output: Codable, Equatable {}

    static func main(_ input: Input) throws -> Output { Output() }
}

// Register all tasks, then seal.
Airlock.register(EchoTask.self)
Airlock.register(PIDTask.self)
Airlock.register(UnicodeTask.self)
Airlock.register(LargePayloadTask.self)
Airlock.register(ThrowingTask.self)
Airlock.register(FatalTask.self)
Airlock.register(SIGKILLTask.self)
Airlock.register(SlowTask.self)
Airlock.register(EmptyIOTask.self)
Airlock.engage()
