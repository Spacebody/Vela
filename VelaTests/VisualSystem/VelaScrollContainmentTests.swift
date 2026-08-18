import AppKit
import Testing
@testable import Vela

@MainActor
struct VelaScrollContainmentTests {
    @Test
    func policyDisablesElasticityForEveryNestedScrollView() {
        let root = NSView()
        let outerScrollView = NSScrollView()
        let container = NSView()
        let innerScrollView = NSScrollView()

        outerScrollView.verticalScrollElasticity = .allowed
        outerScrollView.horizontalScrollElasticity = .allowed
        outerScrollView.usesPredominantAxisScrolling = false
        innerScrollView.verticalScrollElasticity = .allowed
        innerScrollView.horizontalScrollElasticity = .allowed
        innerScrollView.usesPredominantAxisScrolling = false

        root.addSubview(outerScrollView)
        root.addSubview(container)
        container.addSubview(innerScrollView)

        VelaScrollContainmentPolicy.apply(to: root)

        #expect(outerScrollView.verticalScrollElasticity == .none)
        #expect(outerScrollView.horizontalScrollElasticity == .none)
        #expect(outerScrollView.usesPredominantAxisScrolling)
        #expect(innerScrollView.verticalScrollElasticity == .none)
        #expect(innerScrollView.horizontalScrollElasticity == .none)
        #expect(innerScrollView.usesPredominantAxisScrolling)
    }
}
