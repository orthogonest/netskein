/// How often a middleware runs for a call that is retried.
///
/// Pass it when registering a middleware, for example with
/// ``NetSkeinClientBuilder/using(_:per:)``:
///
/// ```swift
/// NetSkeinClient.builder()
///     .using(IdempotencyKeyMiddleware(), per: .call)
///     .using(AuthMiddleware())  // per: .attempt
/// ```
@nonexhaustive
public enum MiddlewareScope: Sendable, Hashable {
    /// Runs once for the whole call, around all of its attempts.
    ///
    /// Changes to the request apply to every attempt, which suits values that must stay the same
    /// across retries, such as an `Idempotency-Key`. `next` returns once the retry policy has
    /// finished, with the final response or the last error:
    ///
    /// - For `send()`, the response carries the collected body.
    /// - For `stream()` and `lines()`, the body is still to be read by the caller.
    /// - For `stream(_:)` and downloads, the body has already been delivered, so the response
    ///   has only its status and headers.
    ///
    /// Changing the response returned by `next` has no effect. Returning a response without
    /// calling `next`, or after `next` throws, ends the call with that response instead.
    /// ``MiddlewareContext/attempt`` is always `0`.
    case call

    /// Runs for every attempt, including retries. The default.
    ///
    /// Suits work that must be redone for each attempt, such as refreshing credentials, signing
    /// a request with a timestamp, or logging each attempt.
    case attempt
}
