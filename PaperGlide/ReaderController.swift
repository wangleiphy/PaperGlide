import UIKit
import PDFKit

final class ReaderController: UIViewController, UIGestureRecognizerDelegate {
    let folder: Folder
    let papers: [PaperEntry]
    var didChangeTags: (() -> Void)?
    var didSavePDF: (() -> Void)?
    private var drawing: InkGesture?
    private enum InkEdit {
        case draw(InkDisplay.DisplayMark)
        case erase([InkDisplay.DisplayMark])
    }
    private var edits = [InkEdit]()
    private var activeErasures = [InkDisplay.DisplayMark]()
    private lazy var eraser = UIBarButtonItem(image: UIImage(systemName: "eraser"), style: .plain, target: self, action: #selector(toggleEraser))
    private var saving = false
    private var tagging = Set<String>()
    private var revision = 0
    private var savedRevision = 0
    private var lastWritten: URL?
    private var recoveryURL: URL?
    private var recoveryNoticePending = false
    private var scheduledSave: DispatchWorkItem?
    private var afterSave: (() -> Void)?
    private var fingerDrawing = false
    private var backgroundTask = UIBackgroundTaskIdentifier.invalid
    private var libraryNeedsRefresh = false
    private var originalScrollTouches = 1
    private lazy var undoInkButton = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: self, action: #selector(undoInk))
    private lazy var nibButton = UIBarButtonItem(image: UIImage(systemName: "pencil.tip"), style: .plain, target: self, action: #selector(selectPencil))
    private var index: Int
    private var panes = [Int: PaperPane]()
    private let canvas = UIView()
    private let queue = OperationQueue()
    private var drag: CGFloat = 0
    private var settling = false
    private var popGestureWasEnabled = true
    private var contentPopWasEnabled = true
    private lazy var pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan))
    private lazy var tag = UIBarButtonItem(image: nil, style: .plain, target: self, action: #selector(toggleTag))

    init(folder: Folder, papers: [PaperEntry], index: Int) {
        self.folder = folder
        self.papers = papers
        self.index = index
        super.init(nibName: nil, bundle: nil)
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
    }
    deinit {
        if let lastWritten { try? FileManager.default.removeItem(at: lastWritten) }
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = .systemBackground
        canvas.clipsToBounds = true
        view.addSubview(canvas)
        pan.maximumNumberOfTouches = 1
        pan.delegate = self
        pan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        canvas.addGestureRecognizer(pan)
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(title: "Papers", style: .plain, target: self, action: #selector(returnToLibrary))
        nibButton.accessibilityLabel = "Pencil"
        nibButton.accessibilityHint = "Touch and hold for pen width and finger drawing."
        undoInkButton.accessibilityLabel = "Undo last stroke"
        navigationItem.rightBarButtonItems = [nibButton, eraser, undoInkButton, tag]
        updateWindow()
    }
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if let pop = navigationController?.interactivePopGestureRecognizer {
            popGestureWasEnabled = pop.isEnabled
            pop.isEnabled = false
        }
        if #available(iOS 26.0, *), let pop = navigationController?.interactiveContentPopGestureRecognizer {
            contentPopWasEnabled = pop.isEnabled
            pop.isEnabled = false
        }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        savePosition()
        if libraryNeedsRefresh { didSavePDF?(); libraryNeedsRefresh = false }
        navigationController?.interactivePopGestureRecognizer?.isEnabled = popGestureWasEnabled
        if #available(iOS 26.0, *) { navigationController?.interactiveContentPopGestureRecognizer?.isEnabled = contentPopWasEnabled }
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        canvas.frame = view.safeAreaLayoutGuide.layoutFrame
        layoutPanes()
    }
    func savePosition() {
        if let saved = panes[index]?.position() { folder.save(saved, for: papers[index].name) }
    }
    private func updateWindow() {
        for i in Array(panes.keys) where abs(i - index) > 1 {
            let pane = panes.removeValue(forKey: i)
            pane?.cancel()
            pane?.removeFromSuperview()
        }
        for i in [index, index + 1, index - 1] where papers.indices.contains(i) && panes[i] == nil {
            let pane = PaperPane(frame: canvas.bounds)
            canvas.addSubview(pane)
            panes[i] = pane
            pane.onRetry = { [weak self] in self?.load(i) }
            pane.onReady = { [weak self, weak pane] in
                guard let self, let pane else { return }
                pane.scrollView?.panGestureRecognizer.require(toFail: self.pan)
                if self.index == i { self.updateControls() }
            }
            load(i)
        }
        layoutPanes()
        updateControls()
    }
    private func load(_ i: Int) {
        panes[i]?.load(folder: folder, name: papers[i].name, position: folder.position(papers[i].name), queue: queue, priority: i == index ? .veryHigh : .normal)
    }
    private func layoutPanes() {
        for (i, pane) in panes {
            pane.frame = canvas.bounds.offsetBy(dx: CGFloat(i - index) * canvas.bounds.width + drag, dy: 0)
            pane.accessibilityElementsHidden = i != index
        }
    }
    private func updateControls() {
        title = (papers[index].name as NSString).deletingPathExtension
        if !settling, drawing == nil, let pane = panes[index], pane.retainedPaper?.document.allowsCommenting == true {
            attachInk(to: pane)
        }
        refreshInkButtons()
        let tagged = folder.tags.contains(papers[index].name)
        tag.image = UIImage(systemName: tagged ? "tag.fill" : "tag")
        tag.tintColor = tagged ? .systemRed : .secondaryLabel
        tag.accessibilityLabel = tagged ? "Remove red tag" : "Add red tag"
        tag.isEnabled = !settling && !tagging.contains(papers[index].name)
    }
    @objc private func toggleTag() {
        let name = papers[index].name
        guard tagging.insert(name).inserted else { return }
        let enabled = !folder.tags.contains(name)
        updateControls()
        Folder.metadataQueue.async { [folder, didChangeTags, weak self] in
            let result = Result { try FinderTags.setRed(enabled, at: folder.url.appendingPathComponent(name)) }
            DispatchQueue.main.async {
                if case .success = result {
                    if enabled { folder.tags.insert(name) } else { folder.tags.remove(name) }
                    didChangeTags?()
                }
                guard let self else { return }
                self.tagging.remove(name)
                self.updateControls()
                if case .failure(let error) = result {
                    let alert = UIAlertController(title: "Couldn’t update the Finder tag", message: name + "\n" + error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "OK", style: .default))
                    self.navigationController?.visibleViewController?.present(alert, animated: true)
                } else {
                    UIAccessibility.post(notification: .announcement, argument: enabled ? "Red tag added" : "Red tag removed")
                }
            }
        }
    }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard !settling, afterSave == nil, !(fingerDrawing && drawing != nil), recognizer === pan else { return false }
        let velocity = pan.velocity(in: canvas)
        guard abs(velocity.x) > abs(velocity.y) * 1.4 else { return false }
        let direction = velocity.x < 0 ? 1 : -1
        guard papers.indices.contains(index + direction) else { return false }
        if panes[index]?.zoomed == true {
            let start = pan.location(in: canvas).x - pan.translation(in: canvas).x
            return direction == 1 ? start > canvas.bounds.width - 48 : start < 48
        }
        return true
    }
    @objc private func handlePan() {
        let width = canvas.bounds.width
        guard width > 0 else { return }
        switch pan.state {
        case .began, .changed:
            let translation = pan.translation(in: canvas).x
            let lower = index + 1 < papers.count ? -width : 0
            let upper = index > 0 ? width : 0
            drag = max(lower, min(upper, translation))
            layoutPanes()
        case .ended:
            let projected = drag + pan.velocity(in: canvas).x * 0.14
            settle(abs(projected) > width * 0.20 ? (projected < 0 ? 1 : -1) : 0)
        case .cancelled, .failed: settle(0)
        default: break
        }
    }
    private func settle(_ step: Int) {
        guard !settling else { return }
        let delta = papers.indices.contains(index + step) ? step : 0
        if delta != 0 {
            guard afterSave == nil else { return }
            leaveAfterSaving { [weak self] in self?.animateSwitch(delta) }
        } else { animateSwitch(0) }
    }
    private func animateSwitch(_ delta: Int) {
        if delta != 0 { drawing?.isEnabled = false; savePosition() }
        settling = true
        updateControls()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.drag = -CGFloat(delta) * self.canvas.bounds.width
            self.layoutPanes()
        } completion: { _ in
            if delta != 0 {
                let changed = self.revision > 0
                self.detachInk()
                if changed {
                    // A later visit must start from the bytes now in the source file.
                    self.panes.removeValue(forKey: self.index)?.removeFromSuperview()
                }
            }
            self.index += delta
            self.drag = 0
            self.settling = false
            self.updateWindow()
        }
    }
}

