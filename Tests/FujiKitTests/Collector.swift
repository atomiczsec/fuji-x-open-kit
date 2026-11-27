import Foundation

actor Collector {
    var chunks: [Data] = []
    func append(_ data: Data) {
        chunks.append(data)
    }

    func data() -> Data {
        chunks.reduce(Data(), +)
    }

    func count() -> Int {
        chunks.count
    }
}
