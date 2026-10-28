import AppKit
import ScreenCaptureKit
import CoreImage

struct CapturedFrame {
    let jpeg: Data
    let width: Int
    let height: Int
    var encodingMilliseconds: Double = 0
}

final class ScreenCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "boox.capture", qos: .userInitiated)
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var maxWidth = 1600
    private var grayscale = true
    private var jpegQuality = 0.70
    var onFrame: ((CapturedFrame) -> Void)?
    var onError: ((String) -> Void)?

    func start(displayID: CGDirectDisplayID, fps: Int, maxWidth: Int, grayscale: Bool, jpegQuality: Double = 0.70) async throws {
        self.maxWidth = maxWidth
        self.grayscale = grayscale
        self.jpegQuality = jpegQuality
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw NSError(domain: "BooxSidecar", code: 1, userInfo: [NSLocalizedDescriptionKey: "Selected display is no longer connected."])
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        // SCDisplay dimensions may be logical points on a HiDPI desktop.
        // Respect the underlying mode so the full 2480×1860 option is available.
        let mode = CGDisplayCopyDisplayMode(displayID)
        let pixelWidth = mode?.pixelWidth ?? display.width
        let pixelHeight = mode?.pixelHeight ?? display.height
        let scale = min(1.0, Double(maxWidth) / Double(pixelWidth))
        config.width = max(2, Int(Double(pixelWidth) * scale))
        config.height = max(2, Int(Double(pixelHeight) * scale))
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = 3
        config.showsCursor = true
        config.capturesAudio = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        self.stream = stream
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        stream = nil
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) { onError?(error.localizedDescription) }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        autoreleasepool {
            let encodingStart = CFAbsoluteTimeGetCurrent()
            var image = CIImage(cvPixelBuffer: buffer)
            if image.extent.width > CGFloat(maxWidth) {
                let scale = CGFloat(maxWidth) / image.extent.width
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
            if grayscale { image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]) }
            guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpaceCreateDeviceRGB(), options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: jpegQuality]) else { return }
            onFrame?(CapturedFrame(jpeg: jpeg, width: Int(image.extent.width), height: Int(image.extent.height), encodingMilliseconds: (CFAbsoluteTimeGetCurrent() - encodingStart) * 1000))
        }
    }
}
