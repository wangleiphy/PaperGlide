import UIKit
import UniformTypeIdentifiers

final class LibraryController: UITableViewController, UIDocumentPickerDelegate, UISearchResultsUpdating {
    private var folder: Folder?
    private var papers = [PaperEntry]()
    private var orderedPapers = [PaperEntry]()
    private var visible = [PaperEntry]()
    private var sorting: Task<Void, Never>?
    private var filtering: Task<Void, Never>?
    private var order = PaperOrder.preferred
    private let sort = UIBarButtonItem(image: UIImage(systemName: "arrow.up.arrow.down"), menu: nil)
    private let emptyStack = UIStackView()
    private let emptyTitle = UILabel()
    private let emptyMessage = UILabel()
    private let emptyChoose = UIButton(type: .system)
    private var redOnly = false
    private var deleting = Set<URL>()
    private var loading = false
    private var readError: String?
    private var revision = 0
    private let search = UISearchController(searchResultsController: nil)
    private lazy var filter = UIBarButtonItem(image: UIImage(systemName: "tag"), style: .plain, target: self, action: #selector(filterRed))

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Papers"
        navigationItem.backButtonTitle = "Papers"
        let privacy = UIBarButtonItem(image: UIImage(systemName: "info.circle"), style: .plain, target: self, action: #selector(showPrivacy))
        privacy.accessibilityLabel = "Privacy policy"
        navigationItem.leftBarButtonItem = privacy
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search by filename"
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
        search.searchBar.searchTextField.accessibilityIdentifier = "Filename search"
        search.searchResultsUpdater = self
        navigationItem.searchController = search
        definesPresentationContext = true
        let choose = UIBarButtonItem(image: UIImage(systemName: "folder"), style: .plain, target: self, action: #selector(chooseFolder))
        choose.accessibilityLabel = "Choose folder"
        navigationItem.rightBarButtonItems = [choose, filter, sort]
        sort.accessibilityLabel = "Sort papers"
        setSortMenu()
        emptyStack.axis = .vertical
        emptyStack.alignment = .center
        emptyStack.spacing = 10
        emptyTitle.font = .preferredFont(forTextStyle: .headline)
        emptyMessage.font = .preferredFont(forTextStyle: .body)
        emptyMessage.textColor = .secondaryLabel
        emptyMessage.numberOfLines = 0
        emptyMessage.textAlignment = .center
        emptyChoose.setTitle("Choose Folder", for: .normal)
        emptyChoose.addTarget(self, action: #selector(chooseFolder), for: .touchUpInside)
        [emptyTitle, emptyMessage, emptyChoose].forEach(emptyStack.addArrangedSubview)
        let background = UIView()
        background.addSubview(emptyStack)
        emptyStack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyStack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            emptyStack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            emptyStack.widthAnchor.constraint(lessThanOrEqualTo: background.widthAnchor, multiplier: 0.85)
        ])
        tableView.backgroundView = background
        filter.accessibilityLabel = "Show red-tagged papers"
        refreshControl = UIRefreshControl()
        refreshControl?.addTarget(self, action: #selector(refresh), for: .valueChanged)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "paper")
        do {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-fixture-papers") {
                folder = try DemoPapers.folder()
            } else {
                folder = try Folder.reopen()
            }
            #else
            folder = try Folder.reopen()
            #endif
        } catch { readError = error.localizedDescription }
        refresh()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applyFilter()
    }

    @objc private func showPrivacy() {
        guard let url = Bundle.main.url(forResource: "Privacy", withExtension: "txt"),
              let policy = try? String(contentsOf: url, encoding: .utf8) else { return }
        let controller = UIViewController()
        controller.title = "Privacy policy"
        let text = UITextView()
        text.isEditable = false
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 24, right: 20)
        text.text = policy
        text.dataDetectorTypes = [.link]
        controller.view = text
        navigationController?.pushViewController(controller, animated: true)
    }

