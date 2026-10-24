public protocol BodyState: Sendable {}

public enum BodyForbidden: BodyState {}
public enum BodyAllowed: BodyState {}
public enum BodyAttached: BodyState {}
