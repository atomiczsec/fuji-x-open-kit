import Foundation

actor MemoryPipe {
    var buffer = Data()
    var ended = false
    var waiter: CheckedContinuation<Void, Never>?
    func write(_ bytes: Data) throws {
        guard !ended else {
            throw PTPError.disconnected
        }
        buffer.append(bytes)
        waiter?.resume()
        waiter = nil
    }

    func read(_ maximum: Int) async throws -> Data {
        guard maximum > 0 else {
            throw PTPError.malformed("Invalid read size")
        }
        while buffer.isEmpty && !ended {
            guard waiter == nil else {
                throw PTPError.busy
            }
            await withCheckedContinuation {
                waiter = $0
            }
        }
        guard !buffer.isEmpty else {
            throw PTPError.disconnected
        }
        let bytes = Data(buffer.prefix(maximum))
        buffer = Data(buffer.dropFirst(bytes.count))
        return bytes
    }

    func close() {
        ended = true
        waiter?.resume()
        waiter = nil
    }
}
