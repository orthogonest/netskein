import Testing

@testable import NetSkein

struct NanosecondsTests {
    @Test(
        "NanosecondsTests: Verifies nanoseconds to seconds conversion constant matches the absolute mathematical scale"
    )
    func testNanosecondsToSecondsConstantValue() {
        #expect(Nanoseconds.toSeconds == 1_000_000_000.0)
    }
}
