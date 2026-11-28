#if os(macOS)
import AppKit
import Network
import WebKit
import XCTest
@testable import ExactKit
@testable import ExactWebViews

extension SplitMacTests {
    func testSampleRefusesAnUnreadableLayerOnlyWhereItContributes() throws {
        let session = try boot(tabs: false, size: CGSize(width: 900, height: 500))
        _ = compose(ExactView(session: session), width: 900, sidebar: false)
        session.presenter.press(try node("row-a").id)
        let agent = Agent(session: session), node = try node("half-a")
        let window = try XCTUnwrap(window)
        XCTAssertNil(agent.sample(["points": [[0, 0]]])["error"])
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
        let parent = try XCTUnwrap(node.layer)
        let metal = CAMetalLayer(), cover = CALayer()
        metal.frame = parent.bounds
        cover.frame = parent.bounds.divided(atDistance: parent.bounds.width / 2, from: .minXEdge).slice
        cover.backgroundColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        cover.zPosition = 2
        parent.addSublayer(cover)
        parent.addSublayer(metal)
        let box = agent.box(node)
        func sample(_ fraction: CGFloat) -> [String: Any] {
            agent.sample(["points": [[box.minX + fraction * box.width, box.midY]]])
        }
        let covered = sample(0.25)
        XCTAssertEqual((covered["values"] as? [[Double]])?.first, [0, 1, 0, 1], "\(covered)")
        XCTAssertTrue((sample(0.75)["error"] as? String)?.contains("half-a") == true)
        cover.opacity = 0.5
        XCTAssertTrue((sample(0.25)["error"] as? String)?.contains("Metal") == true)
        metal.isHidden = true
        XCTAssertNil(sample(0.25)["error"])
        XCTAssertTrue(parent.sublayers?.last === metal)
    }
}

final class AgentSampleIframeMacTests: XCTestCase {
    private var sessions: [ExactSession] = []

    override func tearDown() {
        sessions.forEach { $0.destroy() }
        sessions = []
        super.tearDown()
    }

    /// Linear-sRGB `#ececef`: the backdrop behind every test iframe.
    private let backdrop: [Double] = [0.8388, 0.8388, 0.8632, 1.0]
    /// Linear-sRGB `#ef4444`.
    private let red: [Double] = [0.8632, 0.0578, 0.0578, 1.0]
    /// Linear-sRGB `#16a34a`.
    private let green: [Double] = [0.0080, 0.3663, 0.0685, 1.0]

