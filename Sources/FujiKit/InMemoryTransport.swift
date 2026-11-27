import Foundation

public struct InMemoryTransport: PTPIPTransport {
    private let input: MemoryPipe
    private let output: MemoryPipe
    public static func pair() -> (Self, Self) {
        let firstInput = MemoryPipe()
        let secondInput = MemoryPipe()
        return (
            Self(input: firstInput, output: secondInput),
            Self(input: secondInput, output: firstInput)
        )
    }

    public func send(_ bytes: Data) async throws {
        try await output.write(bytes)
    }

    public func receive(maximum: Int) async throws -> Data {
        try await input.read(maximum)
    }

    public func close() async {
        await input.close()
        await output.close()
    }
}
