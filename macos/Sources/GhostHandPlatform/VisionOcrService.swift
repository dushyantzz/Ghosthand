import CoreGraphics
import Foundation
import GhostHandCore
import ScreenCaptureKit
import Vision

// MARK: - VisionOcrService
//
// macOS port of GhostHand.Platform.ScreenReading.WindowsOcrService.
//
// Instead of Windows.Media.Ocr this uses Vision's `VNRecognizeTextRequest` in accurate
// mode with language correction. Each recognized line becomes one AccessibilityElement
// with role "Text", source "ocr" and sanitized text in `label` (matching the Windows
// service, which also emits one element per OCR line).
//
// Frames are reported in screen coordinates with a top-left origin, consistent with the
// rest of the Swift model. Vision returns normalized coordinates with a bottom-left
// origin, so the y axis is flipped while mapping into the captured rectangle.

/// OCR fallback backed by Apple's Vision framework.
public final class VisionOcrService: OcrService, @unchecked Sendable {

    /// BCP-47 language identifiers (e.g. `["en-US", "de-DE"]`). Empty means Vision's default.
    public let languages: [String]

    /// Upper bound on emitted elements, mirroring the old Swift reference implementation.
    private static let maximumObservations = 500

    public init(languages: [String] = []) {
        self.languages = languages
    }

    // MARK: - OcrService

    /// Recognizes text inside `bounds` (screen coordinates, top-left origin).
    /// Never throws: capture/OCR failures are logged and `[]` is returned.
    public func recognizeScreenArea(_ bounds: CGRect) async -> [AccessibilityElement] {
        let rect = bounds.standardized
        guard rect.width >= 1, rect.height >= 1 else { return [] }

        guard let image = await Self.captureScreenArea(rect) else {
            GhostLog.shared.warning(
                "VisionOcrService: screen capture unavailable for \(Int(rect.width))x\(Int(rect.height)) "
                    + "at (\(Int(rect.minX)), \(Int(rect.minY))). Grant Screen Recording permission to enable OCR."
            )
            return []
        }

        do {
            return try await Self.recognize(image: image, screenBounds: rect, languages: languages)
        } catch {
            GhostLog.shared.warning("VisionOcrService: OCR failed: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - Capture

    /// Captures the on-screen content of `rect` via ScreenCaptureKit, falling back to a
    /// main-display capture. Returns nil when no image can be obtained.
    private static func captureScreenArea(_ rect: CGRect) async -> CGImage? {
        if let image = await captureWithScreenCaptureKit(rect) {
            GhostLog.shared.debug(
                "VisionOcrService: captured \(Int(rect.width))x\(Int(rect.height)) via ScreenCaptureKit"
            )
            return image
        }

        GhostLog.shared.debug("VisionOcrService: ScreenCaptureKit unavailable; trying CGDisplayCreateImage.")
        if let image = CGDisplayCreateImage(CGMainDisplayID(), rect: rect) {
            return image
        }

        return nil
    }

    /// `SCScreenshotManager` is macOS 14's replacement for the deprecated
    /// `CGWindowListCreateImage`. It needs Screen Recording permission; a failure here is
    /// expected (and handled by the fallback) when that permission has not been granted.
    private static func captureWithScreenCaptureKit(_ rect: CGRect) async -> CGImage? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
            guard let display = content.displays.first(where: { $0.frame.intersects(rect) })
                ?? content.displays.first else { return nil }

            // `sourceRect` is display-local (points) and must lie inside the display; the target
            // bounds are global screen coordinates.
            let local = CGRect(
                x: rect.minX - display.frame.minX,
                y: rect.minY - display.frame.minY,
                width: rect.width,
                height: rect.height
            ).intersection(CGRect(origin: .zero, size: display.frame.size))
            guard local.width >= 1, local.height >= 1 else { return nil }

            // Output dimensions are pixels, so scale the point-sized rect by the display factor.
            let scale = display.frame.width > 0 ? CGFloat(display.width) / display.frame.width : 1
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.sourceRect = local
            configuration.width = max(1, Int(local.width * scale))
            configuration.height = max(1, Int(local.height * scale))
            configuration.showsCursor = false

            return try await SCScreenshotManager.captureImage(
                contentFilter: filter,
                configuration: configuration
            )
        } catch {
            GhostLog.shared.debug(
                "VisionOcrService: ScreenCaptureKit capture failed (rect=\(rect), error=\(error))"
            )
            return nil
        }
    }

    // MARK: - Recognition

    private static func recognize(
        image: CGImage,
        screenBounds: CGRect,
        languages: [String]
    ) async throws -> [AccessibilityElement] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                if !languages.isEmpty {
                    request.recognitionLanguages = languages
                }

                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                do {
                    try handler.perform([request])
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                guard let observations = request.results else {
                    continuation.resume(returning: [])
                    return
                }

                var elements: [AccessibilityElement] = []
                var index = 1

                for observation in observations.prefix(maximumObservations) {
                    guard let candidate = observation.topCandidates(1).first else { continue }
                    let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }

                    // Vision boxes are normalized with a bottom-left origin; flip y so the
                    // emitted frame uses the model's top-left screen coordinate space.
                    let box = observation.boundingBox
                    let frame = CGRect(
                        x: screenBounds.minX + box.minX * screenBounds.width,
                        y: screenBounds.minY + (1 - box.maxY) * screenBounds.height,
                        width: box.width * screenBounds.width,
                        height: box.height * screenBounds.height
                    )

                    elements.append(
                        AccessibilityElement(
                            id: "ocr_\(index)",
                            role: "Text",
                            label: SecretSanitizer.sanitize(text, isPassword: false),
                            frame: frame,
                            source: "ocr"
                        )
                    )
                    index += 1
                }

                GhostLog.shared.debug("VisionOcrService: \(elements.count) OCR line(s) recognized.")
                continuation.resume(returning: elements)
            }
        }
    }
}
