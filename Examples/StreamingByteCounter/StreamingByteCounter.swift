import NIOCore
import NetSkein

actor ByteCounter {
    var totalBytes = 0

    func add(_ bytes: Int) -> Int {
        totalBytes += bytes
        return totalBytes
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
                .send { chunk, progress in
                    let currentFragmentBytes = chunk.readableBytes
                    print("Received fragment size: \(currentFragmentBytes) bytes")

                    let currentTotal = await counter.add(currentFragmentBytes)

                    if let progress = progress {
                        print("Progress: \(Int(progress * 100))% (Total: \(currentTotal) bytes)")
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
