import NIOCore
import NetSkein

actor ByteCounter {
    var totalBytes: Int64 = 0

    func update(_ bytes: Int64) {
        totalBytes = bytes
    }
}

@main
struct StreamingByteCounter {
    static func main() async throws {
        let client = NetSkeinClient.builder()
            .connectTimeout(.seconds(2))
            .readTimeout(.seconds(30))
            .build()

        do {
            let counter = ByteCounter()

            try await client.get("https://apple.com")
                .timeout(.seconds(30))
                .send { chunk, received, total in
                    let currentFragmentBytes = chunk.readableBytes
                    print("Received fragment size: \(currentFragmentBytes) bytes")

                    await counter.update(received)

                    let progress = total.map { Double(received) / Double($0) }
                    if let progress {
                        print("Progress: \(Int(progress * 100))% (Total: \(received) bytes)")
                    }
                }

            let finalTotal = await counter.totalBytes
            print("Did receive \(finalTotal) bytes total.")
            print("Streaming network operation completed successfully.")
        } catch {
            print("request failed:", error)
        }

        // It is important to shutdown the client after all requests are done, even if one failed
        try await client.shutdown()
    }
}
