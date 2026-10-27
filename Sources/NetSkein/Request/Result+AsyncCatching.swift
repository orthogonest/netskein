extension Result {
    /// Runs an async throwing operation and captures its outcome, keeping the typed error.
    init(catching body: () async throws(Failure) -> Success) async {
        do {
            self = .success(try await body())
        } catch {
            self = .failure(error)
        }
    }
}
