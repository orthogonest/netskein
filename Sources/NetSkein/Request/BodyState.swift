/// Whether a ``NetSkeinRequest`` can take a body, checked at compile time.
///
/// You don't use these types directly: they appear as `NetSkeinRequest<BodyForbidden>` and so on,
/// and decide which body methods compile. The three states are ``BodyForbidden``,
/// ``BodyAllowed`` and ``BodyAttached``.
public protocol BodyState: Sendable {}

/// A request that can't have a body, such as `GET` or `DELETE`.
///
/// Call ``NetSkeinRequest/dangerouslyAllowBody()`` to send a body anyway.
public enum BodyForbidden: BodyState {}

/// A request that can have a body but doesn't have one yet, such as `POST`.
public enum BodyAllowed: BodyState {}

/// A request whose body is set, so it can't get another one.
public enum BodyAttached: BodyState {}
