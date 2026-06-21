import AppKit
import Vision

/// Extracts text from clipboard images using Apple's Vision framework (on-device OCR).
/// Uses the Neural Engine on Apple Silicon — fast (~50-200ms), no persistent RAM, no cloud.
class OCRService {
    static let shared = OCRService()
    private init() {}

    /// Image file extensions OCR can load. Single source of truth, shared with the
    /// clipboard reader's file-URL filter (`ClipboardService.readClipboardContent`).
    static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "tiff", "tif", "heic", "heif", "bmp", "gif", "webp"
    ]

    /// OCRs the first loadable image file in `urls`, returning its recognized text
    /// (or nil if none qualify or no text is found). Pure CPU + disk work, no
    /// pasteboard access — run it OFF the PasteboardQueue lane after the URLs have
    /// been captured, so Vision/disk I/O don't occupy the shared lane.
    func ocrImageFiles(_ urls: [URL]) -> String? {
        for url in urls {
            guard Self.imageExtensions.contains(url.pathExtension.lowercased()),
                  let image = NSImage(contentsOf: url),
                  let cgImg = cgImage(from: image) else {
                continue
            }

            #if DEBUG
            print("OCR: Loading image file: \(url.lastPathComponent)")
            #endif

            return performOCR(on: cgImg)
        }
        return nil
    }

    /// OCRs an already-captured image. Pure CPU work, no pasteboard access — run
    /// it OFF the PasteboardQueue lane.
    func ocrImage(_ image: NSImage) -> String? {
        guard let cgImage = cgImage(from: image) else { return nil }
        return performOCR(on: cgImage)
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
