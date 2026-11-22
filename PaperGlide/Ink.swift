import UIKit
import PDFKit
import UIKit.UIGestureRecognizerSubclass

enum InkNib: String, CaseIterable {
    case fine = "Fine"
    case medium = "Medium"
    case thick = "Thick"

    var width: CGFloat {
        switch self {
        case .fine: return 0.8
        case .medium: return 1.4
        case .thick: return 2.4
        }
    }
}

// Smooth in PDF coordinates. PDF ink lists contain vertices, so subdivide
// each quadratic until its centerline is within 0.01 PDF point of the curve.
struct InkCenterline {
    private(set) var vertices: [CGPoint] = []
    private(set) var lastSample: CGPoint?

    mutating func append(_ point: CGPoint) {
        guard let previous = lastSample, let start = vertices.last else {
            vertices.append(point)
            lastSample = point
            return
        }
        guard previous != point else { return }
        let end = CGPoint(x: (previous.x + point.x) / 2, y: (previous.y + point.y) / 2)
        Self.flatten(start, previous, end, into: &vertices)
        lastSample = point
    }

    private static func flatten(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, into output: inout [CGPoint]) {
        let ab = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let bc = CGPoint(x: (b.x + c.x) / 2, y: (b.y + c.y) / 2)
        let mid = CGPoint(x: (ab.x + bc.x) / 2, y: (ab.y + bc.y) / 2)
        // The maximum parametric deviation from the chord is at t = 0.5.
        if hypot(mid.x - (a.x + c.x) / 2, mid.y - (a.y + c.y) / 2) <= 0.01 {
            output.append(c)
        } else {
            flatten(a, ab, mid, into: &output)
            flatten(mid, bc, c, into: &output)
        }
    }

    mutating func finish() {
        if let lastSample, vertices.last != lastSample { vertices.append(lastSample) }
    }
}

struct InkStroke {
    let page: Int
    let points: [CGPoint]
    let width: CGFloat
    static let color = UIColor(red: 0.77, green: 0.15, blue: 0.12, alpha: 1)

    func annotation() -> PDFAnnotation {
        let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
            .insetBy(dx: -width, dy: -width)
        let path = UIBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        for (index, point) in points.enumerated() {
            let local = CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)
            if index == 0 { path.move(to: local) } else { path.addLine(to: local) }
        }
        if points.count == 1 { path.addLine(to: CGPoint(x: path.currentPoint.x + 0.01, y: path.currentPoint.y)) }
        let ink = PDFAnnotation(bounds: bounds, forType: .ink, withProperties: nil)
        ink.userName = "PaperGlide"
        ink.color = Self.color
        let border = PDFBorder()
        border.lineWidth = width
        ink.border = border
        ink.shouldPrint = true
        ink.add(path)
        return ink
    }
}

final class InkGesture: UIGestureRecognizer {
    weak var surface: PDFView?
    var onStroke: ((InkStroke) -> Void)?
    var isEraser = false
    var onErase: ((PDFPage, CGPoint, CGPoint, CGFloat) -> Void)?
    var onEraseFinished: ((Bool) -> Void)?
    private var erasing = false
    private var previousErasePoint: CGPoint?
    var nib: InkNib = .fine
    private var strokeWidth: CGFloat = InkNib.fine.width
    private var tracking: UITouch?
    private var page: PDFPage?
    private var curve = InkCenterline()
    private let preview = CAShapeLayer()
    private let tip = CAShapeLayer()
    private let trace = UIBezierPath()