extension ReaderController {
    private func attachInk(to pane: PaperPane) {
        let gesture = InkGesture(surface: pane.pdf)
        gesture.onStroke = { [weak self, weak pane] stroke in
            guard let self, let page = pane?.pdf.document?.page(at: stroke.page) else { return }
            let mark = InkDisplay.DisplayMark(stroke.annotation(), origin: .drawn(stroke), pageIndex: stroke.page)
            pane?.inkDisplay.add(mark, on: page)
            self.edits.append(.draw(mark))
            self.inkChanged()
        }
        gesture.onErase = { [weak self, weak pane] page, start, end, radius in
            guard let self, let hits = pane?.inkDisplay.erase(on: page, from: start, to: end, radius: radius), !hits.isEmpty else { return }
            let firstHit = self.activeErasures.isEmpty
            self.activeErasures.append(contentsOf: hits)
            if firstHit { self.refreshInkButtons() }
        }
        gesture.onEraseFinished = { [weak self] completed in
            guard let self, !self.activeErasures.isEmpty else { return }
            let edit = InkEdit.erase(self.activeErasures)
            self.activeErasures = []
            if completed { self.edits.append(edit); self.inkChanged() } else { self.reverse(edit) }
            self.refreshInkButtons()
        }
        gesture.nib = InkNib(rawValue: UserDefaults.standard.string(forKey: "inkNib") ?? "") ?? .fine
        drawing = gesture
        originalScrollTouches = pane.scrollView?.panGestureRecognizer.minimumNumberOfTouches ?? 1
        pane.scrollView?.panGestureRecognizer.require(toFail: gesture)
        applyInputMode()
    }

