import CoreGraphics
import Testing
@testable import Vela

@Suite("Configuration Workbench presentation policy")
struct ConfigurationWorkbenchPresentationPolicyTests {
    @Test("Primary navigator and editor fit the required minimum window")
    func primaryWorkspaceFitsMinimumWindow() {
        let contentWidth = ConfigurationWorkbenchLayoutPolicy.availableContentWidth(
            windowWidth: VelaMetrics.minimumWindow.width,
            outerSidebarWidth: VelaMetrics.sidebarMaximumWidth
        )

        #expect(contentWidth >= ConfigurationWorkbenchLayoutPolicy.minimumPrimaryContentWidth)
    }

    @Test("Source inspector collapses at the required minimum window")
    func inspectorCollapsesAtMinimumWindow() {
        let contentWidth = ConfigurationWorkbenchLayoutPolicy.availableContentWidth(
            windowWidth: VelaMetrics.minimumWindow.width,
            outerSidebarWidth: VelaMetrics.sidebarMaximumWidth
        )

        #expect(
            ConfigurationWorkbenchLayoutPolicy.inspectorPresentation(
                isPreferred: true,
                contentWidth: contentWidth
            ) == .collapsedForSpace
        )
    }

    @Test("Source inspector is available at the default window")
    func inspectorAppearsAtDefaultWindow() {
        let contentWidth = ConfigurationWorkbenchLayoutPolicy.availableContentWidth(
            windowWidth: VelaMetrics.defaultWindow.width,
            outerSidebarWidth: VelaMetrics.sidebarMaximumWidth
        )

        #expect(
            ConfigurationWorkbenchLayoutPolicy.inspectorPresentation(
                isPreferred: true,
                contentWidth: contentWidth
            ) == .presented
        )
    }

    @Test("A user-hidden inspector remains hidden when space is available")
    func userPreferenceRemainsAuthoritative() {
        #expect(
            ConfigurationWorkbenchLayoutPolicy.inspectorPresentation(
                isPreferred: false,
                contentWidth: ConfigurationWorkbenchLayoutPolicy.minimumThreeColumnContentWidth
            ) == .hiddenByUser
        )
    }

    @Test("Inspector threshold includes both dividers and its minimum width")
    func inspectorThresholdIsDeterministic() {
        #expect(
            !ConfigurationWorkbenchLayoutPolicy.canPresentInspector(
                contentWidth: ConfigurationWorkbenchLayoutPolicy.minimumThreeColumnContentWidth - 1
            )
        )
        #expect(
            ConfigurationWorkbenchLayoutPolicy.canPresentInspector(
                contentWidth: ConfigurationWorkbenchLayoutPolicy.minimumThreeColumnContentWidth
            )
        )
    }

    @Test("Override editors use a bounded responsive trailing control width")
    func overrideEditorsUseSharedWidth() {
        #expect(ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth >= 120)
        #expect(
            ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth
                >= ConfigurationWorkbenchLayoutMetrics.overrideControlMinimumWidth
        )
        #expect(
            ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
                >= ConfigurationWorkbenchLayoutMetrics.overrideControlIdealWidth
        )
        #expect(
            ConfigurationWorkbenchLayoutMetrics.overrideControlMaximumWidth
                < ConfigurationWorkbenchLayoutMetrics.workAreaMinimumWidth
        )
    }

    @Test("Default window can present navigator, work area, and native inspector")
    func defaultWindowFitsThreePaneWorkspace() {
        let contentWidth = ConfigurationWorkbenchLayoutPolicy.availableContentWidth(
            windowWidth: VelaMetrics.defaultWindow.width,
            outerSidebarWidth: VelaMetrics.sidebarMaximumWidth
        )

        #expect(contentWidth >= ConfigurationWorkbenchLayoutMetrics.threePaneMinimumWidth)
        #expect(
            ConfigurationWorkbenchLayoutMetrics.workAreaMinimumWidth
                + ConfigurationWorkbenchLayoutMetrics.inspectorMinimumWidth
                < contentWidth
        )
    }
}
