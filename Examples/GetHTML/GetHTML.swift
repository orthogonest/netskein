import NIOCore
import NetSkein

@main
struct GetHTML {
    static func main() async throws {
        let client = NetSkeinClient()

        do {
            let response = try await client.get("https://apple.com")
                .send()
                .errorForStatus()
                .text(upTo: 1024 * 1024)  // 1 MB

            print("HTTP Body Content:")
            print(response ?? "Empty HTTP body")
        } catch {
            print("request failed:", error)
        }

        // It is important to shutdown the client after all requests are done, even if one failed
        try await client.shutdown()
    }
}