    private func applyInputMode() {
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let finger = NSNumber(value: UITouch.TouchType.direct.rawValue)
        drawing?.allowedTouchTypes = fingerDrawing ? [pencil, finger] : [pencil]
        panes[index]?.scrollView?.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : originalScrollTouches
        configureNibMenu()
    }

    private func configureNibMenu() {
        guard let drawing else { return }
        nibButton.accessibilityValue = drawing.nib.rawValue
        let widths = InkNib.allCases.map { nib in
            UIAction(title: nib.rawValue, state: drawing.nib == nib ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.drawing?.isEraser = false
                self.drawing?.nib = nib
                UserDefaults.standard.set(nib.rawValue, forKey: "inkNib")
                self.configureNibMenu()
                self.refreshInkButtons()
            }
        }
        let finger = UIAction(title: "Draw with finger", image: UIImage(systemName: "hand.draw"),
                              state: fingerDrawing ? .on : .off) { [weak self] _ in
            guard let self else { return }
            self.fingerDrawing.toggle()
            self.applyInputMode()
        }
        nibButton.menu = UIMenu(children: [UIMenu(title: "Pen width", options: .displayInline, children: widths), finger])
    }

    private func refreshInkButtons() {
        let enabled = drawing != nil && !settling && afterSave == nil && activeErasures.isEmpty
        let erasing = drawing?.isEraser == true
        nibButton.tintColor = enabled && !erasing ? .systemRed : .secondaryLabel
        eraser.image = UIImage(systemName: erasing ? "eraser.fill" : "eraser")
        eraser.tintColor = erasing ? .systemRed : .secondaryLabel
        eraser.accessibilityLabel = "Stroke eraser"
        eraser.accessibilityValue = erasing ? "On" : "Off"
        eraser.isEnabled = enabled
        if case .erase = edits.last { undoInkButton.accessibilityLabel = "Undo erase" }
        else { undoInkButton.accessibilityLabel = "Undo last stroke" }
        nibButton.isEnabled = enabled
        undoInkButton.isEnabled = enabled && !edits.isEmpty
    }
    @objc private func selectPencil() {
        drawing?.isEraser = false
        refreshInkButtons()
    }
    @objc private func toggleEraser() {
        drawing?.isEraser.toggle()
        refreshInkButtons()
    }
    @objc private func undoInk() {
        guard let edit = edits.popLast() else { return }
        reverse(edit)
        inkChanged()
    }
    private func reverse(_ edit: InkEdit) {
        guard let pane = panes[index], let doc = pane.pdf.document else { return }
        switch edit {
        case .draw(let mark):
            if let page = doc.page(at: mark.pageIndex) { pane.inkDisplay.remove(mark, from: page) }
        case .erase(let marks):
            for mark in marks {
                if let page = doc.page(at: mark.pageIndex) { pane.inkDisplay.add(mark, on: page) }
            }
        }
    }
    private func inkChanged() {
        revision += 1
        refreshInkButtons()
        scheduledSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushInk() }
        scheduledSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    @objc private func returnToLibrary() {
        guard !settling, afterSave == nil else { return }
        leaveAfterSaving { [weak self] in self?.navigationController?.popViewController(animated: true) }
    }