    init(surface: PDFView) {
        self.surface = surface
        super.init(target: nil, action: nil)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        for layer in [preview, tip] {
            layer.strokeColor = InkStroke.color.cgColor
            layer.fillColor = nil
            layer.lineCap = .round
            layer.lineJoin = .round
            layer.zPosition = 100
            layer.actions = ["path": NSNull(), "bounds": NSNull(), "position": NSNull()]
        }
        surface.addGestureRecognizer(self)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracking == nil, touches.count == 1, let touch = touches.first, let surface,
              let page = surface.page(for: touch.preciseLocation(in: surface), nearest: false) else {
            state = tracking == nil ? .failed : .cancelled
            return
        }
        tracking = touch
        self.page = page
        erasing = isEraser
        if erasing {
            appendSamples(touch, event: event)
            state = .began
            return
        }
        strokeWidth = nib.width
        for layer in [preview, tip] {
            layer.frame = surface.bounds
            layer.contentsScale = max(surface.contentScaleFactor, surface.traitCollection.displayScale)
            layer.lineWidth = strokeWidth * surface.scaleFactor
            surface.layer.addSublayer(layer)
        }
        appendSamples(touch, event: event)
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracking, touches.contains(touch) else { return }
        appendSamples(touch, event: event)
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = tracking, touches.contains(touch), let page, let doc = surface?.document else { return }
        appendSamples(touch, event: event)
        if erasing {
            erasing = false
            onEraseFinished?(true)
            state = .ended
            return
        }
        curve.finish()
        if !curve.vertices.isEmpty { onStroke?(InkStroke(page: doc.index(for: page), points: curve.vertices, width: strokeWidth)) }
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() {
        super.reset()
        if erasing { onEraseFinished?(false) }
        erasing = false
        previousErasePoint = nil
        tracking = nil
        page = nil
        curve = InkCenterline()
        trace.removeAllPoints()
        for layer in [preview, tip] {
            layer.path = nil
            layer.removeFromSuperlayer()
        }
    }
    private func appendSamples(_ touch: UITouch, event: UIEvent) {
        guard let surface else { return }
        if erasing {
            let samples = event.coalescedTouches(for: touch) ?? []
            for sample in samples + [touch] {
                let location = sample.preciseLocation(in: surface)
                guard let target = surface.page(for: location, nearest: false) else {
                    previousErasePoint = nil
                    continue
                }
                let point = surface.convert(location, to: target)
                let start = target === page ? previousErasePoint ?? point : point
                onErase?(target, start, point, 9 / max(0.01, surface.scaleFactor))
                previousErasePoint = point
                page = target
            }
            return
        }
        guard let page else { return }
        let bounds = page.bounds(for: surface.displayBox)
        let first = curve.vertices.count
        let samples = event.coalescedTouches(for: touch) ?? []
        func append(_ sample: UITouch) {
            let raw = surface.convert(sample.preciseLocation(in: surface), to: page)
            guard raw.x.isFinite && raw.y.isFinite else { return }
            curve.append(CGPoint(x: min(bounds.maxX, max(bounds.minX, raw.x)), y: min(bounds.maxY, max(bounds.minY, raw.y))))
        }
        for sample in samples { append(sample) }
        append(touch)
        for index in first..<curve.vertices.count {
            let location = surface.convert(curve.vertices[index], from: page)
            if index == 0 { trace.move(to: location) } else { trace.addLine(to: location) }
        }
        preview.path = trace.cgPath
        // Show the tip up to the latest measured sample while the next curve is forming.
        if let last = curve.lastSample {
            let end = surface.convert(last, from: page)
            let tail = UIBezierPath()
            tail.move(to: trace.currentPoint)
            tail.addLine(to: trace.currentPoint == end ? CGPoint(x: end.x + 0.01, y: end.y) : end)
            tip.path = tail.cgPath
        }
    }
}

enum InkFile {
    static func generate(from source: URL, strokes: [InkStroke], removing: [Int: Set<Int>] = [:], to output: URL) throws {
        guard let doc = PDFDocument(url: source), doc.allowsCommenting else { throw CocoaError(.fileWriteNoPermission) }
        for (pageIndex, indices) in removing {
            guard let page = doc.page(at: pageIndex) else { throw CocoaError(.fileReadCorruptFile) }
            let originals = page.annotations
            for index in indices {
                guard originals.indices.contains(index), InkDisplay.isPaperGlideInk(originals[index]) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                page.removeAnnotation(originals[index])
            }
        }
        for stroke in strokes {
            guard let page = doc.page(at: stroke.page) else { throw CocoaError(.fileReadCorruptFile) }
            page.addAnnotation(stroke.annotation())
        }
        guard doc.write(to: output), let check = PDFDocument(url: output), check.pageCount == doc.pageCount else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

    // The view keeps its original snapshot so undo and erasing original annotation
    // slots stay valid. Each commit compares against the most recent saved bytes.
    static func autosave(from snapshot: URL, expected: URL, source: URL, recovery: URL?,
                         strokes: [InkStroke], removing: [Int: Set<Int>]) throws -> (draft: URL, recovery: URL?) {
        let fm = FileManager.default
        let draft = snapshot.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".pdf")
        do {
            if strokes.isEmpty && removing.isEmpty { try fm.copyItem(at: snapshot, to: draft) }
            else { try generate(from: snapshot, strokes: strokes, removing: removing, to: draft) }
            do {
                try commit(draft, replacing: recovery ?? source, basedOn: expected)
                return (draft, recovery)
            } catch {
                let docs = try fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let dir = docs.appendingPathComponent("Recovered Markups", isDirectory: true)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let name = String(source.deletingPathExtension().lastPathComponent.prefix(60))
                let copy = dir.appendingPathComponent(name + " (marked " + UUID().uuidString.prefix(8) + ").pdf")
                try fm.copyItem(at: draft, to: copy)
                return (draft, copy)
            }
        } catch {
            try? fm.removeItem(at: draft)
            throw error
        }
    }

