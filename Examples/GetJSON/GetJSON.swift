import Foundation
import NIOCore
import NIOFoundationCompat
import NetSkein

struct Comic: Codable {
    var num: Int
    var title: String
    var day: String
    var month: String
    var year: String
    var img: String
    var alt: String
    var news: String
    var link: String
    var transcript: String
}

@main
struct GetJSON {
    static func main() async throws {
        let client = NetSkeinClient()

        do {
            let comic = try await client.get("https://xkcd.com/info.0.json")
                .timeout(.seconds(30))
                .send()
                .json(Comic.self)
            dump(comic)
        } catch {
            print("request failed:", error)
        }

        // It is important to shutdown the client after all requests are done, even if one failed
        try await client.shutdown()
    }
}
