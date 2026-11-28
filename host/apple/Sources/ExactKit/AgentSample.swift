// @ref LLP 1100 D12. Core Animation composites in a floating-point bitmap,
// including supplied frames at the layers the render server normally draws.
// On iOS 27 render(in:) still clips native extended-range gradients and omits shadows.
import AVFoundation
import CoreImage
import QuartzCore
#if os(iOS) || os(tvOS)
import UIKit
#else
import AppKit
#endif

private struct SamplePicture {
    let layer: CALayer
    let area: CGRect
    let image: CGImage?
    let refusal: String?
    let replacesSubviews: Bool
    let clip: Bool
    let hiddenSublayers: [CALayer]
    let cornerRadius: CGFloat
}

private struct SampleProbe {
    let layer: CALayer
    let area: CGRect
    let reason: String
    let setColor: (CGColor) -> Void
}

#if os(macOS)
private struct GlassMemberSample {
    let layer: CALayer
    let contentBranch: CALayer?
    let cornerRadius: CGFloat
    let refusal: String?
}

private struct GlassContainerSample {
    let layer: CALayer
    let spacing: CGFloat
    let refusal: String
    let hiddenSublayers: [CALayer]
    var topLevelMembers: [GlassMemberSample]
    var backdropMembers: [GlassMemberSample]
    var bridgeMembers: [(layer: CALayer, cornerRadius: CGFloat)]
}

private func copyLayerGeometry(from src: CALayer, to dst: CALayer) {
    dst.bounds = src.bounds
    dst.position = src.position
    dst.anchorPoint = src.anchorPoint
    dst.anchorPointZ = src.anchorPointZ
    dst.isGeometryFlipped = src.isGeometryFlipped
    dst.transform = src.transform
    dst.sublayerTransform = src.sublayerTransform
    dst.isDoubleSided = src.isDoubleSided
}

private func copyLayerShadow(from src: CALayer, to dst: CALayer) {
    dst.shadowOpacity = src.shadowOpacity
    dst.shadowColor = src.shadowColor
    dst.shadowOffset = src.shadowOffset
    dst.shadowRadius = src.shadowRadius
    dst.shadowPath = src.shadowPath
}

/// Builds a lightweight geometry-only mirror chain from `host` (exclusive) down to `target`
/// (inclusive), placing `leaf` at `target`. Preserves full 3D perspective and flips without
/// reparenting any live layer.
private func makeGeometryMirror(from host: CALayer, to target: CALayer, leaf: CALayer) -> CALayer? {
    var chain: [CALayer] = []
    var cur: CALayer? = target
    while let c = cur, c !== host {
        chain.append(c)
        cur = c.superlayer
    }
    guard cur === host, !chain.isEmpty else { return nil }
    let ordered = Array(chain.reversed())
    var parent: CALayer?
    var top: CALayer?
    for i in 0..<ordered.count {
        let w = (i == ordered.count - 1) ? leaf : CALayer()
        copyLayerGeometry(from: ordered[i], to: w)
        if let p = parent { p.addSublayer(w) } else { top = w }
        parent = w
    }
    return top
}

/// Renders a live layer directly at the geometry established by an enclosing mirror chain.
private final class GlassBranchReplayLayer: CALayer {
    weak var branch: CALayer?

    init(branch: CALayer) {
        self.branch = branch
        super.init()
        copyLayerGeometry(from: branch, to: self)
    }

    required init?(coder: NSCoder) { nil }

    override func render(in ctx: CGContext) {
        guard let branch, !branch.isHidden, branch.opacity > 0 else { return }
        branch.render(in: ctx)
    }
}

/// Renders a masked grouped `NSGlassEffectView`'s backdrop probe through its live mask at the
/// mirror chain's 3D geometry, keeping its public content suppressed for the shared glass pass.
private final class GlassMaskedBackdropReplayLayer: CALayer {
    weak var target: CALayer?
    weak var contentBranch: CALayer?
    let stand: CALayer
    let replayOpacity: Float

