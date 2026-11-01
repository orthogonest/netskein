import NetSkein

extension NetSkeinClient {
    /// The mock transport of a client built with ``NetSkein/NetSkeinClient/testing()``, or `nil`
    /// for any other client.
    ///
    /// Use it to check what actually reached the network, for example that a cached response
    /// was served without a request:
    ///
    /// ```swift
    /// _ = try await client.get(url).send()
    /// _ = try await client.get(url).send()   // served from the cache
    ///
    /// #expect(client.mock?.requests.count == 1)
    /// ```
    public var mock: MockHTTPClient? {
        transport as? MockHTTPClient
    }
}
