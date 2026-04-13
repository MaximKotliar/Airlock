import Foundation
import Airlock

// MARK: - Task definitions

struct Greet: AirlockTask {
    struct Input: Codable  { var name: String }
    struct Output: Codable { var greeting: String }

    static func main(_ input: Input) throws -> Output {
        Output(greeting: "Hello, \(input.name)! (pid \(getpid()))")
    }
}

struct Fib: AirlockTask {
    struct Input: Codable  { var n: Int }
    struct Output: Codable { var result: Int }

    static func main(_ input: Input) throws -> Output {
        func fib(_ n: Int) -> Int { n <= 1 ? n : fib(n - 1) + fib(n - 2) }
        return Output(result: fib(input.n))
    }
}

// MARK: - Child hook (register tasks, then seal)

Airlock.register(Greet.self)
Airlock.register(Fib.self)
Airlock.engage()

// MARK: - Parent path

print("Parent pid: \(getpid())")

let greeting = try Airlock.run(Greet.self, input: .init(name: "World"))
print(greeting.greeting)

let fib = try Airlock.run(Fib.self, input: .init(n: 10))
print("fib(10) = \(fib.result)")
