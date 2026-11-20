#if DEBUG
import UIKit

enum DemoPapers {
    // Accessible only when the UI test runner supplies its explicit launch argument.
    static func folder() throws -> Folder {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(ProcessInfo.processInfo.arguments.contains("-ink-fixtures") ? "Ink Test Papers" : "Gesture Test Papers", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for number in 1...5 {
            let file = root.appendingPathComponent("Paper \(number).pdf")
            defer {
                if ProcessInfo.processInfo.arguments.contains("-ink-fixtures") {
                    try? FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_730_000_000 + Double(number) * 86_400)], ofItemAtPath: file.path)
                }
            }
            guard !FileManager.default.fileExists(atPath: file.path) else { continue }
            let format = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
            try format.writePDF(to: file) { context in
                for page in 1...10 {
                    context.beginPage()
                    let title = "Paper \(number) · Page \(page)" as NSString
                    title.draw(at: CGPoint(x: 52, y: 54), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 24)])
                    for row in 0..<20 {
                        let line = "Reading position sample — line \(row + 1)" as NSString
                        line.draw(at: CGPoint(x: 52, y: 110 + row * 28), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
                    }
                }
            }
        }
        return Folder(root)
    }
}
#endif
