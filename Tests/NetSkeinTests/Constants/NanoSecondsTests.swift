import Testing

@testable import NetSkein

struct NanoSecondsTests {
    @Test(
        "NanoSecondsTests: Verifies nanoseconds to seconds conversion constant matches the absolute mathematical scale"
    )
    func testNanoSecondsToSecondsConstantValue() {
        #expect(NanoSeconds.toSeconds == 1_000_000_000.0)
    }
}