    init(target: CALayer, contentBranch: CALayer?, stand: CALayer, replayOpacity: Float) {
        self.target = target
        self.contentBranch = contentBranch
        self.stand = stand
        self.replayOpacity = replayOpacity
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func render(in ctx: CGContext) {
        guard let target else { return }
        let branchSaved = contentBranch?.opacity
        if let contentBranch, contentBranch.opacity > 0 { contentBranch.opacity = 0 }
        let saved = target.opacity
        if saved == 0 { target.opacity = replayOpacity }
        target.insertSublayer(stand, at: 0)
        target.render(in: ctx)
        stand.removeFromSuperlayer()
        if target.opacity == replayOpacity { target.opacity = saved }
        if let contentBranch, let branchSaved, contentBranch.opacity == 0 { contentBranch.opacity = branchSaved }
    }
}

/// Renders a masked grouped `NSGlassEffectView`'s content through its live mask at the mirror
/// chain's 3D geometry above the container's shared glass layer.
private final class GlassMaskedContentReplayLayer: CALayer {
    weak var target: CALayer?
    let replayOpacity: Float

    init(target: CALayer, replayOpacity: Float) {
        self.target = target
        self.replayOpacity = replayOpacity
        super.init()
    }

    required init?(coder: NSCoder) { nil }