    static func commit(_ draft: URL, replacing source: URL, basedOn snapshot: URL) throws {
        let fm = FileManager.default
        var coordinatorError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: source, options: .forReplacing, error: &coordinatorError) { live in
            do {
                guard fm.contentsEqual(atPath: live.path, andPath: snapshot.path) else {
                    throw NSError(domain: "PaperGlide", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "The shared PDF changed after you opened it. Save your marked version as a separate copy."])
                }
                let directory = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: live, create: true)
                defer { try? fm.removeItem(at: directory) }
                let replacement = directory.appendingPathComponent(live.lastPathComponent)
                try fm.copyItem(at: draft, to: replacement)
                _ = try fm.replaceItemAt(live, withItemAt: replacement)
            } catch { writeError = error }
        }
        if let error = coordinatorError ?? writeError as NSError? { throw error }
    }
}

// PDFKit can enlarge its annotation bitmap when a page is zoomed. Render
// PaperGlide ink in viewport pixels, using the original PDF-space paths.
final class InkDisplay: UIView {
    private weak var pdf: PDFView?
    private let scanned = NSHashTable<PDFPage>.weakObjects()
    // PDFKit materializes UIKit paths on access. Keep their immutable geometry
    // for the lifetime of this viewing document instead of decoding it per frame.
    final class DisplayMark {
        enum Origin {
            case saved(Int)
            case drawn(InkStroke)
        }
        let annotation: PDFAnnotation
        let paths: [CGPath]
        let origin: Origin
        let pageIndex: Int

        init(_ annotation: PDFAnnotation, origin: Origin, pageIndex: Int) {
            self.annotation = annotation
            self.paths = (annotation.paths ?? []).map { $0.cgPath }
            self.origin = origin
            self.pageIndex = pageIndex
        }

