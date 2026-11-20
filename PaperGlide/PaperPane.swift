import UIKit
import PDFKit

final class PaperPane: UIView {
    let pdf = PDFView()
    lazy var inkDisplay = InkDisplay(pdf: pdf)
    private let status = UIStackView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let message = UILabel()
    private let retry = UIButton(type: .system)
    private(set) var retainedPaper: LoadedPaper?
    private var operation: Operation?
    private var coordinator: NSFileCoordinator?
    private var baseScale: CGFloat = 1
    private var previousWidth: CGFloat = 0
    var onRetry: (() -> Void)?
    var onReady: (() -> Void)?
    private var waitingForLayout: ReadingPosition?
    private var needsInitialLayout = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemBackground
        pdf.displayMode = .singlePageContinuous
        pdf.displayDirection = .vertical
        pdf.displayBox = .cropBox
        pdf.displaysPageBreaks = true
        pdf.backgroundColor = .secondarySystemBackground
        pdf.accessibilityIdentifier = "Paper pages"
        addSubview(pdf)
        addSubview(inkDisplay)
        status.axis = .vertical
        status.alignment = .center
        status.spacing = 12
        status.translatesAutoresizingMaskIntoConstraints = false
        message.numberOfLines = 0
        message.textAlignment = .center
        message.font = .preferredFont(forTextStyle: .body)
        retry.setTitle("Try Again", for: .normal)
        retry.addTarget(self, action: #selector(retryLoad), for: .touchUpInside)
        [spinner, message, retry].forEach(status.addArrangedSubview)
        addSubview(status)
        NSLayoutConstraint.activate([
            status.centerXAnchor.constraint(equalTo: centerXAnchor),
            status.centerYAnchor.constraint(equalTo: centerYAnchor),
            status.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.8)
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func load(folder: Folder, name: String, position: ReadingPosition?, queue: OperationQueue, priority: Operation.QueuePriority) {
        cancel()
        inkDisplay.reset()
        retainedPaper = nil
        pdf.document = nil
        message.text = "Opening " + name
        retry.isHidden = true
        status.isHidden = false
        spinner.startAnimating()
        let coordinator = NSFileCoordinator()
        self.coordinator = coordinator
        let operation = BlockOperation()
        operation.queuePriority = priority
        operation.addExecutionBlock { [weak operation, weak self] in
            guard operation?.isCancelled == false else { return }
            let result = Result { try LoadedPaper(url: folder.url.appendingPathComponent(name), coordinator: coordinator) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.coordinator === coordinator else { return }
                self.spinner.stopAnimating()
                switch result {
                case .success(let paper):
                    self.retainedPaper = paper
                    self.pdf.document = paper.document
                    self.waitingForLayout = position
                    self.needsInitialLayout = true
                    self.status.isHidden = true
                    self.setNeedsLayout()
                    self.layoutIfNeeded()
                    self.inkDisplay.track(self.scrollView)
                    self.onReady?()
                case .failure(let error):
                    self.message.text = "Couldn’t open " + name + "\n" + error.localizedDescription
                    self.retry.isHidden = false
                }
            }
        }
        self.operation = operation
        queue.addOperation(operation)
    }
    @objc private func retryLoad() { onRetry?() }
    func cancel() {
        operation?.cancel()
        coordinator?.cancel()
        coordinator = nil
        operation = nil
    }
    deinit { operation?.cancel(); coordinator?.cancel() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let widthChanged = abs(previousWidth - bounds.width) > 0.5
        let restore = needsInitialLayout ? waitingForLayout : widthChanged ? position() : nil
        pdf.frame = bounds
        if inkDisplay.frame != bounds {
            inkDisplay.frame = bounds
            inkDisplay.redraw()
        }
        guard bounds.width > 0, bounds.height > 0, needsInitialLayout || widthChanged,
              let doc = pdf.document, let first = doc.page(at: 0) else { return }
        previousWidth = bounds.width
        needsInitialLayout = false
        waitingForLayout = nil
        // PDFView's fit scale includes rotation and page gutters.
        pdf.autoScales = true
        pdf.layoutIfNeeded()
        baseScale = max(0.01, pdf.scaleFactorForSizeToFit)
        pdf.autoScales = false
        pdf.minScaleFactor = baseScale
        pdf.maxScaleFactor = baseScale * 8
        pdf.scaleFactor = baseScale * min(8, max(1, restore?.zoom ?? 1))
        pdf.layoutDocumentView()
        if let restore, let page = doc.page(at: min(restore.page, doc.pageCount - 1)) {
            let point = CGPoint(x: restore.x, y: restore.y)
            pdf.go(to: page)
            pdf.layoutIfNeeded()
            if let scroll = scrollView {
                let current = pdf.convert(point, from: page)
                let desired = CGPoint(x: bounds.midX, y: bounds.midY)
                let inset = scroll.adjustedContentInset
                let offset = CGPoint(x: scroll.contentOffset.x + current.x - desired.x,
                                     y: scroll.contentOffset.y + current.y - desired.y)
                func clamp(_ x: CGFloat, min low: CGFloat, max high: CGFloat) -> CGFloat { max(low, min(high, x)) }
                scroll.setContentOffset(CGPoint(
                    x: clamp(offset.x, min: -inset.left, max: scroll.contentSize.width - scroll.bounds.width + inset.right),
                    y: clamp(offset.y, min: -inset.top, max: scroll.contentSize.height - scroll.bounds.height + inset.bottom)
                ), animated: false)
            }
        } else { pdf.go(to: first) }
    }

    var scrollView: UIScrollView? {
        var ancestor = pdf.documentView?.superview
        while let view = ancestor {
            if let scroll = view as? UIScrollView { return scroll }
            ancestor = view.superview
        }
        return nil
    }
    var zoomed: Bool { pdf.document != nil && pdf.scaleFactor > baseScale * 1.04 }
    func position() -> ReadingPosition? {
        let center = CGPoint(x: pdf.bounds.midX, y: pdf.bounds.midY)
        guard !needsInitialLayout, let doc = pdf.document,
              let page = pdf.page(for: center, nearest: true) else { return nil }
        let point = pdf.convert(center, to: page)
        return ReadingPosition(page: doc.index(for: page), x: point.x, y: point.y, zoom: pdf.scaleFactor / baseScale)
    }
}
