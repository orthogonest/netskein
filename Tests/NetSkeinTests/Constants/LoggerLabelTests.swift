import Testing

@testable import NetSkein

struct LoggerLabelTests {
    @Test(
        "LoggerLabelTests: Verifies internal identifier constant matches the reverse domain naming convention string literal"
    )
    func testLabelIdentifierConstantValue() {
        #expect(LoggerLabel.identifier == "com.netskein.network")
    }
}
