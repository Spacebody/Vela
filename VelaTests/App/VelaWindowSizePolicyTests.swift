import CoreGraphics
import Foundation
import Testing
@testable import Vela

@Suite("Main window size policy")
struct VelaWindowSizePolicyTests {
    @Test("Measured frame target maps to an explicit content minimum")
    func measuredMinimum() {
        #expect(
            VelaWindowSizePolicy.mainMinimumReferenceFrameSize
                == CGSize(width: 1_040, height: 680)
        )
        #expect(
            VelaWindowSizePolicy.mainMinimumContentSize
                == CGSize(width: 1_040, height: 648)
        )
        #expect(
            VelaWindowSizePolicy.referenceFrameSize(
                forContentSize: VelaWindowSizePolicy.mainMinimumContentSize
            ) == VelaWindowSizePolicy.mainMinimumReferenceFrameSize
        )
    }

    @Test("Default and ideal sizes are content sizes with no maximum")
    func defaultAndIdeal() {
        #expect(
            VelaWindowSizePolicy.mainDefaultContentSize
                == CGSize(width: 1_280, height: 788)
        )
        #expect(
            VelaWindowSizePolicy.mainIdealContentSize
                == VelaWindowSizePolicy.mainDefaultContentSize
        )
        #expect(
            VelaWindowSizePolicy.mainDefaultReferenceFrameSize
                == CGSize(width: 1_280, height: 820)
        )
        #expect(
            VelaWindowSizePolicy.mainDefaultContentSize.width
                > VelaWindowSizePolicy.mainMinimumContentSize.width
        )
        #expect(
            VelaWindowSizePolicy.mainDefaultContentSize.height
                > VelaWindowSizePolicy.mainMinimumContentSize.height
        )
    }

    @Test("Debug window accessor accepts only a bounded explicit request")
    func testRequestParsing() throws {
        let request = try #require(
            try VelaWindowTestRequest.resolve(arguments: [
                "Vela",
                VelaWindowTestRequest.modeKey, "YES",
                VelaWindowTestRequest.sceneIdentifierKey,
                "main-window-policy-test-unit",
                VelaWindowTestRequest.requestedContentSizeKey, "600x400",
            ])
        )
        #expect(request.requestedContentSize == CGSize(width: 600, height: 400))

        #expect(throws: VelaWindowTestRequestError.invalidMode) {
            try VelaWindowTestRequest.resolve(arguments: [
                "Vela",
                VelaWindowTestRequest.modeKey, "NO",
                VelaWindowTestRequest.sceneIdentifierKey,
                "main-window-policy-test-unit",
            ])
        }
        #expect(throws: VelaWindowTestRequestError.invalidContentSize("0x400")) {
            try VelaWindowTestRequest.resolve(arguments: [
                "Vela",
                VelaWindowTestRequest.modeKey, "YES",
                VelaWindowTestRequest.sceneIdentifierKey,
                "main-window-policy-test-unit",
                VelaWindowTestRequest.requestedContentSizeKey, "0x400",
            ])
        }
        #expect(throws: VelaWindowTestRequestError.invalidSceneIdentifier("main")) {
            try VelaWindowTestRequest.resolve(arguments: [
                "Vela",
                VelaWindowTestRequest.modeKey, "YES",
                VelaWindowTestRequest.sceneIdentifierKey, "main",
            ])
        }
        #expect(
            try AppLaunchConfiguration.resolve(
                arguments: [
                    "Vela",
                    VelaWindowTestRequest.modeKey, "YES",
                ],
                environment: [:]
            ) == .uiTesting
        )
    }

}
