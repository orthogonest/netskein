import Testing

@testable import NetSkein

struct ResultAsyncCatchingTests {
    struct SampleError: Error, Equatable {}

    @Test("ResultAsyncCatchingTests: Verifies a returned value is captured as success")
    func testCapturesSuccess() async {
        let result = await Result { () async throws(SampleError) -> Int in 42 }

        #expect(result == .success(42))
    }

    @Test("ResultAsyncCatchingTests: Verifies a thrown error is captured as failure")
    func testCapturesFailure() async {
        let result = await Result { () async throws(SampleError) -> Int in throw SampleError() }

        #expect(result == .failure(SampleError()))
    }
}
