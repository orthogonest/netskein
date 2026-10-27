import Logging
import NetSkein

struct NewItem: Encodable {
    var name: String
    var quantity: Int
}

@main
struct CurlLogging {
    static func main() async throws {
        var logger = Logger(label: "com.netskein.examples.curl-logging")
        logger.logLevel = .debug

        let client = NetSkeinClient.builder()
            .logger(logger)
            .using { request, _, next in
                var request = request
                request.headers.replaceOrAdd(name: "Authorization", value: "Bearer example-token")
                return try await next(request)
            }
            .using(CurlLoggingMiddleware(format: .multiline))
            .build()

        do {
            let response = try await client.post("https://httpbin.org/post")
                .json(NewItem(name: "Notebook", quantity: 2))
                .send()
            print("status:", response.status)
        } catch {
            print("request failed:", error)
        }

        // It is important to shutdown the client after all requests are done, even if one failed
        try await client.shutdown()
    }
}