        func intersects(_ sweep: CGPath) -> Bool {
            guard annotation.bounds.intersects(sweep.boundingBoxOfPath) else { return false }
            var shift = CGAffineTransform(translationX: -annotation.bounds.minX, y: -annotation.bounds.minY)
            guard let local = sweep.copy(using: &shift) else { return false }
            let width = max(0.1, annotation.border?.lineWidth ?? 2)
            return paths.contains { path in
                path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1).intersects(local)
            }
        }
    }
    private var annotations: [PDFPage: [DisplayMark]] = [:]
    private var updatePending = false
    private var observations: [NSKeyValueObservation] = []

    init(pdf: PDFView) {
        self.pdf = pdf
        super.init(frame: .zero)
        backgroundColor = .clear
        isOpaque = false
        isUserInteractionEnabled = false
        contentMode = .redraw
        isHidden = true
        for name in [Notification.Name.PDFViewScaleChanged, .PDFViewVisiblePagesChanged, .PDFViewPageChanged] {
            NotificationCenter.default.addObserver(self, selector: #selector(redraw), name: name, object: pdf)
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    func reset() {
        observations.removeAll()
        scanned.removeAllObjects()
        annotations.removeAll()
        isHidden = true
    }
    func track(_ scroll: UIScrollView?) {
        guard let scroll else { return }
        observations = [
            scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in self?.redraw() },
            scroll.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in self?.redraw() }
        ]
        redraw()
    }
    @objc func redraw() {
        guard !updatePending else { return }
        updatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.updatePending = false
            self.updateVisibleInk()
        }
    }

    func add(_ mark: DisplayMark, on page: PDFPage) {
        scan(page)
        annotations[page, default: []].append(mark)
        redraw()
    }
    func remove(_ mark: DisplayMark, from page: PDFPage) {
        annotations[page]?.removeAll { $0 === mark }
        redraw()
    }

    func erase(on page: PDFPage, from start: CGPoint, to end: CGPoint, radius: CGFloat) -> [DisplayMark] {
        scan(page)
        guard let marks = annotations[page], !marks.isEmpty else { return [] }
        let sweep: CGPath
        if start == end {
            sweep = CGPath(ellipseIn: CGRect(x: end.x - radius, y: end.y - radius, width: 2 * radius, height: 2 * radius), transform: nil)
        } else {
            let segment = CGMutablePath()
            segment.move(to: start)
            segment.addLine(to: end)
            sweep = segment.copy(strokingWithWidth: 2 * radius, lineCap: .round, lineJoin: .round, miterLimit: 1)
        }
        var hits = [DisplayMark]()
        annotations[page]?.removeAll { mark in
            guard mark.intersects(sweep) else { return false }
            hits.append(mark)
            return true
        }
        if !hits.isEmpty { redraw() }
        return hits
    }

    nonisolated static func isPaperGlideInk(_ annotation: PDFAnnotation) -> Bool {
        guard annotation.type == "Ink" || annotation.type == PDFAnnotationSubtype.ink.rawValue, annotation.shouldDisplay,
              annotation.paths?.isEmpty == false else { return false }
        if annotation.userName == "PaperGlide" { return true }
        // The original release wrote single-path red ink without a name.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard annotation.paths?.count == 1, (annotation.userName == nil || annotation.userName == "Mobile User"),
              annotation.color.getRed(&r, green: &g, blue: &b, alpha: &a),
              let width = annotation.border?.lineWidth,
              [0.8, 1.4, 2.0, 2.4].contains(where: { abs($0 - width) < 0.005 }) else { return false }
        return abs(r - 0.77) < 0.004 && abs(g - 0.15) < 0.004 && abs(b - 0.12) < 0.004 && a == 1
    }
    private func scan(_ page: PDFPage) {
        guard !scanned.contains(page), let document = pdf?.document else { return }
        scanned.add(page)
        let pageIndex = document.index(for: page)
        // Preserve the original annotation slot in the immutable snapshot used for saving.
        for (index, annotation) in page.annotations.enumerated() where Self.isPaperGlideInk(annotation) {
            annotations[page, default: []].append(DisplayMark(annotation, origin: .saved(index), pageIndex: pageIndex))
            page.removeAnnotation(annotation)
        }
    }

    private func updateVisibleInk() {
        let pages = pdf?.visiblePages ?? []
        for page in pages { scan(page) }
        isHidden = !pages.contains { annotations[$0]?.isEmpty == false }
        if !isHidden { setNeedsDisplay() }
    }
    override func draw(_ rect: CGRect) {
        guard let pdf, let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setShouldAntialias(true)
        for page in pdf.visiblePages {
            guard let marks = annotations[page], !marks.isEmpty else { continue }
            let origin = pdf.convert(.zero as CGPoint, from: page)
            let x = pdf.convert(CGPoint(x: 1, y: 0), from: page)
            let y = pdf.convert(CGPoint(x: 0, y: 1), from: page)
            ctx.saveGState()
            ctx.concatenate(CGAffineTransform(a: x.x - origin.x, b: x.y - origin.y,
                                              c: y.x - origin.x, d: y.y - origin.y,
                                              tx: origin.x, ty: origin.y))
            ctx.clip(to: page.bounds(for: pdf.displayBox))
            let visible = ctx.boundingBoxOfClipPath
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            for mark in marks where visible.intersects(mark.annotation.bounds) {
                let annotation = mark.annotation
                ctx.saveGState()
                ctx.translateBy(x: annotation.bounds.minX, y: annotation.bounds.minY)
                ctx.setStrokeColor(annotation.color.cgColor)
                ctx.setLineWidth(annotation.border?.lineWidth ?? 2)
                for path in mark.paths { ctx.addPath(path) }
                ctx.strokePath()
                ctx.restoreGState()
            }
            ctx.restoreGState()
        }
    }
}
