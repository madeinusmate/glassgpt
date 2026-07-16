import XCTest
@testable import GlassGPT

final class RealtimeSupportTests: XCTestCase {
    func testTurnImagePolicyCapturesEveryCompletedTurn() {
        // The on-demand camera design deliberately uses one still per turn,
        // regardless of wording, so no continuous video transport is needed.
        XCTAssertTrue(TurnImagePolicy.shouldCaptureImage(for: "What am I looking at?"))
        XCTAssertTrue(TurnImagePolicy.shouldCaptureImage(for: "Set a five minute timer"))
    }
}
