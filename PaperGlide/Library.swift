import Foundation
import PDFKit
import CryptoKit
import Darwin

struct ReadingPosition: Codable {
    let page: Int
    let x: CGFloat
    let y: CGFloat
    let zoom: CGFloat
}

struct PaperEntry {
    let name: String
    let modified: Date?
    let created: Date?
}

enum PaperOrder: String, CaseIterable {
    case name = "Filename"
    case modifiedNewest = "Date modified · newest first"
    case modifiedOldest = "Date modified · oldest first"
    case createdNewest = "Date created · newest first"
    case createdOldest = "Date created · oldest first"

    // Start existing libraries in creation-date order once, then honor later selections.
    private static let preferenceKey = "librarySortOrder"
    static var preferred: PaperOrder {
        get {
            UserDefaults.standard.string(forKey: preferenceKey).flatMap(PaperOrder.init(rawValue:)) ?? .createdNewest
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: preferenceKey) }
    }

    func date(for entry: PaperEntry) -> Date? {
        switch self {
        case .createdNewest, .createdOldest: return entry.created
        default: return entry.modified
        }
    }

    func precedes(_ left: PaperEntry, _ right: PaperEntry) -> Bool {
        if self != .name {
            let a = date(for: left), b = date(for: right)
            if let a, let b, a != b {
                return self == .modifiedOldest || self == .createdOldest ? a < b : a > b
            }
            if (a == nil) != (b == nil) { return a != nil }
        }
        return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
}

// Finder stores the tag names and palette numbers together in a binary property list.
enum FinderTags {
    static let attribute = "com.apple.metadata:_kMDItemUserTags"
    static let red = "Red\n6"