    private func leaveAfterSaving(_ action: @escaping () -> Void) {
        drawing?.isEnabled = false
        guard savedRevision != revision || saving else { action(); return }
        afterSave = action
        refreshInkButtons()
        flushInk()
    }

    func flushInk() {
        scheduledSave?.cancel()
        scheduledSave = nil
        guard !saving, revision != savedRevision, let paper = panes[index]?.retainedPaper else { return }
        saving = true
        let ticket = revision
        let source = folder.url.appendingPathComponent(papers[index].name)
        let expected = lastWritten ?? paper.snapshot
        let recovery = recoveryURL
        var added = [InkDisplay.DisplayMark]()
        var erased = Set<ObjectIdentifier>()
        var removed = [Int: Set<Int>]()
        for edit in edits {
            switch edit {
            case .draw(let mark):
                added.append(mark)
            case .erase(let marks):
                for mark in marks {
                    erased.insert(ObjectIdentifier(mark))
                    if case .saved(let slot) = mark.origin { removed[mark.pageIndex, default: []].insert(slot) }
                }
            }
        }
        let strokes = added.compactMap { mark -> InkStroke? in
            guard !erased.contains(ObjectIdentifier(mark)), case .drawn(let stroke) = mark.origin else { return nil }
            return stroke
        }
        let removedSlots = removed
        if lastWritten == nil, strokes.isEmpty, removedSlots.isEmpty {
            saving = false
            savedRevision = revision
            let action = afterSave
            afterSave = nil
            action?()
            return
        }
        if backgroundTask == .invalid {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Save PDF ink") { [weak self] in self?.endBackgroundSave() }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try InkFile.autosave(from: paper.snapshot, expected: expected, source: source,
                                     recovery: recovery, strokes: strokes, removing: removedSlots)
            }
            DispatchQueue.main.async {
                self.saving = false
                switch result {
                case .success(let output):
                    if let old = self.lastWritten { try? FileManager.default.removeItem(at: old) }
                    self.lastWritten = output.draft
                    self.savedRevision = ticket
                    if output.recovery != self.recoveryURL { self.recoveryNoticePending = true }
                    self.recoveryURL = output.recovery
                    self.libraryNeedsRefresh = true
                    if ticket != self.revision { self.flushInk() }
                    else {
                        self.endBackgroundSave()
                        let action = self.afterSave
                        self.afterSave = nil
                        if self.recoveryNoticePending, let copy = output.recovery {
                            self.recoveryNoticePending = false
                            self.drawing?.isEnabled = true
                            self.refreshInkButtons()
                            let notice = UIAlertController(title: "Saved a recovery copy",
                                message: "The original PDF couldn’t be updated. Your edits for this visit are saving to Files → On My iPad → PaperGlide → Recovered Markups → " + copy.lastPathComponent, preferredStyle: .alert)
                            notice.addAction(UIAlertAction(title: "OK", style: .default) { _ in action?() })
                            self.present(notice, animated: true)
                        } else { action?() }
                    }
                case .failure(let error):
                    self.afterSave = nil
                    self.drawing?.isEnabled = true
                    self.drag = 0
                    self.layoutPanes()
                    self.endBackgroundSave()
                    self.refreshInkButtons()
                    let alert = UIAlertController(title: "Couldn’t save your ink", message: error.localizedDescription, preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "Retry", style: .default) { _ in self.flushInk() })
                    alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
                    if self.presentedViewController == nil { self.present(alert, animated: true) }
                }
            }
        }
    }

    private func endBackgroundSave() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func detachInk() {
        if let drawing { panes[index]?.pdf.removeGestureRecognizer(drawing) }
        panes[index]?.scrollView?.panGestureRecognizer.minimumNumberOfTouches = originalScrollTouches
        drawing = nil
        edits = []
        activeErasures = []
        savedRevision = 0
        revision = 0
        if let lastWritten { try? FileManager.default.removeItem(at: lastWritten) }
        lastWritten = nil
        recoveryURL = nil
        recoveryNoticePending = false
    }
}
