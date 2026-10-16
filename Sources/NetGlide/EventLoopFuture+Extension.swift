import NIOCore

public extension EventLoopFuture where Value: Sendable {
    @inlinable
    func fallbackGet() async throws -> Value {
        try await withCheckedThrowingContinuation { @Sendable (continuation: CheckedContinuation<Value, Error>) in
            self.whenComplete { result in
                switch result {
                case let .success(value):
                    continuation.resume(returning: value)
                case let .failure(error):
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