    override func render(in ctx: CGContext) {
        guard let target else { return }
        let saved = target.opacity
        if saved == 0 { target.opacity = replayOpacity }
        target.render(in: ctx)
        if target.opacity == replayOpacity { target.opacity = saved }
    }
}
#endif

extension Agent {
    func sample(_ req: [String: Any]) -> [String: Any] {
        _ = settleForPicture()
        if let now = session.clock {
            _ = session.canvases.waitUntilReady()
            session.canvases.settle(now: now)
        }
        presenter.canvas2d.waitForReplays()
        let requested = req["points"] as? [[Any]] ?? []
        let points = requested.compactMap { p -> CGPoint? in
            guard p.count == 2, let x = (p[0] as? NSNumber)?.doubleValue, let y = (p[1] as? NSNumber)?.doubleValue,
                  x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard !points.isEmpty, points.count == requested.count else { return ["malformed": true, "error": "sample needs pairs of finite viewport coordinates"] }

        // Snapshot providers can run the main loop. Finish them before borrowing any live layer.
        var guests: [UInt32: ExactWebImage] = [:]
        var stableGuests = false
        for _ in 0..<3 {
            let commit = session.appliedBatches
            guests = session.webviews.snapshots().merging(session.natives.snapshots()) { web, _ in web }
            #if targetEnvironment(simulator) && (os(iOS) || os(tvOS))
            // WebKit's simulator snapshot flushes remote text. UIKit can then draw
            // that text at backing scale, including the guest's transparent pixels.
            for id in Array(guests.keys) {
                guard let web = presenter.views[id]?.web, !web.bounds.isEmpty else { continue }
                let format = UIGraphicsImageRendererFormat()
                format.scale = web.window?.screen.scale ?? web.traitCollection.displayScale
                format.opaque = false
                format.preferredRange = .extended
                var complete = false
                let image = UIGraphicsImageRenderer(bounds: web.bounds, format: format).image { _ in
                    complete = web.drawHierarchy(in: web.bounds, afterScreenUpdates: true)
                }
                guests[id] = complete ? image : nil
            }
            #endif
            if session.appliedBatches == commit { stableGuests = true; break }
        }
        if !stableGuests { guests.removeAll() }
        #if os(iOS) || os(tvOS)
        let view = presenter.viewport
        let size = view.pageSize
        let scale = max(1, view.window?.screen.scale ?? view.traitCollection.displayScale)
        let layer: CALayer
        var mapping = CGAffineTransform.identity
        let area = view.window.map { view.convert(view.pageBounds, to: $0) } ?? CGRect(origin: .zero, size: size)
        let backing = CGAffineTransform(translationX: area.minX, y: area.minY)
            .scaledBy(x: area.width / max(1, size.width), y: area.height / max(1, size.height))
        if presenter.surfaces(includingRetiring: true).contains(where: { $0.kind != .document }), let window = view.window {
            layer = window.layer
            if area.width > 0, area.height > 0 { mapping = mapping.scaledBy(x: size.width / area.width, y: size.height / area.height) }
            mapping = mapping.translatedBy(x: -area.minX, y: -area.minY)
        } else {
            layer = presenter.documentHost.layer
            mapping = mapping.translatedBy(x: view.bounds.minX - view.pageBounds.minX, y: view.bounds.minY - view.pageBounds.minY)
        }
        #else
        let view = presenter.navigation.stackSplit.agentRoot
        if view.layer == nil {
            view.wantsLayer = true
            view.layoutSubtreeIfNeeded()
            view.displayIfNeeded()
        }
        guard let layer = view.layer else { return ["error": "the session's view has no layer"] }
        let area = presenter.navigation.stackSplit.agentCaptureArea
        let size = area.size
        let scale = view.window?.backingScaleFactor ?? max(1, layer.contentsScale)
        let backing = CGAffineTransform(translationX: area.minX, y: area.minY)
        var mapping = CGAffineTransform(translationX: -area.minX, y: -area.minY)
        if presenter.navigation.stackSplit.active || presenter.navigation.stackSplit.hasInspector, !view.isFlipped {
            mapping = mapping.translatedBy(x: 0, y: view.bounds.height).scaledBy(x: 1, y: -1)
        }
        #endif
        if req["strict"] as? Bool == true, points.contains(where: {
            $0.x < 0 || $0.y < 0 || $0.x >= size.width || $0.y >= size.height
        }) { return ["error": "the sample lies outside the viewport"] }
        guard size.width > 0, size.height > 0 else { return ["error": "the viewport has no pixels"] }
        let bounds = CGRect(origin: .zero, size: size).applying(backing)
        guard bounds.width > 0, bounds.height > 0 else { return ["error": "the viewport has no backing pixels"] }
        let pixels = points.map {
            let p = $0.applying(backing)
            return CGPoint(x: min(ceil(bounds.maxX * scale) - 1, max(floor(bounds.minX * scale), floor(p.x * scale))),
                           y: min(ceil(bounds.maxY * scale) - 1, max(floor(bounds.minY * scale), floor(p.y * scale))))
        }
        let box = pixels.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: CGSize(width: 1, height: 1))) }
        let (w, h) = (Int(box.width), Int(box.height))
        guard let extended = CGColorSpace(name: CGColorSpace.extendedSRGB), let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 32, bytesPerRow: w * 16, space: extended,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue),
              let data = ctx.data else { return ["error": "no extended-range context for the view"] }
        ctx.translateBy(x: -box.minX, y: box.maxY)
        ctx.scaleBy(x: scale, y: -scale)
        ctx.concatenate(backing)
        ctx.concatenate(mapping)
        let baseCTM = ctx.ctm
        let pixelRects = pixels.map { CGRect(x: $0.x - box.minX, y: box.maxY - $0.y - 1, width: 1, height: 1) }
        CATransaction.flush()
        let offsets = pixels.map { (Int($0.y - box.minY) * w + Int($0.x - box.minX)) * 4 }
        func read() -> [[Float]] {
            memset(data, 0, ctx.bytesPerRow * h)
            layer.render(in: ctx)
            let px = data.assumingMemoryBound(to: Float.self)
            return offsets.map { i in (0..<4).map { px[i + $0] } }
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        var restore: [() -> Void] = []
        defer { for undo in restore.reversed() { undo() }; CATransaction.commit() }
        // Temporarily zero opacity within the disabled-actions transaction and restore on exit,
        // keeping `isHidden` untouched.
        @discardableResult
        func suppress(_ target: CALayer) -> Float? {
            let saved = target.opacity
            guard saved > 0 else { return nil }
            target.opacity = 0
            restore.append { if target.opacity == 0 { target.opacity = saved } }
            return saved
        }
        // render(in:) visits siblings in array order. The compositor also uses zPosition.
        // Sort before collecting so grouped glass members keep paint order.
        func order(_ parent: CALayer) {
            guard !parent.isHidden, parent.opacity > 0 else { return }
            if let mask = parent.mask { order(mask) }
            guard let children = parent.sublayers else { return }
            if zip(children, children.dropFirst()).contains(where: { $0.zPosition > $1.zPosition }) {
                parent.sublayers = children.enumerated().sorted {
                    ($0.element.zPosition, $0.offset) < ($1.element.zPosition, $1.offset)
                }.map(\.element)
                restore.append { parent.sublayers = children }
            }
            children.forEach(order)
        }
        order(layer)
        let collected = samplePictures(in: layer, guests: guests, stable: stableGuests)
        // Suppress unavailable platform-effect subtrees (AppKit's glass effect/portal layers)
        // so CPU render(in:) cannot paint white placeholders or destIn wipes over content.
        for picture in collected.pictures {
            for child in picture.hiddenSublayers { suppress(child) }
        }
        var unknown: [SampleProbe] = []
        for picture in collected.pictures {
            guard let refusal = picture.refusal, !picture.area.isEmpty else { continue }
            let source = picture.layer
            if picture.replacesSubviews {
                let background = source.backgroundColor, contents = source.contents, border = source.borderWidth
                source.backgroundColor = nil; source.contents = nil; source.borderWidth = 0
                restore.append { source.backgroundColor = background; source.contents = contents; source.borderWidth = border }
                for child in source.sublayers ?? [] { suppress(child) }
            }
            let stand = CALayer()
            stand.frame = picture.area
            stand.contents = picture.image
            if picture.cornerRadius > 0 {
                stand.cornerRadius = picture.cornerRadius
                stand.cornerCurve = .continuous
            }
            if picture.image == nil {
                stand.backgroundColor = CGColor(gray: 1, alpha: 1)
                unknown.append(SampleProbe(layer: stand, area: stand.bounds, reason: refusal) { stand.backgroundColor = $0 })
            }
            if picture.clip {
                let clip = CALayer()
                clip.frame = source.bounds
                clip.bounds = source.bounds
                clip.masksToBounds = true
                clip.addSublayer(stand)
                source.insertSublayer(clip, at: 0)
                restore.append { clip.removeFromSuperlayer() }
            } else {
                source.insertSublayer(stand, at: 0)
                restore.append { stand.removeFromSuperlayer() }
            }
        }
        #if os(macOS)
        // Elevate direct members and conservative merge bridges of each NSGlassEffectContainerView
        // above ordinary group siblings (LLP 1053.000.000 D5), keeping all grouped glass backdrops
        // and bridges beneath all grouped member content, and below layers outside the group.
        for group in collected.glassContainers {
            let containerLayer = group.layer
            for child in group.hiddenSublayers { suppress(child) }
            guard !group.topLevelMembers.isEmpty else { continue }
            let overlay = CALayer()
            overlay.bounds = containerLayer.bounds
            overlay.anchorPoint = .zero
            overlay.position = containerLayer.bounds.origin
            overlay.isGeometryFlipped = false
            // Attach overlay first so `convert(..., to: overlay)` cancels containerLayer.sublayerTransform.
            containerLayer.addSublayer(overlay)
            restore.append { overlay.removeFromSuperlayer() }
            if group.bridgeMembers.count >= 2 {
                let entries = group.bridgeMembers.compactMap { entry -> (rect: CGRect, radius: CGFloat)? in
                    let bounds = entry.layer.bounds
                    guard !bounds.isEmpty else { return nil }
                    let r = entry.layer.convert(bounds, to: overlay)
                    guard !r.isNull, !r.isInfinite, !r.isEmpty,
                          r.minX.isFinite, r.minY.isFinite, r.width.isFinite, r.height.isFinite else { return nil }
                    let scale = max(r.width / bounds.width, r.height / bounds.height)
                    let radius = min(max(0, entry.cornerRadius) * scale, min(r.width, r.height) / 2)
                    return (r, radius)
                }
                let s = group.spacing
                let path = CGMutablePath()
                for i in 0..<entries.count {
                    let a = entries[i]
                    for j in (i + 1)..<entries.count {
                        let b = entries[j]
                        if a.rect.contains(b.rect) || b.rect.contains(a.rect) {
                            let (outer, inner) = a.rect.contains(b.rect) ? (a, b) : (b, a)
                            let reach = max(s, inner.radius)
                            guard reach > 0 else { continue }
                            let bridge = inner.rect.insetBy(dx: -reach, dy: -reach).intersection(outer.rect)
                            if !bridge.isNull, !bridge.isEmpty { path.addRect(bridge) }
                            continue
                        }
                        guard a.rect.minX - s <= b.rect.maxX, b.rect.minX - s <= a.rect.maxX,
                              a.rect.minY - s <= b.rect.maxY, b.rect.minY - s <= a.rect.maxY else { continue }
                        let reach = max(s, max(a.radius, b.radius))
                        guard reach > 0 else { continue }
                        let bridge = a.rect.insetBy(dx: -reach, dy: -reach)
                            .intersection(b.rect.insetBy(dx: -reach, dy: -reach))
                            .intersection(a.rect.union(b.rect))
                        if !bridge.isNull, !bridge.isEmpty { path.addRect(bridge) }
                    }
                }
                if !path.isEmpty {
                    let bridges = CAShapeLayer()
                    bridges.bounds = overlay.bounds
                    bridges.anchorPoint = .zero
                    bridges.position = overlay.bounds.origin
                    bridges.isGeometryFlipped = false
                    bridges.fillRule = .nonZero
                    bridges.path = path
                    bridges.fillColor = CGColor(gray: 1, alpha: 1)
                    overlay.addSublayer(bridges)
                    unknown.append(SampleProbe(layer: bridges, area: path.boundingBox, reason: group.refusal) { bridges.fillColor = $0 })
                }
            }
            var replayed: [(member: GlassMemberSample, opacity: Float)] = []
            var savedOpacities: [ObjectIdentifier: Float] = [:]
            for member in group.topLevelMembers {
                guard let savedOpacity = suppress(member.layer) else { continue }
                replayed.append((member, savedOpacity))
                savedOpacities[ObjectIdentifier(member.layer)] = savedOpacity
            }
            // Shared glass backdrop pass (both direct and non-isolated nested members).
            for member in group.backdropMembers {
                guard let refusal = member.refusal, !member.layer.bounds.isEmpty else { continue }
                let stand = CALayer()
                stand.frame = member.layer.bounds
                stand.backgroundColor = CGColor(gray: 1, alpha: 1)
                if member.cornerRadius > 0 {
                    stand.cornerRadius = member.cornerRadius
                    stand.cornerCurve = .continuous
                }
                let leaf: CALayer
                let probeLayer: CALayer
                let probeArea: CGRect
                if member.layer.mask == nil {
                    let clip = CALayer()
                    clip.cornerRadius = member.layer.cornerRadius
                    clip.cornerCurve = member.layer.cornerCurve
                    clip.masksToBounds = member.layer.masksToBounds
                    copyLayerShadow(from: member.layer, to: clip)
                    clip.addSublayer(stand)
                    leaf = clip
                    probeLayer = stand
                    probeArea = stand.bounds
                } else {
                    let opacity = savedOpacities[ObjectIdentifier(member.layer)] ?? member.layer.opacity
                    leaf = GlassMaskedBackdropReplayLayer(
                        target: member.layer, contentBranch: member.contentBranch,
                        stand: stand, replayOpacity: opacity
                    )
                    probeLayer = member.layer
                    probeArea = member.layer.bounds
                }
                if let mirror = makeGeometryMirror(from: containerLayer, to: member.layer, leaf: leaf) {
                    overlay.addSublayer(mirror)
                    unknown.append(SampleProbe(layer: probeLayer, area: probeArea, reason: refusal) {
                        stand.backgroundColor = $0
                    })
                }
            }
            // Shared content pass above all grouped glass backdrops and bridges.
            for item in replayed {
                let member = item.member
                let leaf: CALayer
                if member.layer.mask == nil {
                    guard let branch = member.contentBranch else { continue }
                    let clip = CALayer()
                    clip.cornerRadius = member.layer.cornerRadius
                    clip.cornerCurve = member.layer.cornerCurve
                    clip.masksToBounds = member.layer.masksToBounds
                    copyLayerShadow(from: member.layer, to: clip)
                    clip.addSublayer(GlassBranchReplayLayer(branch: branch))
                    leaf = clip
                } else {
                    leaf = GlassMaskedContentReplayLayer(target: member.layer, replayOpacity: item.opacity)
                }
                if let mirror = makeGeometryMirror(from: containerLayer, to: member.layer, leaf: leaf) {
                    overlay.addSublayer(mirror)
                }
            }
        }
        #endif
        let values = read()
        func affectsSampledPixels(_ probe: SampleProbe) -> Bool {
            // A probe rendered as a sublayer of `probe.layer` (such as a masked grouped member's stand)
            // inherits `probe.layer.sublayerTransform`, which `probe.layer.convert(bounds, to:)` omits.
            if !CATransform3DIsIdentity(probe.layer.sublayerTransform) { return true }
            var reachedRoot = probe.layer === layer
            var current: CALayer? = probe.layer
            while let node = current {
                // Non-affine 3D transforms can diverge between convert(_:to:) and render(in:);
                // shadows and filters can also paint outside the probe's own bounds.
                if !CATransform3DIsAffine(node.transform) || !CATransform3DIsAffine(node.sublayerTransform)
                    || node.shadowOpacity > 0 || !(node.filters?.isEmpty ?? true) { return true }
                if node === layer { reachedRoot = true; break }
                current = node.superlayer
            }
            guard reachedRoot else { return true }
            let inRoot = probe.layer.convert(probe.area, to: layer)
            guard !inRoot.isNull, !inRoot.isInfinite,
                  inRoot.minX.isFinite, inRoot.minY.isFinite, inRoot.width.isFinite, inRoot.height.isFinite else { return true }
            let inBitmap = inRoot.applying(baseCTM)
            guard !inBitmap.isNull, !inBitmap.isInfinite,
                  inBitmap.minX.isFinite, inBitmap.minY.isFinite, inBitmap.width.isFinite, inBitmap.height.isFinite else { return true }
            let expanded = inBitmap.insetBy(dx: -2, dy: -2)
            return pixelRects.contains { expanded.intersects($0) }
        }
        // A missing picture only matters where it contributes. The same compositor
        // resolves masks, rounded clips and occlusion for both the probe and the pixel.
        let active = unknown.filter(affectsSampledPixels)
        for probe in active {
            for alpha in [CGFloat(0), 1] {
                probe.setColor(CGColor(gray: 0, alpha: alpha))
                if read() != values { return ["error": probe.reason] }
            }
            probe.setColor(CGColor(gray: 1, alpha: 1))
        }
        // Also vary all active probes together so overlapping unavailable layers inside an alpha mask
        // cannot shield one another while varied individually.
        if active.count > 1 {
            for alpha in [CGFloat(0), 1] {
                for probe in active { probe.setColor(CGColor(gray: 0, alpha: alpha)) }
                if read() != values { return ["error": active[0].reason] }
            }
            for probe in active { probe.setColor(CGColor(gray: 1, alpha: 1)) }
        }
        // Apple blends SDR layers in encoded sRGB. Convert after blending so half
        // black over red has the displayed intensity while P3 and HDR remain extended.
        var result: [[Double]] = []
        for px in values {
            let a = CGFloat(px[3])
            let rgba = px.prefix(3).map { a > 0 ? CGFloat($0) / a : 0 } + [a]
            let converted = CGColor(colorSpace: extended, components: rgba)?.converted(to: linear, intent: .defaultIntent, options: nil)
            guard let components = converted?.components else { return ["error": "could not convert the sample to linear sRGB"] }
            result.append(components.map { Agent.r4(Double($0)) })
        }
        return ["space": "extended-linear-srgb", "values": result]
    }

    #if os(macOS)
    private typealias CollectedSamples = (pictures: [SamplePicture], glassContainers: [GlassContainerSample])
    #else
    private typealias CollectedSamples = (pictures: [SamplePicture], Void)
    #endif

    private func samplePictures(in root: CALayer, guests: [UInt32: ExactWebImage], stable: Bool) -> CollectedSamples {
        var owners: [ObjectIdentifier: NodeView] = [:]
        var guestLayers: [ObjectIdentifier: NodeView] = [:]
        func guest(_ view: PaintView, _ node: NodeView) {
            if let layer = view.layer as CALayer? { guestLayers[ObjectIdentifier(layer)] = node }
        }
        for node in presenter.views.values {
            if let layer = node.layer as CALayer? { owners[ObjectIdentifier(layer)] = node }
            if let view = node.web { guest(view, node) }
        }
        for (id, view) in session.natives.snapshotViews {
            if let node = presenter.views[id] { guest(view, node) }
        }
        var pictures: [SamplePicture] = []
        #if os(macOS)
        var glassContainers: [GlassContainerSample] = []
        #endif
        func walk(_ layer: CALayer, owner: NodeView?, activeContainer: Int?, insideGlass: Bool) {
            guard !layer.isHidden, layer.opacity > 0 else { return }
            let key = ObjectIdentifier(layer)
            let node = owners[key] ?? owner
            var image: CGImage?, reason: String?, area = layer.bounds, replaces = false, clip = false
            if let guest = guestLayers[key] {
                #if os(macOS)
                image = guests[guest.id]?.cgImage(forProposedRect: nil, context: nil, hints: nil)
                #else
                image = guests[guest.id]?.cgImage
                #endif
                reason = stable ? "the hosted view returned no snapshot" : "the page changed during the hosted snapshot"
                replaces = true
            } else if let metal = layer as? CAMetalLayer {
                #if os(macOS)
                let canvas = node?.metal?.layer
                #else
                let canvas = node?.metal?.metalLayer
                #endif
                if canvas === metal, let node { image = node.canvases?.sampledFrame(of: node) }
                reason = "the Metal layer has no readable presented frame"
            } else if let player = layer as? AVPlayerLayer, player.isReadyForDisplay {
                if #available(iOS 27, macOS 27, tvOS 27, *) {
                    image = player.displayedReadOnlyPixelBuffer()?.withUnsafeBuffer { Self.videoPicture($0) }
                } else { image = Self.videoPicture(player.displayedPixelBuffer()) }
                clip = true
                area = player.videoRect
                reason = "AVPlayerLayer did not provide the displayed frame (playing, protected or unavailable)"
            } else if let display = layer as? AVSampleBufferDisplayLayer {
                clip = true
                if #available(iOS 17.4, tvOS 17.4, macOS 14.4, *), display.isReadyForDisplay {
                    reason = "the sample-buffer renderer did not provide the displayed frame"
                    image = Self.videoPicture(display.sampleBufferRenderer.displayedPixelBuffer())
                    if let image, display.videoGravity != .resize {
                        let w = CGFloat(image.width), h = CGFloat(image.height)
                        let ratio = display.videoGravity == .resizeAspectFill ? max(area.width / w, area.height / h) : min(area.width / w, area.height / h)
                        area = CGRect(x: area.midX - w * ratio / 2, y: area.midY - h * ratio / 2, width: w * ratio, height: h * ratio)
                    }
                } else if #unavailable(iOS 17.4, tvOS 17.4, macOS 14.4) {
                    reason = "this OS does not expose the displayed sample buffer"
                }
            } else if let preview = layer as? AVCaptureVideoPreviewLayer {
                if #available(tvOS 17, *) {
                    let rect = preview.layerRectConverted(fromMetadataOutputRect: CGRect(x: 0, y: 0, width: 1, height: 1))
                    if !rect.isEmpty { area = area.intersection(rect) }
                }
                reason = "the live camera preview does not expose its displayed frame"
            }
            #if os(macOS)
            if !replaces, reason == nil {
                // Native glass (LLP 1100 D12): AppKit puts its portal/effect subtree after `contentView`.
                // In CPU render(in:), untinted glass paints opaque white over content and tinted glass applies
                // a destIn compositing filter that clears earlier pixels. Hide the effect subtree, keep the
                // public content branch, and probe the glass bounds below it so opaque content samples cleanly
                // while bare or translucent glass pixels refuse.
                if #available(macOS 26.0, *), let glass = layer.delegate as? NSGlassEffectView {
                    let branch = Capture.glassContentBranch(of: layer, content: glass.contentView?.layer)
                    let hidden = (layer.sublayers ?? []).filter { !$0.isHidden && $0.opacity > 0 && $0 !== branch }
                    let ownerName = node.map { $0.props["testId"] ?? "\($0.kind) #\($0.id)" } ?? "the session"
                    let radius = max(0, glass.cornerRadius)
                    let refusal = layer.bounds.isEmpty ? nil : "sample \(ownerName): the window server composites native glass"
                    if let idx = activeContainer {
                        if !hidden.isEmpty {
                            pictures.append(SamplePicture(
                                layer: layer, area: .zero, image: nil, refusal: nil,
                                replacesSubviews: false, clip: false, hiddenSublayers: hidden, cornerRadius: 0
                            ))
                        }
                        let member = GlassMemberSample(
                            layer: layer, contentBranch: branch, cornerRadius: radius, refusal: refusal
                        )
                        if !insideGlass { glassContainers[idx].topLevelMembers.append(member) }
                        glassContainers[idx].backdropMembers.append(member)
                        glassContainers[idx].bridgeMembers.append((layer, radius))
                    } else {
                        pictures.append(SamplePicture(
                            layer: layer, area: layer.bounds, image: nil, refusal: refusal,
                            replacesSubviews: false, clip: false, hiddenSublayers: hidden, cornerRadius: radius
                        ))
                    }
                    if let mask = layer.mask { walk(mask, owner: node, activeContainer: nil, insideGlass: false) }
                    if let branch { walk(branch, owner: node, activeContainer: activeContainer, insideGlass: true) }
                    return
                }
                if #available(macOS 26.0, *), let container = layer.delegate as? NSGlassEffectContainerView {
                    let branch = Capture.glassContentBranch(of: layer, content: container.contentView?.layer)
                    let hidden = (layer.sublayers ?? []).filter { !$0.isHidden && $0.opacity > 0 && $0 !== branch }
                    let ownerName = node.map { $0.props["testId"] ?? "\($0.kind) #\($0.id)" } ?? "the session"
                    let spacing = container.spacing.isFinite ? max(0, container.spacing) : 0
                    let idx = glassContainers.count
                    glassContainers.append(GlassContainerSample(
                        layer: layer, spacing: spacing,
                        refusal: "sample \(ownerName): the window server composites native glass",
                        hiddenSublayers: hidden, topLevelMembers: [], backdropMembers: [], bridgeMembers: []
                    ))
                    if let mask = layer.mask { walk(mask, owner: node, activeContainer: nil, insideGlass: false) }
                    if let branch { walk(branch, owner: node, activeContainer: idx, insideGlass: false) }
                    return
                }
                if layer is CAOpenGLLayer { reason = "the OpenGL layer does not expose its displayed frame" }
            }
            #else
            if !replaces, reason == nil, layer is CAEAGLLayer { reason = "the OpenGL layer does not expose its displayed frame" }
            #endif
            if let reason, !area.isEmpty {
                let owner = node.map { $0.props["testId"] ?? "\($0.kind) #\($0.id)" } ?? "the session"
                pictures.append(SamplePicture(
                    layer: layer, area: area, image: image, refusal: "sample \(owner): \(reason)",
                    replacesSubviews: replaces, clip: clip, hiddenSublayers: [], cornerRadius: 0
                ))
            }
            if let mask = layer.mask { walk(mask, owner: node, activeContainer: nil, insideGlass: false) }
            if !replaces { for child in layer.sublayers ?? [] { walk(child, owner: node, activeContainer: activeContainer, insideGlass: insideGlass) } }
        }
        walk(root, owner: nil, activeContainer: nil, insideGlass: false)
        #if os(macOS)
        return (pictures, glassContainers)
        #else
        return (pictures, ())
        #endif
    }

    private static let videoContext = CIContext()

    private static func videoPicture(_ buffer: CVPixelBuffer?) -> CGImage? {
        guard let buffer else { return nil }
        let image = CIImage(cvPixelBuffer: buffer, options: [.applyOrientationProperty: true])
        return videoContext.createCGImage(image, from: image.extent, format: .RGBAh, colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
    }

    static func r4(_ v: Double) -> Double { (v * 10_000).rounded() / 10_000 }
}
