import Foundation

/// Downloads GGUF model files from Hugging Face with progress tracking,
/// resume support, and cancellation.
class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    /// Shared instance — survives window close so downloads continue in background.
    static let shared = ModelDownloader()

    @Published var progress: Double = 0          // 0.0 to 1.0
    @Published var downloadedBytes: Int64 = 0
    @Published var totalBytes: Int64 = 0
    @Published var isDownloading: Bool = false
    @Published var error: String?

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?
    private var destinationURL: URL?
    private var continuation: CheckedContinuation<URL, Error>?

    // MARK: - Default Model

    /// The recommended model shipped with Cai's built-in LLM
    static let defaultModel = ModelInfo(
        name: "Ministral 3B",
        fileName: "Ministral-3-3B-Instruct-2512-Q4_K_M.gguf",
        downloadURL: URL(string: "https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512-GGUF/resolve/main/Ministral-3-3B-Instruct-2512-Q4_K_M.gguf")!,
        sizeBytes: 2_310_000_000, // ~2.15 GB
        description: "Fast, concise output. Recommended for clipboard actions."
    )

    // MARK: - Download

    /// Downloads a model file to the Cai models directory.
    /// Returns the local file path on success.
    func download(model: ModelInfo) async throws -> URL {
        // Create models directory
        let modelsDir = BuiltInLLM.modelsDirectory
        try FileManager.default.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let destination = modelsDir.appendingPathComponent(model.fileName)
        let partFile = modelsDir.appendingPathComponent(model.fileName + ".part")

        // If the file already exists and is roughly the right size, skip download
        if FileManager.default.fileExists(atPath: destination.path) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: destination.path)
            let fileSize = attrs?[.size] as? Int64 ?? 0
            if fileSize > model.sizeBytes / 2 { // sanity check — at least half expected size
                return destination
            }
        }

        // Check available disk space (need model size + 500MB buffer)
        let requiredSpace = model.sizeBytes + 500_000_000
        if let availableSpace = availableDiskSpace(), availableSpace < requiredSpace {
            throw ModelDownloadError.insufficientDiskSpace(
                needed: model.sizeBytes,
                available: availableSpace
            )
        }

        await MainActor.run {
            self.isDownloading = true
            self.progress = 0
            self.downloadedBytes = 0
            self.totalBytes = model.sizeBytes
            self.error = nil
        }

        self.destinationURL = destination

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation

            let config = URLSessionConfiguration.default
            config.timeoutIntervalForResource = 3600 // 1 hour max
            self.session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

            var request = URLRequest(url: model.downloadURL)

            // Resume support — check for partial download
            if FileManager.default.fileExists(atPath: partFile.path),
               let attrs = try? FileManager.default.attributesOfItem(atPath: partFile.path),
               let existingSize = attrs[.size] as? Int64, existingSize > 0 {
                request.setValue("bytes=\(existingSize)-", forHTTPHeaderField: "Range")
                Task { @MainActor in
                    self.downloadedBytes = existingSize
                    self.progress = Double(existingSize) / Double(model.sizeBytes)
                }
                print("⬇️ Resuming download from byte \(existingSize)")
            }

            self.downloadTask = session?.downloadTask(with: request)
            self.downloadTask?.resume()
        }
    }

    /// Cancels the active download and cleans up the partial file.
    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        session?.invalidateAndCancel()
        session = nil

        Task { @MainActor in
            self.isDownloading = false
            self.progress = 0
        }

        continuation?.resume(throwing: ModelDownloadError.cancelled)
        continuation = nil
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : self.totalBytes
        Task { @MainActor in
            self.downloadedBytes = totalBytesWritten
            if total > 0 {
                self.totalBytes = total
                self.progress = Double(totalBytesWritten) / Double(total)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard let destination = destinationURL else {
            continuation?.resume(throwing: ModelDownloadError.saveFailed)
            continuation = nil
            return
        }

        do {
            // Remove any existing file
            try? FileManager.default.removeItem(at: destination)
            // Remove partial file
            let partFile = destination.appendingPathExtension("part")
            try? FileManager.default.removeItem(at: partFile)
            // Move downloaded file to final destination
            try FileManager.default.moveItem(at: location, to: destination)

            print("⬇️ Model downloaded to \(destination.path)")

            Task { @MainActor in
                self.isDownloading = false
                self.progress = 1.0
            }

            continuation?.resume(returning: destination)
            continuation = nil
        } catch {
            continuation?.resume(throwing: ModelDownloadError.saveFailed)
            continuation = nil
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        guard let error = error else { return } // success handled in didFinishDownloadingTo

        // Don't report cancellation as an error
        if (error as NSError).code == NSURLErrorCancelled {
            return
        }

        Task { @MainActor in
            self.isDownloading = false
            self.error = error.localizedDescription
        }

        continuation?.resume(throwing: ModelDownloadError.networkError(error.localizedDescription))
        continuation = nil
    }

    // MARK: - Private

    private func availableDiskSpace() -> Int64? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: home.path),
              let freeSpace = attrs[.systemFreeSize] as? Int64 else {
            return nil
        }
        return freeSpace
    }
}

// MARK: - Model Info

struct ModelInfo {
    let name: String
    let fileName: String
    let downloadURL: URL
    let sizeBytes: Int64
    let description: String

    /// Human-readable file size (e.g. "2.15 GB")
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

// MARK: - Errors

enum ModelDownloadError: LocalizedError {
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case networkError(String)
    case saveFailed
    case cancelled

    var errorDescription: String? {
        switch self {
        case .insufficientDiskSpace(let needed, let available):
            let neededStr = ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)
            let availStr = ByteCountFormatter.string(fromByteCount: available, countStyle: .file)
            return "Not enough disk space. Need \(neededStr), only \(availStr) available."
        case .networkError(let message):
            return "Download failed: \(message)"
        case .saveFailed:
            return "Failed to save model file."
        case .cancelled:
            return "Download cancelled."
        }
    }
}
