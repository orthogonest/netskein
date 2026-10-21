import Testing

@testable import NetSkein

struct LabelTests {
    @Test(
        "LabelTests: Verifies internal identifier constant matches the reverse domain naming convention string literal"
    )
    func testLabelIdentifierConstantValue() {
        #expect(Label.identifier == "com.netskein.network")
    }
}
