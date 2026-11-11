import Foundation
import Testing
@testable import Toasty

@MainActor
struct PreviewTests {
    @Test func addressesResolveLikeADevWouldType() {
        #expect(PreviewSession.resolve("3000")?.absoluteString == "http://localhost:3000")
        #expect(PreviewSession.resolve(":5173")?.absoluteString == "http://localhost:5173")
        #expect(PreviewSession.resolve("localhost:3000/pricing")?.absoluteString == "http://localhost:3000/pricing")
        #expect(PreviewSession.resolve("127.0.0.1:8080")?.absoluteString == "http://127.0.0.1:8080")
        #expect(PreviewSession.resolve("myapp.test")?.absoluteString == "http://myapp.test")
        #expect(PreviewSession.resolve("example.com")?.absoluteString == "https://example.com")
        #expect(PreviewSession.resolve("https://example.com/a?b=1")?.absoluteString == "https://example.com/a?b=1")
        #expect(PreviewSession.resolve("") == nil)
        #expect(PreviewSession.resolve("not an address") == nil)
        #expect(PreviewSession.resolve("javascript:alert(1)") == nil)
    }

    @Test func localLinksAreDevServersNotSites() {
        for local in ["http://localhost:5173/", "http://127.0.0.1:8000", "http://0.0.0.0:3000", "http://192.168.1.20:3000/a",
                      "http://[::1]:3000/", "http://app.localhost:3000", "http://marty.local:8080", "https://localhost:3000"] {
            #expect(PreviewStore.isLocal(URL(string: local)!), "\(local)")
        }
        for site in ["https://github.com/a/b", "https://vitejs.dev", "http://example.com", "mailto:a@b.co",
                     "file:///tmp/a.html", "https://1.2.3.example.com"] {
            #expect(!PreviewStore.isLocal(URL(string: site)!), "\(site)")
        }
    }

    @Test func addressesDisplayWithoutNoise() {
        #expect(PreviewSession.display(URL(string: "http://localhost:3000/")!) == "localhost:3000")
        #expect(PreviewSession.display(URL(string: "http://localhost:3000/pricing")!) == "localhost:3000/pricing")
        #expect(PreviewSession.display(URL(string: "https://example.com/")!) == "https://example.com")
    }

    @Test func phoneKeepsItsWidthAndCentersInAWidePane() {
        let fit = PreviewViewport.mobile.fit(in: CGSize(width: 500, height: 1000))
        #expect(fit.page == CGSize(width: 390, height: 844))
        #expect(fit.scale == 1)
        #expect(fit.display == CGRect(x: 55, y: 0, width: 390, height: 844))
    }

    @Test func phoneShrinksInANarrowPaneAndShortensInAShortOne() {
        let narrow = PreviewViewport.mobile.fit(in: CGSize(width: 195, height: 2000))
        #expect(narrow.page.width == 390)
        #expect(narrow.scale == 0.5)
        let short = PreviewViewport.mobile.fit(in: CGSize(width: 500, height: 600))
        #expect(short.page == CGSize(width: 390, height: 600))
    }

    @Test func desktopStays1280WideWhenDrawnSmaller() {
        let panel = PreviewViewport.desktop.fit(in: CGSize(width: 1024, height: 800))
        #expect(panel.page == CGSize(width: 1280, height: 1000))
        #expect(panel.display == CGRect(x: 0, y: 0, width: 1024, height: 800))
        // Never taller than wide, however narrow the pane.
        let narrow = PreviewViewport.desktop.fit(in: CGSize(width: 400, height: 900))
        #expect(narrow.page == CGSize(width: 1280, height: 1280))
        #expect(narrow.display == CGRect(x: 0, y: 0, width: 400, height: 400))
    }

    @Test func desktopFillsAPaneWithRoom() {
        let fit = PreviewViewport.desktop.fit(in: CGSize(width: 1500, height: 900))
        #expect(fit.page == CGSize(width: 1500, height: 900))
        #expect(fit.scale == 1)
    }

    /// A desktop page beside the workspaces and the conversation needs
    /// 1280 points of its own; a window without them gives it the whole
    /// window and makes the conversation a drawer.
    @Test func desktopPageTakesTheWindowWhenItCantFitBeside() {
        // A 16-inch MacBook Pro's whole screen, and the window in the report.
        #expect(!PreviewDrawer.fits(width: 1728, sidebar: 250))
        #expect(!PreviewDrawer.fits(width: 1620, sidebar: 250))
        // A window on a 27-inch display.
        #expect(PreviewDrawer.fits(width: 2072, sidebar: 250))
        // Exactly enough: 250 + 440 + 1280, and the two hairlines.
        #expect(PreviewDrawer.fits(width: 1971, sidebar: 250))
        #expect(!PreviewDrawer.fits(width: 1970, sidebar: 250))
    }

    @Test func commentSaysWhatWhereAndAtWhichSize() {
        let pick = PreviewSession.Pick(kind: .element, selector: "button.cta", text: "Start free trial",
                                       rect: .zero, viewport: CGSize(width: 390, height: 844),
                                       url: "http://localhost:3000/pricing")
        #expect(PreviewSession.commentLine(pick, note: " too close to the edge ", viewport: .mobile)
            == "Preview comment on `button.cta` \"Start free trial\" (mobile 390×844, localhost:3000/pricing, outlined in the screenshot): too close to the edge")
        let area = PreviewSession.Pick(kind: .area, selector: "div.hero", text: "ignored", rect: .zero,
                                       viewport: CGSize(width: 1280, height: 800), url: "http://localhost:3000/")
        #expect(PreviewSession.commentLine(area, note: "", viewport: .desktop)
            == "Preview comment on the area around `div.hero` (desktop 1280×800, localhost:3000, outlined in the screenshot)")
    }

    @Test func toolsExistOnlyWhileTheSettingIsOn() {
        let was = PreviewSettings.shared.enabled
        defer { PreviewSettings.shared.enabled = was }
        PreviewSettings.shared.enabled = false
        #expect(PreviewTools.servers().isEmpty)
        PreviewSettings.shared.enabled = true
        #expect(PreviewTools.servers().count == 1)
    }
}