    @objc private func chooseFolder() {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder], asCopy: false)
        picker.delegate = self
        picker.directoryURL = folder?.url
        present(picker, animated: true)
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        guard let url = urls.first else { return }
        let picked = Folder(url)
        folder = picked
        do { try picked.saveBookmark() } catch {
            let alert = UIAlertController(title: "Choose this folder again next time", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
        redOnly = false
        search.searchBar.text = nil
        sorting?.cancel()
        filtering?.cancel()
        papers = []
        orderedPapers = []
        visible = []
        refresh()
    }

    @objc private func refresh() {
        guard let folder else {
            refreshControl?.endRefreshing()
            applyFilter()
            return
        }
        title = folder.url.lastPathComponent
        revision += 1
        let ticket = revision
        loading = true
        readError = nil
        applyFilter()
        Folder.metadataQueue.async { [weak self] in
            let result = Result { try folder.loadLibrary() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == ticket else { return }
                self.loading = false
                self.refreshControl?.endRefreshing()
                switch result {
                case .success(let library):
                    folder.tags = library.red
                    self.papers = library.papers
                    if library.pending > 0 {
                        let note = UILabel()
                        note.numberOfLines = 0
                        note.textAlignment = .center
                        note.font = .preferredFont(forTextStyle: .footnote)
                        note.text = "Finder could not save \(library.pending) earlier red tag(s). Pull to refresh and retry."
                        note.frame.size = note.sizeThatFits(CGSize(width: self.tableView.bounds.width, height: .greatestFiniteMagnitude))
                        self.tableView.tableFooterView = note
                    } else { self.tableView.tableFooterView = nil }
                    self.sortPapers()
                case .failure(let error):
                    self.readError = error.localizedDescription
                    self.applyFilter()
                }
            }
        }
    }

    private func sortPapers() {
        sorting?.cancel()
        sorting = Task.detached(priority: .userInitiated) { [weak self, papers, order] in
            // A changed order or folder can supersede an expensive localized sort.
            guard let sorted = try? papers.sorted(by: { lhs, rhs in
                try Task.checkCancellation()
                return order.precedes(lhs, rhs)
            }) else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.orderedPapers = sorted
                self.applyFilter()
            }
        }
    }

    private func setSortMenu() {
        sort.menu = UIMenu(title: "Sort papers", children: PaperOrder.allCases.map { option in
            UIAction(title: option.rawValue, state: option == order ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.order = option
                PaperOrder.preferred = option
                self.setSortMenu()
                self.sortPapers()
            }
        })
    }
    @objc private func filterRed() { redOnly.toggle(); applyFilter() }
    func updateSearchResults(for searchController: UISearchController) { applyFilter() }

    private func applyFilter() {
        let query = search.searchBar.text ?? ""
        filtering?.cancel()
        guard !orderedPapers.isEmpty, redOnly || !query.isEmpty else {
            visible = orderedPapers
            reloadResults()
            return
        }
        let tags = redOnly ? folder?.tags : nil
        filtering = Task.detached(priority: .userInitiated) { [weak self, orderedPapers] in
            guard let matches = try? orderedPapers.filter({ entry in
                try Task.checkCancellation()
                return (tags?.contains(entry.name) ?? true) && (query.isEmpty || entry.name.localizedCaseInsensitiveContains(query))
            }) else { return }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled, let self else { return }
                self.visible = matches
                self.reloadResults()
            }
        }
    }

    private func reloadResults() {
        filter.image = UIImage(systemName: redOnly ? "tag.fill" : "tag")
        filter.tintColor = redOnly ? .systemRed : nil
        filter.accessibilityLabel = redOnly ? "Show all papers" : "Show red-tagged papers"
        filter.isEnabled = folder != nil
        tableView.reloadData()
        emptyStack.isHidden = !visible.isEmpty
        if visible.isEmpty {
            emptyTitle.text = readError != nil ? "Folder unavailable" : loading ? "Opening folder…" : folder == nil ? "Choose your papers folder" : redOnly ? "No matching red tags" : "No matching PDFs"
            emptyMessage.text = readError ?? (folder == nil ? "Open a folder from iCloud Drive or On My iPad." : nil)
            emptyMessage.isHidden = emptyMessage.text == nil
            emptyChoose.isHidden = folder != nil && readError == nil
        }
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { visible.count }
    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "paper", for: indexPath)
        let entry = visible[indexPath.row]
        let name = entry.name
        let tagged = folder?.tags.contains(name) == true
        var content = cell.defaultContentConfiguration()
        content.text = (name as NSString).deletingPathExtension
        if let date = order.date(for: entry) {
            content.secondaryText = date.formatted(date: .abbreviated, time: .shortened)
            content.secondaryTextProperties.color = .secondaryLabel
        }
        content.image = UIImage(systemName: tagged ? "tag.fill" : "doc.text")
        content.imageProperties.tintColor = tagged ? .systemRed : .secondaryLabel
        cell.contentConfiguration = content
        cell.accessibilityValue = tagged ? "Red tagged" : nil
        cell.accessoryType = .disclosureIndicator
        return cell
    }
    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let folder, visible.indices.contains(indexPath.row) else { return nil }
        let name = visible[indexPath.row].name
        let url = folder.url.appendingPathComponent(name)
        let action = UIContextualAction(style: .destructive, title: "Delete") { [weak self] _, _, close in
            close(false) // The table changes only after the file operation succeeds.
            guard let self, self.folder === folder, !self.deleting.contains(url) else { return }
            self.confirmPDFDeletion(name) {
                guard self.deleting.insert(url).inserted else { return }
                folder.deletePDF(name) { result in
                    self.deleting.remove(url)
                    guard self.folder === folder else { return }
                    switch result {
                    case .success: self.removeDeletedPDF(name)
                    case .failure(let error): self.showDeletionError(name, error: error)
                    }
                }
            }
        }
        action.image = UIImage(systemName: "trash")
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func removeDeletedPDF(_ name: String) {
        sorting?.cancel()
        filtering?.cancel()
        papers.removeAll { $0.name == name }
        orderedPapers.removeAll { $0.name == name }
        visible.removeAll { $0.name == name }
        reloadResults()
        refresh()
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        guard let folder else { return }
        guard !deleting.contains(folder.url.appendingPathComponent(visible[indexPath.row].name)) else { return }
        let reader = ReaderController(folder: folder, papers: visible, index: indexPath.row)
        reader.didChangeTags = { [weak self] in self?.applyFilter() }
        reader.didDeletePDF = { [weak self] name in self?.removeDeletedPDF(name) }
        reader.didSavePDF = { [weak self] in self?.refresh() }
        navigationController?.pushViewController(reader, animated: true)
    }
}

extension UIViewController {
    func confirmPDFDeletion(_ name: String, onConfirm: @escaping () -> Void) {
        let alert = UIAlertController(title: "Delete " + name + "?",
                                      message: "This removes the PDF from its folder. In a shared folder, it also removes it for everyone with access.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { _ in onConfirm() })
        present(alert, animated: true)
    }

    func showDeletionError(_ name: String, error: Error) {
        let alert = UIAlertController(title: "Couldn’t delete " + name, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}