    static func read(_ url: URL) throws -> [String] {
        for _ in 0..<3 {
            let size = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
            if size < 0 {
                if errno == ENOATTR { return [] }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard size > 0 else { throw CocoaError(.fileReadCorruptFile) }
            var data = Data(count: size)
            let count = data.withUnsafeMutableBytes {
                getxattr(url.path, attribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW)
            }
            if count < 0 {
                if errno == ERANGE || errno == ENOATTR { continue }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            guard let tags = try PropertyListSerialization.propertyList(from: data.prefix(count), format: nil) as? [String] else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return tags
        }
        throw POSIXError(.EAGAIN)
    }

    static func write(_ tags: [String], to url: URL) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: tags, format: .binary, options: 0)
        let result = data.withUnsafeBytes { setxattr(url.path, attribute, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    static func isRed(_ tag: String) -> Bool {
        // Some providers normalize the color suffix when the file syncs.
        tag.split(separator: "\n", maxSplits: 1).first == "Red"
    }

    static func setRed(_ enabled: Bool, at url: URL) throws {
        var error: NSError?
        var result: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .contentIndependentMetadataOnly, error: &error) { live in
            result = Result {
                var tags = try read(live)
                if enabled {
                    guard !tags.contains(where: isRed) else { return }
                    tags.append(red)
                } else {
                    guard tags.contains(where: isRed) else { return }
                    tags.removeAll(where: isRed)
                }
                try write(tags, to: live)
                guard try read(live) == tags else { throw CocoaError(.fileWriteUnknown) }
            }
        }
        if let error { throw error }
        guard let result else { throw CocoaError(.fileWriteUnknown) }
        try result.get()
    }
}

final class Folder {
    let url: URL
    private let scoped: Bool
    private let key: String
    private let defaults = UserDefaults.standard
    static let metadataQueue = DispatchQueue(label: "PaperGlide.file-metadata", qos: .userInitiated)
    var tags = Set<String>() // Published and read on the main thread.

    init(_ url: URL) {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        // Scope metadata to this folder, even when other folders contain identical filenames.
        key = SHA256.hash(data: Data(url.standardizedFileURL.path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }

    func saveBookmark() throws {
        let bookmark = try url.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "currentFolder")
    }

    static func reopen() throws -> Folder? {
        guard let data = UserDefaults.standard.data(forKey: "currentFolder") else { return nil }
        var stale = false
        let url = try URL(resolvingBookmarkData: data, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale)
        let folder = Folder(url)
        if stale { try folder.saveBookmark() }
        return folder
    }

    func loadLibrary() throws -> (papers: [PaperEntry], red: Set<String>, pending: Int) {
        let papers = try papers()
        let legacyKey = key + ".red"
        var legacy = Set(defaults.stringArray(forKey: legacyKey) ?? [])
        var red = Set<String>()
        var pending = 0
        for entry in papers {
            let file = url.appendingPathComponent(entry.name)
            if legacy.contains(entry.name) {
                do {
                    try FinderTags.setRed(true, at: file)
                    legacy.remove(entry.name)
                    red.insert(entry.name)
                } catch { pending += 1 }
            } else if (try? FinderTags.read(file).contains(where: FinderTags.isRed)) == true {
                red.insert(entry.name)
            }
        }
        if defaults.object(forKey: legacyKey) != nil { defaults.set(legacy.sorted(), forKey: legacyKey) }
        return (papers, red, pending)
    }

    func position(_ name: String) -> ReadingPosition? {
        defaults.data(forKey: key + ".position." + name).flatMap { try? JSONDecoder().decode(ReadingPosition.self, from: $0) }
    }

    func save(_ position: ReadingPosition, for name: String) {
        if let data = try? JSONEncoder().encode(position) {
            defaults.set(data, forKey: key + ".position." + name)
        }
    }

    func deletePDF(_ name: String, completion: @escaping (Result<Void, Error>) -> Void) {
        Self.metadataQueue.async {
            let result = Result { try self.trashPDF(name) }
            DispatchQueue.main.async {
                if case .success = result { self.tags.remove(name) }
                completion(result)
            }
        }
    }

    private func trashPDF(_ name: String) throws {
        guard name == (name as NSString).lastPathComponent,
              (name as NSString).pathExtension.lowercased() == "pdf" else { throw CocoaError(.fileWriteInvalidFileName) }
        let file = url.appendingPathComponent(name)
        var coordinationError: NSError?
        var outcome: Result<Void, Error>?
        NSFileCoordinator().coordinate(writingItemAt: file, options: .forDeleting, error: &coordinationError) { live in
            outcome = Result {
                let values = try live.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw CocoaError(.fileWriteInvalidFileName) }
                do {
                    try FileManager.default.trashItem(at: live, resultingItemURL: nil)
                } catch let error as CocoaError where error.code == .featureUnsupported {
                    try FileManager.default.removeItem(at: live)
                }
            }
        }
        if let coordinationError { throw coordinationError }
        guard let outcome else { throw CocoaError(.fileWriteUnknown) }
        try outcome.get()
        defaults.removeObject(forKey: key + ".position." + name)
        let oldTags = key + ".red"
        if let old = defaults.stringArray(forKey: oldTags), old.contains(name) {
            defaults.set(old.filter { $0 != name }, forKey: oldTags)
        }
    }

    func papers() throws -> [PaperEntry] {
        try coordinatedRead(url) { dir in
            let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey, .creationDateKey]
            let resourceKeys = Set(keys)
            let items = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            return items.compactMap { item in
                guard item.pathExtension.lowercased() == "pdf",
                      let values = try? item.resourceValues(forKeys: resourceKeys),
                      values.isDirectory != true, values.isSymbolicLink != true else { return nil }
                return PaperEntry(name: item.lastPathComponent, modified: values.contentModificationDate, created: values.creationDate)
            }
        }
    }
}

func coordinatedRead<T>(_ url: URL, coordinator: NSFileCoordinator = NSFileCoordinator(), _ body: (URL) throws -> T) throws -> T {
    var result: Result<T, Error>?
    var error: NSError?
    coordinator.coordinate(readingItemAt: url, options: .withoutChanges, error: &error) { accessible in
        result = Result { try body(accessible) }
    }
    if let error { throw error }
    guard let result else { throw CocoaError(.fileReadUnknown) }
    return try result.get()
}

// Own the coordinated snapshot for as long as PDFKit can lazily read its pages.
final class LoadedPaper {
    // A force-quit skips deinit. Reclaim only this app's old session snapshots on next use.
    private static let scratch: URL = {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PaperGlideSnapshots", isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        return directory
    }()

    let document: PDFDocument
    let snapshot: URL

    init(url: URL, coordinator: NSFileCoordinator) throws {
        try FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
        let snapshot = Self.scratch.appendingPathComponent(UUID().uuidString + ".pdf")
        do {
            try coordinatedRead(url, coordinator: coordinator) { try FileManager.default.copyItem(at: $0, to: snapshot) }
            guard let pdf = PDFDocument(url: snapshot), !pdf.isLocked, pdf.pageCount > 0 else {
                throw NSError(domain: "PaperGlide", code: 1, userInfo: [NSLocalizedDescriptionKey: "This PDF is locked, damaged, or has no pages."])
            }
            self.snapshot = snapshot
            self.document = pdf
        } catch {
            try? FileManager.default.removeItem(at: snapshot)
            throw error
        }
    }

    deinit { try? FileManager.default.removeItem(at: snapshot) }
}