    private func assertLinearColor(_ actual: [Double], matches expected: [Double], tolerance: Double = 0.03, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, 4, message, file: file, line: line)
        guard actual.count == 4 else { return }
        for i in 0..<4 {
            XCTAssertEqual(actual[i], expected[i], accuracy: tolerance, "\(message) channel \(i): got \(actual) expected \(expected)", file: file, line: line)
        }
    }

    private func sampleIframe(
        label: String,
        html: String? = nil,
        src externalSrc: String? = nil,
        props extraProps: [String: Any] = [:],
        afterLoadJS: String? = nil,
        points: [[Double]]
    ) throws -> [[Double]] {
        guard let arm = ProcessInfo.processInfo.environment["EXACT_TEST_WEB_MODULE"] else {
            throw missing("module", "no WebKit arm: name a built one with EXACT_TEST_WEB_MODULE")
        }
        _ = NSApplication.shared
        let session = ExactApp.shared.makeSession(label: "sample-\(label)")
        sessions.append(session)
        session.webHost.moduleLocation = { arm }
        XCTAssertNil(session.boot(size: CGSize(width: 400, height: 300)).error)
        let win = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        win.isReleasedWhenClosed = false
        win.contentView = ExactView(session: session)
        win.orderFrontRegardless()
        defer { win.close() }
        waitForActivation(session)

        let src: String
        var tempFile: URL?
        if let externalSrc {
            src = externalSrc
        } else {
            let name = "app:/tmp/sample-\(UUID().uuidString).html"
            let file = try XCTUnwrap(AppFiles.url(name))
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((html ?? "<!doctype html><body></body>").utf8).write(to: file)
            tempFile = file
            src = name
        }
        defer { if let tempFile { try? FileManager.default.removeItem(at: tempFile) } }

        let loaded = expectation(description: "iframe loaded \(label)")
        var fulfilled = false
        session.presenter.onLoad = { if $0 == 7002 && !fulfilled { fulfilled = true; loaded.fulfill() } }
        var props: [String: Any] = ["src": src, "testId": "page"]
        for (k, v) in extraProps { props[k] = v }
        session.presenter.apply(wireBatch([
            ["op": "create", "id": 7001, "kind": "view", "props": ["testId": "bg"], "style": ["background_color": [236, 236, 239, 255]]],
            ["op": "create", "id": 7002, "kind": "iframe", "props": props, "style": [:], "handlers": ["load"]],
            ["op": "children", "id": 7001, "ids": [7002]],
            ["op": "roots", "ids": [7001]],
            ["op": "frame", "id": 7001, "x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0],
            ["op": "frame", "id": 7002, "x": 0.0, "y": 0.0, "w": 400.0, "h": 300.0],
        ]))
        wait(for: [loaded], timeout: 15)

        if let afterLoadJS, let web = session.presenter.views[7002]?.web as? WKWebView {
            let done = expectation(description: "iframe script \(label)")
            web.evaluateJavaScript("\(afterLoadJS) true") { _, error in
                if let error { XCTFail("\(label): script failed: \(error)") }
                done.fulfill()
            }
            wait(for: [done], timeout: 10)
        }

        let reply = Agent(session: session).sample(["points": points])
        XCTAssertNil(reply["error"], "\(label): \(reply)")
        return try XCTUnwrap(reply["values"] as? [[Double]], "\(label): \(reply)")
    }

    func testSampleOverBlankAndMagnifiedTransparentIframeShowsBackdrop() throws {
        let plain = try sampleIframe(label: "blank-1x", points: [[20, 20], [200, 150], [350, 250]])
        for (i, px) in plain.enumerated() {
            assertLinearColor(px, matches: backdrop, "1x blank point \(i)")
        }

        // apple.magnification < 1 shrinks the document inside the view; pixels outside the
        // scaled document must stay transparent rather than WebKit's white snapshot margin.
        let shrunk = try sampleIframe(
            label: "blank-mag-0.5",
            props: ["appleMagnification": "0.5"],
            points: [[20, 20], [190, 140], [200, 150], [350, 250]]
        )
        for (i, px) in shrunk.enumerated() {
            assertLinearColor(px, matches: backdrop, "0.5x blank point \(i)")
        }

        // Fractional magnification must not leave a white fringe on the document edge.
        let third = try sampleIframe(
            label: "blank-mag-0.33",
            props: ["appleMagnification": "0.33"],
            points: [[20, 20], [131, 98], [132, 99], [300, 200]]
        )
        for (i, px) in third.enumerated() {
            assertLinearColor(px, matches: backdrop, "0.33x blank point \(i)")
        }
    }

    func testSampleOverMagnifiedIframePreservesPaintedElementsAndOrientation() throws {
        let html = """
        <!doctype html>
        <body style="margin:0">
          <div style="position:absolute;left:0;top:0;width:100px;height:100px;background:#ef4444"></div>
          <div style="position:absolute;left:0;top:200px;width:100px;height:100px;background:#16a34a"></div>
        </body>
        """
        // At 0.5x, red occupies (0..50, 0..50), green occupies (0..50, 100..150),
        // (150, 75) is transparent inside the document, and (250, 200) is transparent outside it.
        let values = try sampleIframe(
            label: "elements-mag-0.5",
            html: html,
            props: ["appleMagnification": "0.5"],
            points: [[25, 25], [25, 125], [150, 75], [250, 200]]
        )
        assertLinearColor(values[0], matches: red, "top-left red block")
        assertLinearColor(values[1], matches: green, "lower-left green block")
        assertLinearColor(values[2], matches: backdrop, "transparent inside document")
        assertLinearColor(values[3], matches: backdrop, "transparent outside scaled document")
    }

    func testSampleOverMagnifiedPaintedEdgePreservesBoundaryPixels() throws {
        // A 499-CSS-pixel red document at 0.33x ends at 499 * 0.33 = 164.67 pt (165 pt ceiled),
        // and at 0.67x ends at 499 * 0.67 = 334.33 pt (335 pt ceiled). Points just inside the
        // painted edge must stay red rather than being clipped by point rounding, and points past
        // the edge must show the backdrop rather than WebKit's white margin.
        let html = """
        <!doctype html>
        <style>html,body{margin:0;width:499px;height:200px;background:#ef4444}</style>
        <body></body>
        """
        let third = try sampleIframe(
            label: "edge-499-0.33",
            html: html,
            props: ["appleMagnification": "0.33"],
            points: [[162, 50], [166, 50], [300, 50]]
        )
        assertLinearColor(third[0], matches: red, "inside 0.33x painted edge")
        assertLinearColor(third[1], matches: backdrop, "outside 0.33x painted edge")
        assertLinearColor(third[2], matches: backdrop, "far outside 0.33x painted edge")

        let twoThirds = try sampleIframe(
            label: "edge-499-0.67",
            html: html,
            props: ["appleMagnification": "0.67"],
            points: [[333, 50], [336, 50], [380, 50]]
        )
        assertLinearColor(twoThirds[0], matches: red, "inside 0.67x painted edge")
        assertLinearColor(twoThirds[1], matches: backdrop, "outside 0.67x painted edge")
        assertLinearColor(twoThirds[2], matches: backdrop, "far outside 0.67x painted edge")
    }

    func testSampleOverMagnifiedRTLIframePreservesLeftwardOverflow() throws {
        // An RTL document with 1000 CSS px of content in a 400 px viewport spans [-600, 400].
        // Scrolled to pageLeft = -400 at 0.5x, it projects to [-100, 400] and fills the entire
        // 400 pt viewport; left-edge content must not be cleared as if the document started at 0.
        let scrolledRTL = """
        <!doctype html>
        <html dir="rtl">
        <style>html,body{margin:0;background:transparent}.band{width:1000px;height:200px;background:#ef4444}</style>
        <body><div class="band"></div></body>
        </html>
        """
        let full = try sampleIframe(
            label: "rtl-scrolled-0.5",
            html: scrolledRTL,
            props: ["appleMagnification": "0.5"],
            afterLoadJS: "window.scrollTo(-400, 0);",
            points: [[20, 50], [150, 50], [350, 50]]
        )
        assertLinearColor(full[0], matches: red, "RTL left overflow visible at x=20")
        assertLinearColor(full[1], matches: red, "RTL left overflow visible at x=150")
        assertLinearColor(full[2], matches: red, "RTL content visible at x=350")

        // Unscrolled (pageLeft = 0) at 0.5x, [-600, 400] projects to [-300, 200]:
        // [0, 200) is red content and [200, 400) is outside margin showing the backdrop.
        let unscrolledRTL = """
        <!doctype html>
        <html dir="rtl">
        <style>html,body{margin:0;background:transparent}.band{width:1000px;height:200px;background:#ef4444}</style>
        <body><div class="band"></div></body>
        </html>
        """
        let half = try sampleIframe(
            label: "rtl-unscrolled-0.5",
            html: unscrolledRTL,
            props: ["appleMagnification": "0.5"],
            points: [[20, 50], [180, 50], [250, 50]]
        )
        assertLinearColor(half[0], matches: red, "RTL unscrolled left edge red")
        assertLinearColor(half[1], matches: red, "RTL unscrolled right edge red")
        assertLinearColor(half[2], matches: backdrop, "RTL unscrolled outside margin is backdrop")
    }

    func testPartitionedIframeRetainsOpaquePageBackground() throws {
        let html = """
        <!doctype html>
        <body style="margin:0"><div style="width:100px;height:100px;background:#ef4444"></div></body>
        """
        let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(html.utf8.count)\r\nConnection: close\r\n\r\n\(html)"
        let listener = try loopbackListener(port: 0) { connection in
            connection.start(queue: .main)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { _, _, _, _ in
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
        }
        defer { listener.cancel() }
        let port = try XCTUnwrap(listener.port).rawValue
        // A partitioned frame draws an opaque page background even at magnification < 1:
        // painted content and the area outside the scaled document both remain opaque.
        let values = try sampleIframe(
            label: "partition-opaque-0.5",
            src: "http://127.0.0.1:\(port)/",
            props: ["partition": "mem-sample-opaque", "appleMagnification": "0.5"],
            points: [[25, 25], [250, 200]]
        )
        assertLinearColor(values[0], matches: red, "partitioned red block at 0.5x")
        assertLinearColor(values[1], matches: [1.0, 1.0, 1.0, 1.0], "partitioned frame keeps opaque white background")
    }
}

@available(macOS 26.0, *)
final class AgentSampleGlassMacTests: XCTestCase {
    private var sessions: [ExactSession] = []

    override func tearDown() {
        sessions.forEach { $0.destroy() }
        sessions = []
        super.tearDown()
    }

    private func makeScene(
        _ ops: [[String: Any]],
        size: CGSize = CGSize(width: 480, height: 600),
        appearance: NSAppearance.Name = .aqua
    ) throws -> (session: ExactSession, window: NSWindow, agent: Agent) {
        _ = NSApplication.shared
        let session = ExactApp.shared.makeSession(label: "sample-glass")
        sessions.append(session)
        let window = NSWindow(
            contentRect: NSRect(x: -20000, y: -20000, width: size.width, height: size.height),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: appearance)
        window.contentView = session.presenter.viewport
        session.presenter.apply(wireBatch(ops))
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()
        return (session, window, Agent(session: session))
    }

    private func point(_ agent: Agent, _ node: NodeView, dx: CGFloat, dy: CGFloat) -> [Double] {
        let box = agent.box(node)
        return [Double(box.minX + dx), Double(box.minY + dy)]
    }

    private func assertLinear(
        _ reply: [String: Any],
        equals expected: [Double],
        tolerance: Double = 0.01,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        XCTAssertNil(reply["error"], "\(message): unexpected error \(reply)", file: file, line: line)
        let px = try XCTUnwrap((reply["values"] as? [[Double]])?.first, "\(message): \(reply)", file: file, line: line)
        XCTAssertEqual(px.count, 4, message, file: file, line: line)
        for i in 0..<4 {
            XCTAssertEqual(px[i], expected[i], accuracy: tolerance, "\(message) channel \(i): got \(px) expected \(expected)", file: file, line: line)
        }
    }

    /// Issue #2139: opaque views inside regular and clear native glass sample their true colors
    /// in both light and dark appearance, including with a live Metal layer elsewhere on the page.
    func testSampleReadsOpaqueViewsInsideGlassInLightAndDarkAndWithMetal() throws {
        for appearance: NSAppearance.Name in [.aqua, .darkAqua] {
            for material in ["glass", "glass-clear"] {
                let (session, window, agent) = try makeScene([
                    ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 255, 255]]],
                    ["op": "create", "id": 2, "kind": "view", "props": ["testId": "plain"], "style": ["background_color": [255, 0, 0, 255]]],
                    ["op": "create", "id": 3, "kind": "view", "props": ["testId": "glass-wrap", "backgroundMaterial": material]],
                    ["op": "create", "id": 4, "kind": "view", "props": ["testId": "glass"], "style": ["background_color": [255, 0, 0, 255]]],
                    ["op": "create", "id": 5, "kind": "view", "style": ["background_color": [255, 255, 255, 255]]],
                    ["op": "create", "id": 6, "kind": "view", "props": ["testId": "white-wrap", "backgroundMaterial": material]],
                    ["op": "create", "id": 7, "kind": "view", "props": ["testId": "white"], "style": ["background_color": [255, 0, 0, 255]]],
                    ["op": "children", "id": 3, "ids": [4]],
                    ["op": "children", "id": 6, "ids": [7]],
                    ["op": "children", "id": 5, "ids": [6]],
                    ["op": "children", "id": 1, "ids": [2, 3, 5]],
                    ["op": "roots", "ids": [1]],
                    ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 480.0, "h": 600.0],
                    ["op": "frame", "id": 2, "x": 32.0, "y": 32.0, "w": 80.0, "h": 80.0],
                    ["op": "frame", "id": 3, "x": 32.0, "y": 120.0, "w": 96.0, "h": 96.0],
                    ["op": "frame", "id": 4, "x": 8.0, "y": 8.0, "w": 80.0, "h": 80.0],
                    ["op": "frame", "id": 5, "x": 32.0, "y": 224.0, "w": 96.0, "h": 96.0],
                    ["op": "frame", "id": 6, "x": 0.0, "y": 0.0, "w": 96.0, "h": 96.0],
                    ["op": "frame", "id": 7, "x": 8.0, "y": 8.0, "w": 80.0, "h": 80.0],
                ], appearance: appearance)
                defer { window.close() }
                let p = session.presenter
                let plain = try XCTUnwrap(p.views[2]), glass = try XCTUnwrap(p.views[4]), white = try XCTUnwrap(p.views[7])
                let wrap = try XCTUnwrap(p.views[3])
                let label = "\(appearance.rawValue)/\(material)"
                try assertLinear(agent.sample(["points": [point(agent, plain, dx: 40, dy: 40)]]), equals: [1, 0, 0, 1], "\(label) plain")
                try assertLinear(agent.sample(["points": [point(agent, glass, dx: 40, dy: 40)]]), equals: [1, 0, 0, 1], "\(label) glass")
                try assertLinear(agent.sample(["points": [point(agent, white, dx: 40, dy: 40)]]), equals: [1, 0, 0, 1], "\(label) white")

                // With a live CAMetalLayer elsewhere on the page, glass content still samples red
                // while the Metal layer itself still refuses.
                let metal = CAMetalLayer()
                metal.frame = CGRect(x: 300, y: 32, width: 60, height: 60)
                try XCTUnwrap(p.views[1]?.layer).addSublayer(metal)
                try assertLinear(agent.sample(["points": [point(agent, glass, dx: 40, dy: 40)]]), equals: [1, 0, 0, 1], "\(label) with metal")
                XCTAssertTrue((agent.sample(["points": [[330.0, 62.0]]])["error"] as? String)?.contains("Metal") == true)

                // Bare glass padding refuses naming the glass node (LLP 1100 D12).
                let bare = agent.sample(["points": [point(agent, wrap, dx: 3, dy: 3)]])
                XCTAssertTrue((bare["error"] as? String)?.contains("glass-wrap") == true, "\(label) bare: \(bare)")
            }
        }
    }

    /// Extended-range P3 (< 0) and HDR (> 1) backing pixels inside native glass stay 32-bit float.
    func testSamplePreservesExtendedP3AndHDRInsideGlass() throws {
        let (session, window, agent) = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 0, 255]]],
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "glass-hdr", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 3, "kind": "view", "props": ["testId": "p3"]],
            ["op": "create", "id": 4, "kind": "view", "props": ["testId": "hdr"]],
            ["op": "children", "id": 2, "ids": [3, 4]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 300.0, "h": 200.0],
            ["op": "frame", "id": 2, "x": 20.0, "y": 20.0, "w": 220.0, "h": 120.0],
            ["op": "frame", "id": 3, "x": 10.0, "y": 10.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 4, "x": 110.0, "y": 10.0, "w": 80.0, "h": 80.0],
        ], size: CGSize(width: 300, height: 200))
        defer { window.close() }
        let p = session.presenter
        let p3Node = try XCTUnwrap(p.views[3]), hdrNode = try XCTUnwrap(p.views[4])
        let p3Space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.displayP3))
        let extSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.extendedSRGB))
        p3Node.wantsLayer = true
        let p3Layer = CALayer()
        p3Layer.frame = p3Node.bounds
        p3Layer.backgroundColor = CGColor(colorSpace: p3Space, components: [1, 0, 0, 1])
        try XCTUnwrap(p3Node.layer).addSublayer(p3Layer)

        hdrNode.wantsLayer = true
        let hdrLayer = CALayer()
        hdrLayer.frame = hdrNode.bounds
        hdrLayer.backgroundColor = CGColor(colorSpace: extSpace, components: [1.5, 0, 0, 1])
        try XCTUnwrap(hdrNode.layer).addSublayer(hdrLayer)
        window.displayIfNeeded(); CATransaction.flush()

        let p3Reply = agent.sample(["points": [point(agent, p3Node, dx: 40, dy: 40)]])
        XCTAssertNil(p3Reply["error"], "\(p3Reply)")
        let p3Px = try XCTUnwrap((p3Reply["values"] as? [[Double]])?.first)
        XCTAssertGreaterThan(p3Px[0], 1.1, "Display P3 red exceeds sRGB 1.0 in linear sRGB: \(p3Px)")
        XCTAssertLessThan(p3Px[1], -0.02, "Display P3 red has negative linear-sRGB green: \(p3Px)")

        let hdrReply = agent.sample(["points": [point(agent, hdrNode, dx: 40, dy: 40)]])
        XCTAssertNil(hdrReply["error"], "\(hdrReply)")
        let hdrPx = try XCTUnwrap((hdrReply["values"] as? [[Double]])?.first)
        XCTAssertGreaterThan(hdrPx[0], 2.0, "HDR extended red stays above 1.0: \(hdrPx)")
    }

    /// Tinted glass must not wipe unrelated plain views via destIn; translucent content over glass refuses,
    /// points outside rounded corners sample the backdrop, nested/grouped glass behave cleanly,
    /// and the live layer tree plus active field editor remain intact.
    func testSampleHandlesTintedGlassCornersNestedGroupedAndPreservesLiveState() throws {
        let (session, window, agent) = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "outside-plain"], "style": ["background_color": [255, 0, 0, 255]]],
            // Tinted rounded glass with opaque red + translucent red children
            ["op": "create", "id": 3, "kind": "view", "props": ["testId": "tinted-glass", "backgroundMaterial": "glass"],
             "style": ["border_radius": 32.0, "glass_tint": [255, 128, 0, 200]]],
            ["op": "create", "id": 4, "kind": "view", "props": ["testId": "tinted-red"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "create", "id": 5, "kind": "view", "props": ["testId": "tinted-half"], "style": ["background_color": [255, 0, 0, 128]]],
            // Nested glass
            ["op": "create", "id": 6, "kind": "view", "props": ["testId": "outer-glass", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 7, "kind": "view", "props": ["testId": "inner-glass", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 8, "kind": "view", "props": ["testId": "nested-red"], "style": ["background_color": [255, 0, 0, 255]]],
            // Grouped glass (NSGlassEffectContainerView)
            ["op": "create", "id": 9, "kind": "view", "props": ["testId": "group", "glassGroup": "12"], "style": ["background_color": [0, 255, 0, 255]]],
            ["op": "create", "id": 10, "kind": "view", "props": ["testId": "member-glass", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 11, "kind": "view", "props": ["testId": "member-red"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "children", "id": 3, "ids": [4, 5]],
            ["op": "children", "id": 7, "ids": [8]],
            ["op": "children", "id": 6, "ids": [7]],
            ["op": "children", "id": 10, "ids": [11]],
            ["op": "children", "id": 9, "ids": [10]],
            ["op": "children", "id": 1, "ids": [2, 3, 6, 9]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 480.0, "h": 420.0],
            ["op": "frame", "id": 2, "x": 20.0, "y": 20.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 3, "x": 100.0, "y": 20.0, "w": 160.0, "h": 100.0],
            ["op": "frame", "id": 4, "x": 36.0, "y": 20.0, "w": 40.0, "h": 60.0],
            ["op": "frame", "id": 5, "x": 86.0, "y": 20.0, "w": 40.0, "h": 60.0],
            ["op": "frame", "id": 6, "x": 20.0, "y": 140.0, "w": 160.0, "h": 120.0],
            ["op": "frame", "id": 7, "x": 30.0, "y": 20.0, "w": 100.0, "h": 80.0],
            ["op": "frame", "id": 8, "x": 20.0, "y": 20.0, "w": 60.0, "h": 40.0],
            ["op": "frame", "id": 9, "x": 220.0, "y": 140.0, "w": 200.0, "h": 120.0],
            ["op": "frame", "id": 10, "x": 10.0, "y": 10.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 11, "x": 15.0, "y": 15.0, "w": 50.0, "h": 50.0],
        ], size: CGSize(width: 480, height: 420))
        defer { window.close() }
        let p = session.presenter
        let outsidePlain = try XCTUnwrap(p.views[2])
        let tintedGlass = try XCTUnwrap(p.views[3]), tintedRed = try XCTUnwrap(p.views[4]), tintedHalf = try XCTUnwrap(p.views[5])
        let outerGlass = try XCTUnwrap(p.views[6]), innerGlass = try XCTUnwrap(p.views[7]), nestedRed = try XCTUnwrap(p.views[8])
        let group = try XCTUnwrap(p.views[9]), memberGlass = try XCTUnwrap(p.views[10]), memberRed = try XCTUnwrap(p.views[11])

        // Focus an NSTextField inside the tinted glass to verify sample preserves live responder and layer structure.
        let field = NSTextField(frame: NSRect(x: 130, y: 60, width: 20, height: 20))
        tintedGlass.container.addSubview(field)
        window.makeKeyAndOrderFront(nil)
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor())
        let glassLayer = try XCTUnwrap(tintedGlass.materialView?.layer)
        let beforeSublayers = glassLayer.sublayers ?? []
        let beforeHidden = beforeSublayers.map(\.isHidden)

        // Plain view outside tinted glass is NOT wiped by destIn.
        try assertLinear(agent.sample(["points": [point(agent, outsidePlain, dx: 30, dy: 30)]]), equals: [1, 0, 0, 1], "plain outside tinted glass")
        // Opaque red inside tinted glass samples red; translucent child refuses naming tinted-glass.
        try assertLinear(agent.sample(["points": [point(agent, tintedRed, dx: 20, dy: 30)]]), equals: [1, 0, 0, 1], "red inside tinted glass")
        let translucent = agent.sample(["points": [point(agent, tintedHalf, dx: 20, dy: 30)]])
        XCTAssertTrue((translucent["error"] as? String)?.contains("tinted-glass") == true, "translucent over glass refuses: \(translucent)")
        // Cut-out rounded corner outside the 32 pt radius reads the blue backdrop rather than refusing.
        try assertLinear(agent.sample(["points": [point(agent, tintedGlass, dx: 2, dy: 2)]]), equals: [0, 0, 1, 1], "outside rounded corner reads backdrop")

        // Nested glass: opaque inside inner -> red; bare inner -> refuses inner; bare outer -> refuses outer.
        try assertLinear(agent.sample(["points": [point(agent, nestedRed, dx: 30, dy: 20)]]), equals: [1, 0, 0, 1], "opaque inside nested glass")
        let bareInner = agent.sample(["points": [point(agent, innerGlass, dx: 5, dy: 5)]])
        XCTAssertTrue((bareInner["error"] as? String)?.contains("inner-glass") == true, "bare inner refuses inner: \(bareInner)")
        let bareOuter = agent.sample(["points": [point(agent, outerGlass, dx: 5, dy: 5)]])
        XCTAssertTrue((bareOuter["error"] as? String)?.contains("outer-glass") == true, "bare outer refuses outer: \(bareOuter)")

        // Grouped glass: opaque inside member -> red; bare member -> refuses member; empty container background -> green.
        try assertLinear(agent.sample(["points": [point(agent, memberRed, dx: 25, dy: 25)]]), equals: [1, 0, 0, 1], "opaque inside grouped glass")
        let bareMember = agent.sample(["points": [point(agent, memberGlass, dx: 5, dy: 5)]])
        XCTAssertTrue((bareMember["error"] as? String)?.contains("member-glass") == true, "bare grouped member refuses: \(bareMember)")
        try assertLinear(agent.sample(["points": [point(agent, group, dx: 150, dy: 60)]]), equals: [0, 1, 0, 1], "empty group container reads green background")

        // Repeated sample returns identical values and leaves live sublayers + active editor untouched.
        try assertLinear(agent.sample(["points": [point(agent, tintedRed, dx: 20, dy: 30)]]), equals: [1, 0, 0, 1], "repeated sample")
        XCTAssertEqual(glassLayer.sublayers?.map(ObjectIdentifier.init), beforeSublayers.map(ObjectIdentifier.init), "glass sublayers identity/order preserved")
        XCTAssertEqual(glassLayer.sublayers?.map(\.isHidden), beforeHidden, "glass sublayers visibility restored")
        XCTAssertTrue(window.firstResponder === editor, "active field editor preserved")
    }

    /// Grouped glass on macOS paints above ordinary group siblings (LLP 1053.000.000 D5) while
    /// staying below covers outside the group, refuses conservatively in merge bridges within
    /// `spacing`, samples backdrop across wider gaps, and keeps isolated members at CSS order.
    func testSampleGroupedGlassPaintOrderMergeBridgesAndIsolation() throws {
        let (session, window, agent) = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 0, 255]]],
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "group", "glassGroup": "12"], "style": ["background_color": [0, 255, 0, 255]]],
            // Two close members (gap 6 < spacing 12) that merge, plus a third far member (gap 28 > 12).
            ["op": "create", "id": 3, "kind": "view", "props": ["testId": "m1", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 4, "kind": "view", "props": ["testId": "m1-red"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "create", "id": 5, "kind": "view", "props": ["testId": "m2", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 6, "kind": "view", "props": ["testId": "m2-yellow"], "style": ["background_color": [255, 255, 0, 255]]],
            ["op": "create", "id": 7, "kind": "view", "props": ["testId": "m3", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 8, "kind": "view", "props": ["testId": "m3-cyan"], "style": ["background_color": [0, 255, 255, 255]]],
            // Ordinary opaque blue sibling painted AFTER m1/m2, overlapping m1, its bare padding, the m1-m2 bridge, and free space.
            ["op": "create", "id": 9, "kind": "view", "props": ["testId": "group-sibling"], "style": ["background_color": [0, 0, 255, 255]]],
            // Isolated glass (opacity < 1 forces GlassIsolationView) followed by a later opaque magenta sibling inside the group.
            ["op": "create", "id": 10, "kind": "view", "props": ["testId": "iso-glass", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 11, "kind": "view", "props": ["testId": "iso-cover"], "style": ["background_color": [255, 0, 255, 255]]],
            // Opaque white cover painted AFTER the group (outside the group), overlapping part of m2.
            ["op": "create", "id": 12, "kind": "view", "props": ["testId": "outer-cover"], "style": ["background_color": [255, 255, 255, 255]]],
            ["op": "children", "id": 3, "ids": [4]],
            ["op": "children", "id": 5, "ids": [6]],
            ["op": "children", "id": 7, "ids": [8]],
            ["op": "children", "id": 2, "ids": [3, 5, 7, 9, 10, 11]],
            ["op": "children", "id": 1, "ids": [2, 12]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 460.0, "h": 300.0],
            ["op": "frame", "id": 2, "x": 20.0, "y": 20.0, "w": 420.0, "h": 240.0],
            ["op": "frame", "id": 3, "x": 20.0, "y": 20.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 4, "x": 15.0, "y": 15.0, "w": 50.0, "h": 50.0],
            ["op": "frame", "id": 5, "x": 106.0, "y": 20.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 6, "x": 15.0, "y": 15.0, "w": 50.0, "h": 50.0],
            ["op": "frame", "id": 7, "x": 214.0, "y": 20.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 8, "x": 15.0, "y": 15.0, "w": 50.0, "h": 50.0],
            ["op": "frame", "id": 9, "x": 10.0, "y": 10.0, "w": 110.0, "h": 110.0],
            ["op": "frame", "id": 10, "x": 20.0, "y": 140.0, "w": 80.0, "h": 60.0],
            ["op": "frame", "id": 11, "x": 20.0, "y": 140.0, "w": 80.0, "h": 60.0],
            ["op": "frame", "id": 12, "x": 160.0, "y": 40.0, "w": 40.0, "h": 60.0],
            ["op": "present", "id": 10, "property": "opacity", "x": 0.5, "y": 0.0, "w": 0.0, "h": 0.0],
        ], size: CGSize(width: 460, height: 300))
        defer { window.close() }
        let p = session.presenter
        let group = try XCTUnwrap(p.views[2])
        let m1 = try XCTUnwrap(p.views[3]), m1Red = try XCTUnwrap(p.views[4])
        let m2Yellow = try XCTUnwrap(p.views[6]), m3Cyan = try XCTUnwrap(p.views[8])
        let sibling = try XCTUnwrap(p.views[9])
        let isoCover = try XCTUnwrap(p.views[11])
        let outerCover = try XCTUnwrap(p.views[12])

        // Grouped glass paints above the later blue sibling: m1's red child wins and bare m1 padding refuses.
        try assertLinear(agent.sample(["points": [point(agent, m1Red, dx: 25, dy: 25)]]), equals: [1, 0, 0, 1], "m1 red over later blue sibling")
        let bareM1 = agent.sample(["points": [point(agent, m1, dx: 5, dy: 5)]])
        XCTAssertTrue((bareM1["error"] as? String)?.contains("m1") == true, "bare m1 refuses even where blue sibling overlaps: \(bareM1)")

        // Merge bridge between m1 (x=20..100) and m2 (x=106..186) refuses naming the group, even over the blue sibling.
        let bridge = agent.sample(["points": [point(agent, group, dx: 103, dy: 60)]])
        XCTAssertTrue((bridge["error"] as? String)?.contains("group") == true, "merge bridge refuses naming group: \(bridge)")

        // Ordinary blue sibling still wins outside glass and bridge bounds; m2/m3 opaque children sample cleanly.
        try assertLinear(agent.sample(["points": [point(agent, sibling, dx: 4, dy: 4)]]), equals: [0, 0, 1, 1], "blue sibling outside glass")
        try assertLinear(agent.sample(["points": [point(agent, m2Yellow, dx: 10, dy: 25)]]), equals: [1, 1, 0, 1], "m2 yellow inside uncovered part")
        try assertLinear(agent.sample(["points": [point(agent, m3Cyan, dx: 25, dy: 25)]]), equals: [0, 1, 1, 1], "m3 cyan")

        // Gap between m2 (x=106..186) and m3 (x=214..294) is 28 pt > spacing 12: reads the group's green background.
        try assertLinear(agent.sample(["points": [point(agent, group, dx: 200, dy: 60)]]), equals: [0, 1, 0, 1], "wide gap reads green background")

        // Opaque white cover outside the group paints above m2 and wins.
        try assertLinear(agent.sample(["points": [point(agent, outerCover, dx: 15, dy: 25)]]), equals: [1, 1, 1, 1], "outer cover over grouped glass")

        // Isolated glass stays in its own GlassIsolationView at CSS order, so its later magenta sibling covers it.
        try assertLinear(agent.sample(["points": [point(agent, isoCover, dx: 40, dy: 30)]]), equals: [1, 0, 1, 1], "later sibling covers isolated glass")
    }

    /// Overlapping grouped members place all member content above the shared glass backdrop, exact
    /// spacing-boundary gaps and touching zero-spacing pills refuse conservatively, and a container's
    /// `sublayerTransform` is applied once rather than doubled.
    func testSampleGroupedGlassOverlappingContentBoundaryBridgesAndSublayerTransform() throws {
        let (session, window, agent) = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 0, 255]]],
            // Group 1 (spacing 12): overlapping bare member after content member + exact 12 pt boundary pair.
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "g1", "glassGroup": "12"], "style": ["background_color": [0, 255, 0, 255]]],
            ["op": "create", "id": 3, "kind": "view", "props": ["testId": "front-glass", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 4, "kind": "view", "props": ["testId": "front-red"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "create", "id": 5, "kind": "view", "props": ["testId": "later-bare", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 6, "kind": "view", "props": ["testId": "boundary-b", "backgroundMaterial": "glass"]],
            // Group 2 (spacing 0): two touching 50x50 pills (radius 25) + one separated by 8 pt.
            ["op": "create", "id": 7, "kind": "view", "props": ["testId": "g0", "glassGroup": "0"], "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 8, "kind": "view", "props": ["testId": "p1", "backgroundMaterial": "glass"], "style": ["border_radius": 25.0]],
            ["op": "create", "id": 9, "kind": "view", "props": ["testId": "p2", "backgroundMaterial": "glass"], "style": ["border_radius": 25.0]],
            ["op": "create", "id": 10, "kind": "view", "props": ["testId": "p3", "backgroundMaterial": "glass"], "style": ["border_radius": 25.0]],
            ["op": "children", "id": 3, "ids": [4]],
            ["op": "children", "id": 2, "ids": [3, 5, 6]],
            ["op": "children", "id": 7, "ids": [8, 9, 10]],
            ["op": "children", "id": 1, "ids": [2, 7]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 420.0, "h": 260.0],
            ["op": "frame", "id": 2, "x": 20.0, "y": 20.0, "w": 380.0, "h": 100.0],
            ["op": "frame", "id": 3, "x": 20.0, "y": 10.0, "w": 60.0, "h": 80.0],
            ["op": "frame", "id": 4, "x": 10.0, "y": 10.0, "w": 40.0, "h": 60.0],
            // Overlaps front-red (x=30..70) on x=55..70, and extends to x=115.
            ["op": "frame", "id": 5, "x": 55.0, "y": 10.0, "w": 60.0, "h": 80.0],
            // Exact spacing-boundary gap = 12 pt after later-bare (x=115 -> x=127).
            ["op": "frame", "id": 6, "x": 127.0, "y": 10.0, "w": 60.0, "h": 80.0],
            ["op": "frame", "id": 7, "x": 20.0, "y": 140.0, "w": 380.0, "h": 100.0],
            ["op": "frame", "id": 8, "x": 20.0, "y": 25.0, "w": 50.0, "h": 50.0],
            ["op": "frame", "id": 9, "x": 70.0, "y": 25.0, "w": 50.0, "h": 50.0],
            ["op": "frame", "id": 10, "x": 128.0, "y": 25.0, "w": 50.0, "h": 50.0],
        ], size: CGSize(width: 420, height: 260))
        defer { window.close() }
        let p = session.presenter
        let g1 = try XCTUnwrap(p.views[2]), frontRed = try XCTUnwrap(p.views[4]), laterBare = try XCTUnwrap(p.views[5])
        let g0 = try XCTUnwrap(p.views[7]), p1 = try XCTUnwrap(p.views[8])

        // Earlier member's opaque red child wins even where later bare member overlaps it; bare part of later member refuses.
        try assertLinear(agent.sample(["points": [point(agent, frontRed, dx: 30, dy: 30)]]), equals: [1, 0, 0, 1], "earlier opaque child wins over later bare grouped glass")
        let bareOverlap = agent.sample(["points": [point(agent, laterBare, dx: 45, dy: 40)]])
        XCTAssertTrue((bareOverlap["error"] as? String)?.contains("later-bare") == true, "later bare member still refuses: \(bareOverlap)")

        // Exact spacing boundary (gap == spacing == 12 pt) refuses naming g1.
        let boundaryGap = agent.sample(["points": [point(agent, g1, dx: 121, dy: 50)]])
        XCTAssertTrue((boundaryGap["error"] as? String)?.contains("g1") == true, "exact boundary gap refuses naming g1: \(boundaryGap)")

        // Zero spacing: touching rounded pills refuse at the concave seam (x=70, y=30), keep outer rounded corners readable,
        // and leave the 8 pt separated gap (x=124, y=50) reading the blue group background.
        let seam = agent.sample(["points": [point(agent, g0, dx: 70, dy: 30)]])
        XCTAssertTrue((seam["error"] as? String)?.contains("g0") == true, "touching zero-spacing seam refuses naming g0: \(seam)")
        try assertLinear(agent.sample(["points": [point(agent, p1, dx: 2, dy: 2)]]), equals: [0, 0, 1, 1], "outer rounded corner of touching pill reads backdrop")
        try assertLinear(agent.sample(["points": [point(agent, g0, dx: 124, dy: 50)]]), equals: [0, 0, 1, 1], "8 pt gap at spacing 0 reads backdrop")

        // Container sublayerTransform applies once, not twice: translate +25 pt in x shifts front-red from [50..90] to [75..115].
        let groupLayer = try XCTUnwrap(g1.glassGroupView?.layer)
        groupLayer.sublayerTransform = CATransform3DMakeTranslation(25, 0, 0)
        CATransaction.flush()
        // At x=95 (original 70 + 25, inside shifted front-red [75..115]): must sample RED, not doubled to [100..140].
        try assertLinear(agent.sample(["points": [[95.0, 70.0]]]), equals: [1, 0, 0, 1], "sublayerTransform applied once to grouped content")
        // At x=60 (original 35 + 25, left of shifted front-red [75..115] and inside shifted front-glass [65..125] -> actually left of front-glass):
        // At x=55 (original 30 + 25 = 55, left of shifted front-glass [65..125]): reads g1's green background.
        try assertLinear(agent.sample(["points": [[55.0, 70.0]]]), equals: [0, 1, 0, 1], "point left of sublayerTransform-shifted glass reads backdrop")
        // Shifted boundary bridge moves from g1.minX+121=141 to 141+25=166.
        let shiftedBridge = agent.sample(["points": [[166.0, 70.0]]])
        XCTAssertTrue((shiftedBridge["error"] as? String)?.contains("g1") == true, "sublayerTransform applied once to merge bridge: \(shiftedBridge)")
    }

    /// Covers nested glass containers (no cross-boundary merge), nested non-isolated glass inside
    /// a grouped member, contained rounded-corner bridges, perspective-transformed grouped replay,
    /// and a masked grouped member's own shadow outside its bounds.
    func testSampleGroupedGlassNestedContainersCornerBridgePerspectiveAndMaskedShadow() throws {
        let (session, window, agent) = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 0, 255]]],
            // 1. Nested containers: outer group (spacing 12) has outer-m1 and nested inner-group (spacing 12)
            //    with inner-m1 6 pt away across the boundary, plus inner-m2 6 pt from inner-m1 inside inner-group.
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "outer-group", "glassGroup": "12"], "style": ["background_color": [0, 255, 0, 255]]],
            ["op": "create", "id": 3, "kind": "view", "props": ["testId": "outer-m1", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 4, "kind": "view", "props": ["testId": "inner-group", "glassGroup": "12"], "style": ["background_color": [0, 255, 0, 255]]],
            ["op": "create", "id": 5, "kind": "view", "props": ["testId": "inner-m1", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 6, "kind": "view", "props": ["testId": "inner-m2", "backgroundMaterial": "glass"]],
            // 2. Group with contained corner pill + a separate unclipped glass holding a non-isolated nested NSGlassEffectView.
            ["op": "create", "id": 7, "kind": "view", "props": ["testId": "fused-group", "glassGroup": "12"], "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 8, "kind": "view", "props": ["testId": "big-pill", "backgroundMaterial": "glass"], "style": ["border_radius": 60.0]],
            ["op": "create", "id": 9, "kind": "view", "props": ["testId": "corner-pill", "backgroundMaterial": "glass"], "style": ["border_radius": 10.0]],
            ["op": "create", "id": 10, "kind": "view", "props": ["testId": "host-glass", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 11, "kind": "view", "props": ["testId": "host-red"], "style": ["background_color": [255, 0, 0, 255]]],
            // 3. Perspective-transformed grouped member + masked grouped member with an offset shadow.
            ["op": "create", "id": 12, "kind": "view", "props": ["testId": "fx-group", "glassGroup": "12"], "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 13, "kind": "view", "props": ["testId": "persp-member", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 14, "kind": "view", "props": ["testId": "persp-red"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "create", "id": 15, "kind": "view", "props": ["testId": "shadow-member", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 16, "kind": "view", "props": ["testId": "shadow-red"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "children", "id": 4, "ids": [5, 6]],
            ["op": "children", "id": 2, "ids": [3, 4]],
            ["op": "children", "id": 10, "ids": [11]],
            ["op": "children", "id": 7, "ids": [8, 9, 10]],
            ["op": "children", "id": 13, "ids": [14]],
            ["op": "children", "id": 15, "ids": [16]],
            ["op": "children", "id": 12, "ids": [13, 15]],
            ["op": "children", "id": 1, "ids": [2, 7, 12]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 460.0, "h": 340.0],
            ["op": "frame", "id": 2, "x": 20.0, "y": 10.0, "w": 420.0, "h": 80.0],
            ["op": "frame", "id": 3, "x": 10.0, "y": 10.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 4, "x": 76.0, "y": 0.0, "w": 160.0, "h": 80.0],
            ["op": "frame", "id": 5, "x": 0.0, "y": 10.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 6, "x": 66.0, "y": 10.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 7, "x": 20.0, "y": 100.0, "w": 200.0, "h": 220.0],
            ["op": "frame", "id": 8, "x": 10.0, "y": 10.0, "w": 120.0, "h": 120.0],
            // Contained inside big-pill's bounding box [10..130]x[10..130], sitting in its top-left cut-out corner.
            ["op": "frame", "id": 9, "x": 12.0, "y": 12.0, "w": 20.0, "h": 20.0],
            ["op": "frame", "id": 10, "x": 10.0, "y": 150.0, "w": 100.0, "h": 60.0],
            ["op": "frame", "id": 11, "x": 10.0, "y": 10.0, "w": 40.0, "h": 40.0],
            ["op": "frame", "id": 12, "x": 230.0, "y": 100.0, "w": 210.0, "h": 220.0],
            ["op": "frame", "id": 13, "x": 20.0, "y": 20.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 14, "x": 0.0, "y": 0.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 15, "x": 20.0, "y": 130.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 16, "x": 10.0, "y": 10.0, "w": 20.0, "h": 20.0],
        ], size: CGSize(width: 460, height: 340))
        defer { window.close() }
        let p = session.presenter
        let outerGroup = try XCTUnwrap(p.views[2]), innerGroup = try XCTUnwrap(p.views[4])
        let fusedGroup = try XCTUnwrap(p.views[7]), bigPill = try XCTUnwrap(p.views[8])
        let hostGlass = try XCTUnwrap(p.views[10]), hostRed = try XCTUnwrap(p.views[11])
        let fxGroup = try XCTUnwrap(p.views[12]), perspMember = try XCTUnwrap(p.views[13]), shadowMember = try XCTUnwrap(p.views[15])

        // Add a non-isolated nested NSGlassEffectView directly inside host-glass's contentView,
        // painted after host-red and overlapping it (both belonging to fused-group).
        let nestedGlass = NSGlassEffectView(frame: NSRect(x: 20, y: 10, width: 60, height: 40))
        hostGlass.container.addSubview(nestedGlass)
        window.layoutIfNeeded(); window.displayIfNeeded(); CATransaction.flush()

        // 1. Nested containers: 6 pt gap across container boundary (x=73 in outerGroup) reads green backdrop;
        //    6 pt gap inside innerGroup (x=63 in innerGroup) refuses naming inner-group.
        try assertLinear(agent.sample(["points": [point(agent, outerGroup, dx: 73, dy: 40)]]), equals: [0, 1, 0, 1], "cross-container gap does not merge")
        let innerBridge = agent.sample(["points": [point(agent, innerGroup, dx: 63, dy: 40)]])
        XCTAssertTrue((innerBridge["error"] as? String)?.contains("inner-group") == true, "inner container gap refuses naming inner-group: \(innerBridge)")

        // 2. Non-isolated nested glass inside host-glass sits in the shared backdrop pass, so host-red wins
        //    even where nestedGlass overlaps it, while bare nestedGlass outside host-red still refuses.
        try assertLinear(agent.sample(["points": [point(agent, hostRed, dx: 25, dy: 20)]]), equals: [1, 0, 0, 1], "earlier opaque red child wins over nested non-isolated grouped glass")
        let nestedBare = agent.sample(["points": [point(agent, hostGlass, dx: 65, dy: 30)]])
        XCTAssertTrue((nestedBare["error"] as? String)?.contains("host-glass") == true, "bare nested grouped glass still refuses: \(nestedBare)")
        // Contained corner pill in big-pill's top-left cut-out corner bridges to big-pill's rim (x=34, y=18 in fusedGroup,
        // outside both big-pill's 60 pt circle and corner-pill's [12..32] box), while big-pill's opposite bottom-right
        // cut-out corner (dx=118, dy=118) still samples blue backdrop.
        let cornerBridge = agent.sample(["points": [point(agent, fusedGroup, dx: 34, dy: 18)]])
        XCTAssertTrue((cornerBridge["error"] as? String)?.contains("fused-group") == true, "contained corner pill bridge refuses naming fused-group: \(cornerBridge)")
        try assertLinear(agent.sample(["points": [point(agent, bigPill, dx: 118, dy: 118)]]), equals: [0, 0, 1, 1], "opposite cut-out corner reads backdrop")

        // 3. Perspective-transformed grouped member: replay via geometry mirror matches exact 3D projection.
        var persp = CATransform3DIdentity
        persp.m34 = -1.0 / 160.0
        persp = CATransform3DRotate(persp, .pi / 3, 0, 1, 0)
        perspMember.wantsLayer = true
        let perspLayer = try XCTUnwrap(perspMember.layer)
        perspLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        perspLayer.position = CGPoint(x: 60, y: 60)
        perspLayer.transform = persp

        // 4. Masked grouped member with an extended mask and offset shadow: probe culling checks the
        //    member's own shadowOpacity so shadow pixels outside member.bounds are not skipped.
        let shadowGlassLayer = try XCTUnwrap(shadowMember.materialView?.layer)
        shadowGlassLayer.masksToBounds = false
        let shadowMask = CALayer()
        shadowMask.frame = CGRect(x: 0, y: 0, width: 100, height: 60)
        shadowMask.backgroundColor = CGColor(gray: 0, alpha: 1)
        shadowGlassLayer.mask = shadowMask
        shadowGlassLayer.shadowOpacity = 1
        shadowGlassLayer.shadowRadius = 0
        shadowGlassLayer.shadowOffset = CGSize(width: 30, height: 0)
        shadowGlassLayer.shadowColor = CGColor(gray: 0, alpha: 1)
        CATransaction.flush()

        // Under perspective m34 = -1/160, rotateY(60 deg): render(in:) keeps the quad at [20..100]x[20..100]
        // whereas a 3-point affine approximation from convert(_:to:) shifts it inward past x=40.
        try assertLinear(agent.sample(["points": [point(agent, fxGroup, dx: 25, dy: 25)]]), equals: [1, 0, 0, 1], "perspective-transformed grouped glass replay matches render(in:)")
        // Shadow extends 30 pt right of shadow-member (x=20..80 -> shadow at x=80..110, y=130..190).
        let shadowPoint = agent.sample(["points": [point(agent, fxGroup, dx: 95, dy: 160)]])
        XCTAssertTrue((shadowPoint["error"] as? String)?.contains("shadow-member") == true, "masked grouped member shadow is not culled: \(shadowPoint)")

        // 5. Unmasked grouped member with sublayerTransform + offset shadow:
        //    sublayerTransform shifts the probe onto a sampled pixel without culling it, and
        //    the unmasked replay preserves an opaque child's offset shadow outside member bounds.
        let unmaskedShadow = NSGlassEffectView(frame: NSRect(x: 120, y: 20, width: 40, height: 40))
        let unmaskedContent = NSView(frame: unmaskedShadow.bounds)
        unmaskedContent.wantsLayer = true
        unmaskedContent.layer?.backgroundColor = CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
        unmaskedShadow.contentView = unmaskedContent
        fxGroup.container.addSubview(unmaskedShadow)
        window.layoutIfNeeded(); window.displayIfNeeded(); CATransaction.flush()
        let unmaskedLayer = try XCTUnwrap(unmaskedShadow.layer)
        unmaskedLayer.masksToBounds = false
        unmaskedLayer.shadowOpacity = 1
        unmaskedLayer.shadowRadius = 0
        unmaskedLayer.shadowOffset = CGSize(width: 25, height: 0)
        unmaskedLayer.shadowColor = CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)
        CATransaction.flush()
        // Opaque red content casts a solid green shadow 25 pt right (x=160..185, y=20..60 inside fxGroup).
        try assertLinear(agent.sample(["points": [point(agent, fxGroup, dx: 170, dy: 40)]]), equals: [0, 1, 0, 1], "unmasked grouped replay preserves readable child shadow")

        // Now test member.layer.sublayerTransform shifting a bare unmasked member's probe by +40 pt in x.
        unmaskedContent.layer?.backgroundColor = nil
        unmaskedLayer.shadowOpacity = 0
        unmaskedLayer.sublayerTransform = CATransform3DMakeTranslation(40, 0, 0)
        CATransaction.flush()
        let shiftedProbe = agent.sample(["points": [point(agent, fxGroup, dx: 170, dy: 40)]])
        XCTAssertTrue((shiftedProbe["error"] as? String)?.contains("fx-group") == true, "member sublayerTransform probe is not culled: \(shiftedProbe)")

        // 6. Rotated unrounded square enclosing a smaller member's bounding box still bridges the gap.
        let rotGroup = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "rot-group", "glassGroup": "12"], "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 3, "kind": "view", "props": ["testId": "rot-big", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 4, "kind": "view", "props": ["testId": "rot-small", "backgroundMaterial": "glass"]],
            ["op": "children", "id": 2, "ids": [3, 4]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 220.0, "h": 220.0],
            ["op": "frame", "id": 2, "x": 0.0, "y": 0.0, "w": 220.0, "h": 220.0],
            ["op": "frame", "id": 3, "x": 60.0, "y": 60.0, "w": 100.0, "h": 100.0],
            ["op": "frame", "id": 4, "x": 45.0, "y": 45.0, "w": 18.0, "h": 18.0],
        ], size: CGSize(width: 220, height: 220))
        defer { rotGroup.window.close() }
        let rotBig = try XCTUnwrap(rotGroup.session.presenter.views[3])
        let rotGlassLayer = try XCTUnwrap(rotBig.materialView?.layer)
        rotGlassLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        rotGlassLayer.position = CGPoint(x: 50, y: 50)
        rotGlassLayer.transform = CATransform3DMakeRotation(.pi / 4, 0, 0, 1)
        CATransaction.flush()
        // Rotated 100x100 square centered at (110,110) has AABB [39.3..180.7]^2 enclosing rot-small [45..63]^2,
        // while the top-left rotated edge runs along (x-110)+(y-110) = -70.7 -> at (68, 68), outside both shapes.
        let rotBridge = rotGroup.agent.sample(["points": [[68.0, 68.0]]])
        XCTAssertTrue((rotBridge["error"] as? String)?.contains("rot-group") == true, "rotated square enclosing smaller member refuses bridge: \(rotBridge)")

        // 7. Two overlapping unavailable layers inside an alpha mask refuse together rather than shielding each other.
        let maskScene = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "masked-target"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "children", "id": 1, "ids": [2]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 120.0, "h": 120.0],
            ["op": "frame", "id": 2, "x": 20.0, "y": 20.0, "w": 80.0, "h": 80.0],
        ], size: CGSize(width: 120, height: 120))
        defer { maskScene.window.close() }
        let maskedTarget = try XCTUnwrap(maskScene.session.presenter.views[2])
        let maskHost = CALayer()
        maskHost.frame = maskedTarget.bounds
        let mA = CAMetalLayer(), mB = CAMetalLayer()
        mA.frame = maskedTarget.bounds; mB.frame = maskedTarget.bounds
        maskHost.addSublayer(mA); maskHost.addSublayer(mB)
        try XCTUnwrap(maskedTarget.layer).mask = maskHost
        CATransaction.flush()
        let maskReply = maskScene.agent.sample(["points": [point(maskScene.agent, maskedTarget, dx: 40, dy: 40)]])
        XCTAssertTrue((maskReply["error"] as? String)?.contains("Metal") == true, "overlapping unavailable probes in alpha mask refuse together: \(maskReply)")
    }

    /// Hosted snapshots on a glass root take precedence over glass refusal, a rectangular mask
    /// combines with `glass.cornerRadius`, observer-driven visibility changes survive restore,
    /// and probes outside sampled pixels do not trigger extra full-tree renders.
    func testSampleGlassHostedSnapshotMaskCornerObserverAndProbeCulling() throws {
        // 1. Hosted snapshot precedence: native view whose root is NSGlassEffectView.
        final class SnapshotHostStub: NativeModuleHosting {
            weak var session: ExactSession?
            var diagnostics: (any HatchDiagnosing)? { nil }
            var hatchIncarnation: UInt32 { 0 }
            var isEmpty: Bool { snapshotViews.isEmpty }
            var hatchesConnected: Bool { false }
            var hasAppModule: Bool { false }
            var onHatchesConnected: (() -> Void)?
            var activationQueued: Bool { false }
            var quitWorkPending: Bool { false }
            var ownsWindow = false
            var ownsProcess = false
            func artifactFailure() -> String? { nil }
            var firstFrameTags: Set<String> { [] }
            var holds: ((NodeView) -> Bool)?
            var measured: ((String, TimeInterval) -> Void)?
            func installAppModule() {}
            func prepareAppModule() {}
            func activateAfterCommit(_ live: @escaping () -> Bool) {}
            func loadIfNeeded() {}
            func endViewBindings() {}
            func destroyModule() {}
            func sessionViewChanged() {}
            func willQuit() {}
            func formaMoved() {}
            func imageEntry() -> (UnsafeMutableRawPointer, PackageImageFn)? { nil }
            func authenticator() -> (UnsafeMutableRawPointer, PresenceAuthenticateFn)? { nil }
            func hatchSeq(_ seq: UInt64) {}
            func resetHatchClock() {}
            func beginHatchCommand() {}
            func refreshHatchClock(at now: Double) -> String? { nil }
            var hatchNextAfter: Double? { nil }
            var hatchNextInstant: Double? { nil }
            func fireHatchClock(at now: Double) -> String? { nil }
            func hatchesPresented(_ now: Double) -> Bool { false }
            var liveTickets: Int { 0 }
            func scopesChanged() {}
            func windowLeaving(_ window: FocusWindow?) {}
            var hasTabHatches: Bool { false }
            func tabsHatch(_ controller: AnyObject?, event: UInt32, index: Int) {}
            func tabContainerHatch(names: [String], nodes: [UInt32], selected: Int, controllers: [AnyObject]) -> AnyObject? { nil }
            func tabNodesChanged(_ nodes: [UInt32]) {}
            func navigationHatch(_ controller: AnyObject, built: Bool, showsBar: Bool, label: String) -> Bool { showsBar }
            func routeHatch(_ event: RouteHatchEvent, controller: AnyObject, navigation: AnyObject?, scroll: AnyObject?, key: String, dataset: String?) {}
            func toolbarHatch(_ toolbar: AnyObject, window: AnyObject) {}
            func create(owner: NodeView) {}
            func update(_ owner: NodeView) {}
            func destroy(id: UInt32) {}
            func laidOut(_ owner: NodeView) {}
            func release(_ owner: NodeView) {}
            func recycleFar(hide: CGFloat, release: CGFloat, _ distance: (NodeView) -> CGFloat?) -> [NodeView] { [] }
            var snapshotViews: [UInt32: NativePlatformView] = [:]
            var supplied: [UInt32: NativeImage] = [:]
            func snapshots() -> [UInt32: NativeImage] { supplied }
            func decorate(_ tree: [String: Any]) -> [String: Any] { tree }
            func ownsFocus(_ owner: NodeView) -> Bool { false }
            func focus(_ owner: NodeView) -> Bool { false }
            func focusTarget(_ owner: NodeView) -> NSView? { nil }
            func inputToken(_ owner: NodeView) -> UInt32? { nil }
            func input(_ owner: NodeView, request: [String: Any], token: UInt32?) -> [String: Any] { ["error": "no native module"] }
        }

        final class RenderCounterLayer: CALayer {
            var renderCount = 0
            override func render(in ctx: CGContext) {
                renderCount += 1
                super.render(in: ctx)
            }
        }

        let stub = SnapshotHostStub()
        let previousMake = NativeModuleLink.make
        NativeModuleLink.make = { stub }
        defer { NativeModuleLink.make = previousMake }

        let (session, window, agent) = try makeScene([
            ["op": "create", "id": 1, "kind": "view", "style": ["background_color": [0, 0, 255, 255]]],
            ["op": "create", "id": 2, "kind": "view", "props": ["testId": "hosted-glass"]],
            ["op": "create", "id": 3, "kind": "view", "props": ["testId": "masked-glass"]],
            ["op": "create", "id": 4, "kind": "view", "props": ["testId": "far-1", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 5, "kind": "view", "props": ["testId": "far-2", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 6, "kind": "view", "props": ["testId": "far-3", "backgroundMaterial": "glass"]],
            ["op": "create", "id": 7, "kind": "view", "props": ["testId": "plain-target"], "style": ["background_color": [255, 0, 0, 255]]],
            ["op": "create", "id": 8, "kind": "view", "props": ["testId": "hosted-container"]],
            ["op": "create", "id": 9, "kind": "view", "props": ["testId": "tilted-metal"]],
            ["op": "children", "id": 1, "ids": [2, 3, 4, 5, 6, 7, 8, 9]],
            ["op": "roots", "ids": [1]],
            ["op": "frame", "id": 1, "x": 0.0, "y": 0.0, "w": 460.0, "h": 260.0],
            ["op": "frame", "id": 2, "x": 20.0, "y": 20.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 3, "x": 120.0, "y": 20.0, "w": 100.0, "h": 100.0],
            ["op": "frame", "id": 4, "x": 240.0, "y": 20.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 5, "x": 310.0, "y": 20.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 6, "x": 380.0, "y": 20.0, "w": 60.0, "h": 60.0],
            ["op": "frame", "id": 7, "x": 20.0, "y": 150.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 8, "x": 120.0, "y": 150.0, "w": 80.0, "h": 80.0],
            ["op": "frame", "id": 9, "x": 240.0, "y": 150.0, "w": 80.0, "h": 80.0],
        ], size: CGSize(width: 460, height: 260))
        defer { window.close() }
        let p = session.presenter
        let hostedNode = try XCTUnwrap(p.views[2])
        let maskedNode = try XCTUnwrap(p.views[3])
        let plainTarget = try XCTUnwrap(p.views[7])
        let hostedContainerNode = try XCTUnwrap(p.views[8])
        let tiltedNode = try XCTUnwrap(p.views[9])

        // Mount an NSGlassEffectView AND an NSGlassEffectContainerView as native hosted snapshot views.
        let hostedGlass = NSGlassEffectView(frame: hostedNode.bounds)
        hostedNode.addSubview(hostedGlass)
        let greenImage = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
            NSColor(srgbRed: 0, green: 1, blue: 0, alpha: 1).setFill()
            rect.fill()
            return true
        }
        stub.snapshotViews[2] = hostedGlass
        stub.supplied[2] = greenImage

        let hostedContainer = NSGlassEffectContainerView(frame: hostedContainerNode.bounds)
        let hostedInner = NSGlassEffectView(frame: hostedContainer.bounds)
        hostedContainer.contentView = hostedInner
        hostedContainerNode.addSubview(hostedContainer)
        let cyanImage = NSImage(size: NSSize(width: 80, height: 80), flipped: false) { rect in
            NSColor(srgbRed: 0, green: 1, blue: 1, alpha: 1).setFill()
            rect.fill()
            return true
        }
        stub.snapshotViews[8] = hostedContainer
        stub.supplied[8] = cyanImage

        // 2. Rectangular layer.mask combined with glass.cornerRadius on an NSGlassEffectView.
        let maskedGlass = NSGlassEffectView(frame: maskedNode.bounds)
        maskedGlass.cornerRadius = 32
        maskedGlass.wantsLayer = true
        let rectMask = CALayer()
        rectMask.frame = maskedGlass.bounds
        rectMask.backgroundColor = CGColor(gray: 0, alpha: 1)
        maskedGlass.layer?.mask = rectMask
        maskedNode.addSubview(maskedGlass)

        // 3. Render counter layer to verify distant glass probes are culled.
        let counter = RenderCounterLayer()
        counter.frame = CGRect(x: 0, y: 0, width: 10, height: 10)
        try XCTUnwrap(p.views[1]?.layer).addSublayer(counter)

        window.layoutIfNeeded()
        window.displayIfNeeded()
        CATransaction.flush()

        // Hosted snapshots on both NSGlassEffectView and NSGlassEffectContainerView take precedence over glass refusal.
        try assertLinear(agent.sample(["points": [point(agent, hostedNode, dx: 40, dy: 40)]]), equals: [0, 1, 0, 1], "hosted glass snapshot wins")
        try assertLinear(agent.sample(["points": [point(agent, hostedContainerNode, dx: 40, dy: 40)]]), equals: [0, 1, 1, 1], "hosted glass container snapshot wins")
        stub.supplied.removeAll()
        let missingHosted = agent.sample(["points": [point(agent, hostedNode, dx: 40, dy: 40)]])
        XCTAssertTrue((missingHosted["error"] as? String)?.contains("hosted view returned no snapshot") == true, "missing hosted glass snapshot keeps hosted reason: \(missingHosted)")
        let missingContainer = agent.sample(["points": [point(agent, hostedContainerNode, dx: 40, dy: 40)]])
        XCTAssertTrue((missingContainer["error"] as? String)?.contains("hosted view returned no snapshot") == true, "missing hosted container snapshot keeps hosted reason: \(missingContainer)")
        stub.supplied[2] = greenImage
        stub.supplied[8] = cyanImage

        // Rectangular mask + glass.cornerRadius: corner outside 32 pt radius reads blue backdrop, center refuses.
        try assertLinear(agent.sample(["points": [point(agent, maskedNode, dx: 2, dy: 2)]]), equals: [0, 0, 1, 1], "corner outside glass radius inside rect mask reads backdrop")
        let maskedCenter = agent.sample(["points": [point(agent, maskedNode, dx: 50, dy: 50)]])
        XCTAssertTrue((maskedCenter["error"] as? String)?.contains("masked-glass") == true, "masked glass center still refuses: \(maskedCenter)")

        // Bounding-box probe culling: sampling plainTarget far from all glass views renders exactly once.
        counter.renderCount = 0
        try assertLinear(agent.sample(["points": [point(agent, plainTarget, dx: 40, dy: 40)]]), equals: [1, 0, 0, 1], "plain target away from glass")
        XCTAssertEqual(counter.renderCount, 1, "probes outside sampled pixels should be culled without extra full-tree renders")

        // Non-affine 3D transform (60 deg X-axis rotation) disables culling so a tilted Metal layer still refuses.
        let tiltedMetal = CAMetalLayer()
        tiltedMetal.frame = CGRect(x: 20, y: 20, width: 40, height: 40)
        tiltedMetal.transform = CATransform3DMakeRotation(.pi / 3, 1, 0, 0)
        try XCTUnwrap(tiltedNode.layer).addSublayer(tiltedMetal)
        let tiltedReply = agent.sample(["points": [point(agent, tiltedNode, dx: 40, dy: 30)]])
        XCTAssertTrue((tiltedReply["error"] as? String)?.contains("Metal") == true, "3D rotated probe must not be culled: \(tiltedReply)")

        // Temporary suppression leaves `isHidden` untouched and restores prior opacity.
        let far1GlassLayer = try XCTUnwrap(p.views[4]?.materialView?.layer)
        let far1Effect = try XCTUnwrap(far1GlassLayer.sublayers?.first { $0 !== Capture.glassContentBranch(of: far1GlassLayer, content: (p.views[4]?.materialView as? NSGlassEffectView)?.contentView?.layer) })
        var hiddenKVO = 0
        let token = far1Effect.observe(\.isHidden, options: [.new]) { _, _ in hiddenKVO += 1 }
        defer { token.invalidate() }
        try assertLinear(agent.sample(["points": [point(agent, plainTarget, dx: 40, dy: 40)]]), equals: [1, 0, 0, 1], "sample without mutating isHidden")
        XCTAssertEqual(hiddenKVO, 0, "sample leaves isHidden untouched")
        XCTAssertEqual(far1Effect.opacity, 1, "suppressed effect opacity restored")
    }
}
#endif
