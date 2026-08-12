import QuickLook
import UIKit
import WebKit

@available(iOS 14.5, *)
final class DownloadManager: NSObject, WKDownloadDelegate {
    private let presenterProvider: () -> UIViewController?
    private var destinations: [ObjectIdentifier: URL] = [:]
    private var downloads: [ObjectIdentifier: WKDownload] = [:]
    private var previewURL: URL?

    init(presenterProvider: @escaping () -> UIViewController?) {
        self.presenterProvider = presenterProvider
    }

    func manage(_ download: WKDownload) {
        let identifier = ObjectIdentifier(download)
        downloads[identifier] = download
        download.delegate = self
    }

    func download(_ download: WKDownload,
                  decideDestinationUsing response: URLResponse,
                  suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        do {
            let directory = try downloadDirectory()
            let filename = safeFilename(suggestedFilename)
            let destination = uniqueDestination(directory: directory, filename: filename)
            destinations[ObjectIdentifier(download)] = destination
            completionHandler(destination)
        } catch {
            completionHandler(nil)
            finish(download)
            showFailure(message: "无法创建安全的下载目录。")
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        let destination = destinations[ObjectIdentifier(download)]
        finish(download)
        guard let url = destination else {
            showFailure(message: "下载已结束，但未找到文件。")
            return
        }
        presentCompletedDownload(url)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        finish(download)
        showFailure(message: "下载未完成，请重试或在 Safari 中继续。")
    }

    func numberOfPreviewItems(in controller: QLPreviewController) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
        previewURL! as NSURL
    }

    private func finish(_ download: WKDownload) {
        let identifier = ObjectIdentifier(download)
        downloads.removeValue(forKey: identifier)
        destinations.removeValue(forKey: identifier)
    }

    private func downloadDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let directory = base.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func safeFilename(_ value: String) -> String {
        let lastComponent = (value as NSString).lastPathComponent
        let forbidden = CharacterSet(charactersIn: "/\\:\0").union(.newlines).union(.controlCharacters)
        let cleaned = lastComponent.components(separatedBy: forbidden).joined(separator: "-")
        return cleaned.isEmpty ? "download" : String(cleaned.prefix(160))
    }

    private func uniqueDestination(directory: URL, filename: String) -> URL {
        let candidate = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: candidate.path) else { return candidate }
        let extensionName = candidate.pathExtension
        let baseName = candidate.deletingPathExtension().lastPathComponent
        for index in 2...999 {
            let numberedName = extensionName.isEmpty
                ? "\(baseName)-\(index)"
                : "\(baseName)-\(index).\(extensionName)"
            let numbered = directory.appendingPathComponent(numberedName)
            if !FileManager.default.fileExists(atPath: numbered.path) { return numbered }
        }
        return directory.appendingPathComponent(UUID().uuidString + (extensionName.isEmpty ? "" : ".\(extensionName)"))
    }

    private func presentCompletedDownload(_ url: URL) {
        guard let presenter = presenterProvider() else { return }
        let alert = UIAlertController(
            title: "下载完成",
            message: url.lastPathComponent,
            preferredStyle: .actionSheet
        )
        alert.addAction(UIAlertAction(title: "预览", style: .default) { [weak self] _ in
            guard let self = self, let presenter = self.presenterProvider() else { return }
            self.previewURL = url
            let preview = QLPreviewController()
            preview.dataSource = self
            presenter.present(preview, animated: true)
        })
        alert.addAction(UIAlertAction(title: "分享或存储到文件", style: .default) { [weak self] _ in
            guard let presenter = self?.presenterProvider() else { return }
            let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            activity.popoverPresentationController?.sourceView = presenter.view
            activity.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                                                          y: presenter.view.bounds.maxY - 24,
                                                                          width: 1,
                                                                          height: 1)
            presenter.present(activity, animated: true)
        })
        alert.addAction(UIAlertAction(title: "完成", style: .cancel))
        alert.popoverPresentationController?.sourceView = presenter.view
        alert.popoverPresentationController?.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                                                   y: presenter.view.bounds.maxY - 24,
                                                                   width: 1,
                                                                   height: 1)
        presenter.present(alert, animated: true)
    }

    private func showFailure(message: String) {
        guard let presenter = presenterProvider() else { return }
        let alert = UIAlertController(title: "下载失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "好", style: .default))
        presenter.present(alert, animated: true)
    }
}

@available(iOS 14.5, *)
extension DownloadManager: QLPreviewControllerDataSource {}
