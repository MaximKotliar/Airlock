/// A self-contained unit of work that Airlock can run in an isolated child process.
///
/// Conform a struct to this protocol, implement ``main(_:)``, and Airlock will handle
/// spawning a fresh copy of your executable, routing the task via an inherited
/// shared-memory fd, and shuttling `Codable` I/O through that anonymous region.
///
/// ```swift
/// struct ParseTask: AirlockTask {
///     struct Input: Codable  { var rawBytes: [UInt8] }
///     struct Output: Codable { var parsed: String }
///
///     static func main(_ input: Input) throws -> Output {
///         Output(parsed: String(bytes: input.rawBytes, encoding: .utf8) ?? "")
///     }
/// }
/// ```
public protocol AirlockTask {
    associatedtype Input:  Codable
    associatedtype Output: Codable

    /// Stable identifier written into shared memory to match the task type.
    /// Defaults to the unqualified Swift type name.
    static var identifier: String { get }

    /// Entry point executed in the child process.
    static func main(_ input: Input) throws -> Output
}

public extension AirlockTask {
    static var identifier: String { String(describing: Self.self) }
}
