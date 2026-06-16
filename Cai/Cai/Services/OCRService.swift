import AppKit
import Vision

/// Extracts text from clipboard images using Apple's Vision framework (on-device OCR).
/// Uses the Neural Engine on Apple Silicon — fast (~50-200ms), no persistent RAM, no cloud.
class OCRService {
    static let shared = OCRService()
    private init() {}

    /// Attempts to read an image from the clipboard and extract text via Vision OCR.
    /// Returns the extracted text, or nil if no image is found or no text is recognized.
    /// Supports all image formats macOS handles: PNG, JPEG, TIFF, HEIC, BMP, GIF, WebP, etc.
    func extractTextFromClipboardImage() async -> String? {
        // Pasteboard read + Vision both run on PasteboardQueue: the read is
        // serialized off-main (no hang, no concurrent-reader crash), and OCR
        // only fires on a real clipboard change so the brief lane occupancy
        // (~50-200ms) is acceptable.
        await PasteboardQueue.shared.read {
            // NSImage(pasteboard:) handles all image formats macOS supports
            guard let image = NSImage(pasteboard: NSPasteboard.general),
                  let cgImage = self.cgImage(from: image) else {
                return nil
            }
            return self.performOCR(on: cgImage)
        }
    }

    /// Checks if the clipboard contains a file URL pointing to an image file (e.g. Finder copy).
    /// If so, loads the image and performs OCR. Returns nil if not an image file or no text found.
    func extractTextFromClipboardImageFile() async -> String? {
        await PasteboardQueue.shared.read {
            guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [
                NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true
            ]) as? [URL] else {
                return nil
            }

            let imageExtensions: Set<String> = [
                "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif", "webp"
            ]

            for url in urls {
                guard imageExtensions.contains(url.pathExtension.lowercased()),
                      let image = NSImage(contentsOf: url),
                      let cgImg = self.cgImage(from: image) else {
                    continue
                }

                #if DEBUG
                print("OCR: Loading image file: \(url.lastPathComponent)")
                #endif

                return self.performOCR(on: cgImg)
            }

            return nil
        }
    }

    /// Lightweight check: is there an image on the clipboard? (No OCR performed)
    /// Used for the "No text found in image" toast path.
    func hasImageOnClipboard() async -> Bool {
        await PasteboardQueue.shared.read { NSImage(pasteboard: NSPasteboard.general) != nil }
    }

    /// Lightweight check: is there an image file URL on the clipboard? (No OCR performed)
    func hasImageFileOnClipboard() async -> Bool {
        await PasteboardQueue.shared.read {
            guard let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [
                NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true
            ]) as? [URL] else {
                return false
            }

            let imageExtensions: Set<String> = [
                "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif", "webp"
            ]
            return urls.contains { imageExtensions.contains($0.pathExtension.lowercased()) }
        }
    }

    // MARK: - Private

    /// Runs VNRecognizeTextRequest on a CGImage.
    /// Returns concatenated recognized text, or nil if nothing was found.
    private func performOCR(on cgImage: CGImage) -> String? {
        var recognizedText: String?

        let request = VNRecognizeTextRequest { request, error in
            guard error == nil,
                  let observations = request.results as? [VNRecognizedTextObservation] else {
                return
            }

            let lines = observations.compactMap { observation in
                observation.topCandidates(1).first?.string
            }

            let joined = lines.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if !joined.isEmpty {
                recognizedText = joined
            }
        }

        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            print("OCR: Vision request failed: \(error.localizedDescription)")
        }

        #if DEBUG
        if let text = recognizedText {
            print("OCR: Extracted \(text.count) characters from clipboard image")
        } else {
            print("OCR: No text found in clipboard image")
        }
        #endif

        return recognizedText
    }

    /// Converts NSImage to CGImage for Vision processing.
    private func cgImage(from image: NSImage) -> CGImage? {
        guard let tiffData = image.tiffRepresentation,
              let imageSource = CGImageSourceCreateWithData(tiffData as CFData, nil),
              CGImageSourceGetCount(imageSource) > 0 else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}
