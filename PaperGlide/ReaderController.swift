import UIKit
import PDFKit

final class ReaderController: UIViewController, UIGestureRecognizerDelegate, UIDocumentPickerDelegate {
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
    private var exportDirectory: URL?
    private var originalScrollTouches = 1
    private lazy var mark = UIBarButtonItem(image: UIImage(systemName: "pencil.tip"), style: .plain, target: self, action: #selector(startInk))
    private lazy var saveInkButton = UIBarButtonItem(title: "Save", style: .done, target: self, action: #selector(saveInk))
    private lazy var undoInkButton = UIBarButtonItem(image: UIImage(systemName: "arrow.uturn.backward"), style: .plain, target: self, action: #selector(undoInk))
    private let nibButton = UIBarButtonItem(image: UIImage(systemName: "lineweight"), menu: nil)
    private lazy var finger = UIBarButtonItem(image: UIImage(systemName: "hand.draw"), style: .plain, target: self, action: #selector(toggleFinger))
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
    private lazy var previous = UIBarButtonItem(image: UIImage(systemName: "chevron.left"), style: .plain, target: self, action: #selector(previousPaper))
    private lazy var nextButton = UIBarButtonItem(image: UIImage(systemName: "chevron.right"), style: .plain, target: self, action: #selector(nextPaper))

    init(folder: Folder, papers: [PaperEntry], index: Int) {
        self.folder = folder
        self.papers = papers
        self.index = index
        super.init(nibName: nil, bundle: nil)
        queue.maxConcurrentOperationCount = 3
        queue.qualityOfService = .userInitiated
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
        previous.accessibilityLabel = "Previous paper"
        nextButton.accessibilityLabel = "Next paper"
        mark.accessibilityLabel = "Mark PDF"
        undoInkButton.accessibilityLabel = "Undo last stroke"
        navigationItem.rightBarButtonItems = [mark, tag, nextButton, previous]
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
        mark.isEnabled = !settling && panes[index]?.retainedPaper?.document.allowsCommenting == true
        previous.isEnabled = index > 0 && !settling
        nextButton.isEnabled = index + 1 < papers.count && !settling
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
    @objc private func previousPaper() { settle(-1) }
    @objc private func nextPaper() { settle(1) }

    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard !settling, recognizer === pan else { return false }
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
        if delta != 0 { savePosition() }
        settling = true
        updateControls()
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18, delay: 0, options: [.curveEaseOut, .beginFromCurrentState]) {
            self.drag = -CGFloat(delta) * self.canvas.bounds.width
            self.layoutPanes()
        } completion: { _ in
            self.index += delta
            self.drag = 0
            self.settling = false
            self.updateWindow()
        }
    }
}

extension ReaderController {
    @objc private func startInk() {
        guard drawing == nil, let pane = panes[index], pane.retainedPaper != nil else { return }
        let gesture = InkGesture(surface: pane.pdf)
        gesture.onStroke = { [weak self, weak pane] stroke in
            guard let self, let page = pane?.pdf.document?.page(at: stroke.page) else { return }
            let mark = InkDisplay.DisplayMark(stroke.annotation(), origin: .drawn(stroke), pageIndex: stroke.page)
            pane?.inkDisplay.add(mark, on: page)
            self.edits.append(.draw(mark))
            self.refreshInkButtons()
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
            if completed { self.edits.append(edit) } else { self.reverse(edit) }
            self.refreshInkButtons()
        }
        gesture.nib = InkNib(rawValue: UserDefaults.standard.string(forKey: "inkNib") ?? "") ?? .fine
        drawing = gesture
        configureNibMenu()
        pan.isEnabled = false
        originalScrollTouches = pane.scrollView?.panGestureRecognizer.minimumNumberOfTouches ?? 1
        pane.scrollView?.panGestureRecognizer.require(toFail: gesture)
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .cancel, target: self, action: #selector(cancelInk))
        navigationItem.rightBarButtonItems = [saveInkButton, undoInkButton, eraser, nibButton, finger]
        refreshInkButtons()
    }

    private func configureNibMenu() {
        guard let drawing else { return }
        nibButton.accessibilityLabel = "Pen width"
        nibButton.accessibilityValue = drawing.nib.rawValue
        nibButton.menu = UIMenu(title: "Pen width", children: InkNib.allCases.map { nib in
            UIAction(title: nib.rawValue, state: drawing.nib == nib ? .on : .off) { [weak self] _ in
                self?.drawing?.isEraser = false
                self?.drawing?.nib = nib
                self?.refreshInkButtons()
                UserDefaults.standard.set(nib.rawValue, forKey: "inkNib")
                self?.configureNibMenu()
            }
        })
    }
    private func refreshInkButtons() {
        let canDraw = !saving && activeErasures.isEmpty
        let erasing = drawing?.isEraser == true
        eraser.image = UIImage(systemName: erasing ? "eraser.fill" : "eraser")
        eraser.tintColor = erasing ? .systemRed : .secondaryLabel
        eraser.accessibilityLabel = "Stroke eraser"
        eraser.accessibilityValue = erasing ? "On" : "Off"
        eraser.isEnabled = canDraw
        if case .erase = edits.last { undoInkButton.accessibilityLabel = "Undo erase" }
        else { undoInkButton.accessibilityLabel = "Undo last stroke" }
        let fingerOn = drawing?.allowedTouchTypes.contains(NSNumber(value: UITouch.TouchType.direct.rawValue)) == true
        finger.tintColor = fingerOn ? .systemRed : .secondaryLabel
        finger.accessibilityLabel = fingerOn ? "Use Apple Pencil only" : "Draw with finger"
        finger.isEnabled = canDraw
        nibButton.isEnabled = canDraw
        saveInkButton.title = saving ? "Saving…" : "Save"
        saveInkButton.isEnabled = canDraw && !edits.isEmpty
        undoInkButton.isEnabled = canDraw && !edits.isEmpty
        navigationItem.leftBarButtonItem?.isEnabled = canDraw
    }
    @objc private func toggleEraser() {
        drawing?.isEraser.toggle()
        refreshInkButtons()
    }
    @objc private func toggleFinger() {
        guard let drawing else { return }
        let direct = NSNumber(value: UITouch.TouchType.direct.rawValue)
        let pencil = NSNumber(value: UITouch.TouchType.pencil.rawValue)
        let useFinger = !drawing.allowedTouchTypes.contains(direct)
        drawing.allowedTouchTypes = useFinger ? [pencil, direct] : [pencil]
        panes[index]?.scrollView?.panGestureRecognizer.minimumNumberOfTouches = useFinger ? 2 : originalScrollTouches
        refreshInkButtons()
    }
    @objc private func undoInk() {
        guard let edit = edits.popLast() else { return }
        reverse(edit)
        refreshInkButtons()
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
    @objc private func cancelInk() {
        guard !edits.isEmpty else { finishInk(reload: false); return }
        let alert = UIAlertController(title: "Discard markup changes?", message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
        alert.addAction(UIAlertAction(title: "Discard", style: .destructive) { [weak self] _ in self?.finishInk(reload: false) })
        present(alert, animated: true)
    }
    @objc private func saveInk() {
        guard !saving, let paper = panes[index]?.retainedPaper, !edits.isEmpty else { return }
        saving = true
        drawing?.isEnabled = false
        refreshInkButtons()
        let source = folder.url.appendingPathComponent(papers[index].name)
        if let old = exportDirectory { try? FileManager.default.removeItem(at: old) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        exportDirectory = directory
        let draft = directory.appendingPathComponent(source.deletingPathExtension().lastPathComponent + " (marked).pdf")
        var added = [InkDisplay.DisplayMark]()
        var removed = [Int: Set<Int>]()
        for edit in edits {
            switch edit {
            case .draw(let mark):
                added.append(mark)
            case .erase(let marks):
                let erasedIDs = Set(marks.map(ObjectIdentifier.init))
                added.removeAll { erasedIDs.contains(ObjectIdentifier($0)) }
                for mark in marks {
                    if case .saved(let index) = mark.origin { removed[mark.pageIndex, default: []].insert(index) }
                }
            }
        }
        let strokes = added.compactMap { mark -> InkStroke? in
            if case .drawn(let stroke) = mark.origin { return stroke }
            return nil
        }
        let removedSlots = removed
        if strokes.isEmpty && removedSlots.isEmpty { saving = false; finishInk(reload: false); return }
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try InkFile.generate(from: paper.snapshot, strokes: strokes, removing: removedSlots, to: draft)
                try InkFile.commit(draft, replacing: source, basedOn: paper.snapshot)
            }
            DispatchQueue.main.async {
                self.saving = false
                switch result {
                case .success:
                    self.finishInk(reload: true)
                    self.didSavePDF?()
                case .failure(let error):
                    self.drawing?.isEnabled = true
                    self.refreshInkButtons()
                    let alert = UIAlertController(title: "Couldn’t save to the shared PDF", message: error.localizedDescription, preferredStyle: .alert)
                    if let valid = PDFDocument(url: draft), valid.pageCount == paper.document.pageCount {
                        alert.addAction(UIAlertAction(title: "Save a Copy", style: .default) { _ in
                            let picker = UIDocumentPickerViewController(forExporting: [draft], asCopy: true)
                            picker.delegate = self
                            self.present(picker, animated: true)
                        })
                    }
                    alert.addAction(UIAlertAction(title: "Keep Editing", style: .cancel))
                    self.present(alert, animated: true)
                }
            }
        }
    }
    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        if !urls.isEmpty { finishInk(reload: false); didSavePDF?() }
    }
    private func finishInk(reload: Bool) {
        let pane = panes[index]
        if let drawing { pane?.pdf.removeGestureRecognizer(drawing) }
        drawing = nil
        if !reload { for edit in edits.reversed() { reverse(edit) } }
        edits = []
        if let dir = exportDirectory { try? FileManager.default.removeItem(at: dir) }
        exportDirectory = nil
        pane?.scrollView?.panGestureRecognizer.minimumNumberOfTouches = originalScrollTouches
        navigationItem.leftBarButtonItem = nil
        navigationItem.hidesBackButton = false
        navigationItem.rightBarButtonItems = [mark, tag, nextButton, previous]
        pan.isEnabled = true
        if reload { savePosition(); load(index) }
        updateControls()
    }
}
