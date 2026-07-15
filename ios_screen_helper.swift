#!/usr/bin/swift
/**
 * USB iPhone/iPad screen capture for AVFoundation (same mechanism as QuickTime).
 * Stay running while capturing; read commands from stdin, write status to stdout.
 *
 * Commands:
 *   screenshot <path.png>
 *   record <path.mp4>
 *   stop
 *
 * Responses: ready:<name> | ok | recording | error:<message>
 */

import AVFoundation
import CoreMediaIO
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers

final class ScreenCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate,
    AVCaptureFileOutputRecordingDelegate
{
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "iphone-capture.frames")
    private var screenshotPath: String?
    private var screenshotDone: DispatchSemaphore?
    private var screenshotFailed = false
    private var latestSampleBuffer: CMSampleBuffer?
    private var recordingFinalPath: String?
    private var recordingTempPath: String?
    private var isRecording = false
    private var finishRecordingSem: DispatchSemaphore?
    private var finishRecordingError: String?

    func start(device: AVCaptureDevice) throws {
        self.device = device
        session.beginConfiguration()
        session.sessionPreset = .high

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "ScreenCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Cannot open device input",
            ])
        }
        session.addInput(input)

        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        guard session.canAddOutput(videoOutput) else {
            throw NSError(domain: "ScreenCapture", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add video output",
            ])
        }
        session.addOutput(videoOutput)

        guard session.canAddOutput(movieOutput) else {
            throw NSError(domain: "ScreenCapture", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "Cannot add movie output",
            ])
        }
        session.addOutput(movieOutput)

        session.commitConfiguration()
        session.startRunning()

        // Drop stale frames from session startup
        Thread.sleep(forTimeInterval: 0.5)
    }

    func stopSession() {
        if isRecording {
            try? stopRecording()
        }
        session.stopRunning()
    }

    private func storeLatestFrame(_ sampleBuffer: CMSampleBuffer) {
        var copy: CMSampleBuffer?
        CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy
        )
        if let copy {
            latestSampleBuffer = copy
        }
    }

    func takeScreenshot(path: String) throws {
        guard !isRecording else {
            throw NSError(domain: "ScreenCapture", code: 4, userInfo: [
                NSLocalizedDescriptionKey: "Cannot screenshot while recording",
            ])
        }

        var immediateError: String?
        queue.sync {
            if let buffer = self.latestSampleBuffer {
                if self.writePNG(from: buffer, to: path) {
                    return
                }
                immediateError = "Failed to write screenshot"
            }
        }
        if immediateError != nil {
            throw NSError(domain: "ScreenCapture", code: 8, userInfo: [
                NSLocalizedDescriptionKey: immediateError!,
            ])
        }

        // No cached frame yet — wait for the next one from the device.
        let sem = DispatchSemaphore(value: 0)
        queue.async {
            self.screenshotFailed = false
            self.screenshotPath = path
            self.screenshotDone = sem
        }
        guard sem.wait(timeout: .now() + 10) == .success else {
            queue.async {
                self.screenshotPath = nil
                self.screenshotDone = nil
            }
            throw NSError(domain: "ScreenCapture", code: 5, userInfo: [
                NSLocalizedDescriptionKey: "Screenshot timed out — unlock iPhone or tap the screen",
            ])
        }
        var failed = false
        queue.sync { failed = self.screenshotFailed }
        if failed {
            throw NSError(domain: "ScreenCapture", code: 8, userInfo: [
                NSLocalizedDescriptionKey: "Failed to write screenshot",
            ])
        }
    }

    func startRecording(path: String) throws {
        guard !isRecording else { return }
        guard let connection = movieOutput.connection(with: .video), connection.isActive else {
            throw NSError(domain: "ScreenCapture", code: 13, userInfo: [
                NSLocalizedDescriptionKey: "No active video connection for recording",
            ])
        }

        let tempPath = path + ".recording.mov"
        try? FileManager.default.removeItem(atPath: path)
        try? FileManager.default.removeItem(atPath: tempPath)

        recordingFinalPath = path
        recordingTempPath = tempPath
        isRecording = true
        finishRecordingError = nil

        movieOutput.startRecording(to: URL(fileURLWithPath: tempPath), recordingDelegate: self)
    }

    func stopRecording() throws {
        guard isRecording else { return }
        isRecording = false

        guard let finalPath = recordingFinalPath, let tempPath = recordingTempPath else { return }

        let sem = DispatchSemaphore(value: 0)
        finishRecordingSem = sem
        finishRecordingError = nil
        if movieOutput.isRecording {
            movieOutput.stopRecording()
            if sem.wait(timeout: .now() + 15) == .timedOut {
                throw NSError(domain: "ScreenCapture", code: 6, userInfo: [
                    NSLocalizedDescriptionKey: "Recording stop timed out",
                ])
            }
        } else {
            // USB screen devices may clear isRecording before stop; finalize if possible.
            movieOutput.stopRecording()
            _ = sem.wait(timeout: .now() + 2)
        }
        if let finishRecordingError {
            throw NSError(domain: "ScreenCapture", code: 7, userInfo: [
                NSLocalizedDescriptionKey: finishRecordingError,
            ])
        }

        defer {
            recordingFinalPath = nil
            recordingTempPath = nil
            finishRecordingSem = nil
        }

        guard FileManager.default.fileExists(atPath: tempPath) else {
            throw NSError(domain: "ScreenCapture", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "No recording file created — click Refresh and try again",
            ])
        }

        let attrs = try? FileManager.default.attributesOfItem(atPath: tempPath)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size < 1024 {
            try? FileManager.default.removeItem(atPath: tempPath)
            throw NSError(domain: "ScreenCapture", code: 7, userInfo: [
                NSLocalizedDescriptionKey: "Recording was empty — unlock iPhone and try again",
            ])
        }

        do {
            try exportWebVideo(
                from: URL(fileURLWithPath: tempPath),
                to: URL(fileURLWithPath: finalPath)
            )
        } catch {
            throw NSError(domain: "ScreenCapture", code: 9, userInfo: [
                NSLocalizedDescriptionKey: "Video export failed: \(error.localizedDescription)",
            ])
        }

        try? FileManager.default.removeItem(atPath: tempPath)
    }

    func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        if let error = error as NSError? {
            if error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true {
                finishRecordingError = nil
            } else {
                finishRecordingError = error.localizedDescription
            }
        } else {
            finishRecordingError = nil
        }
        finishRecordingSem?.signal()
    }

    private func writePNG(from sampleBuffer: CMSampleBuffer, to path: String) -> Bool {
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return false }
        CVPixelBufferLockBaseAddress(imageBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(imageBuffer, .readOnly) }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        guard let base = CVPixelBufferGetBaseAddress(imageBuffer) else { return false }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ),
            let cgImage = context.makeImage()
        else { return false }

        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, cgImage, nil)
        return CGImageDestinationFinalize(dest)
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        storeLatestFrame(sampleBuffer)

        guard let path = screenshotPath else { return }
        let saved = writePNG(from: sampleBuffer, to: path)
        if !saved {
            screenshotFailed = true
        }
        screenshotPath = nil
        screenshotDone?.signal()
        screenshotDone = nil
    }
}

func videoRenderSize(for track: AVAssetTrack) -> CGSize {
    let transformed = track.naturalSize.applying(track.preferredTransform)
    return CGSize(width: abs(transformed.width), height: abs(transformed.height))
}

func exportWebVideo(from source: URL, to destination: URL) throws {
    let asset = AVURLAsset(url: source)
    guard let videoTrack = asset.tracks(withMediaType: .video).first else {
        throw NSError(domain: "ScreenCapture", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "No video track found in recording",
        ])
    }

    let renderSize = videoRenderSize(for: videoTrack)
    let composition = AVMutableVideoComposition()
    composition.renderSize = renderSize
    composition.frameDuration = CMTime(value: 1, timescale: 30)

    let instruction = AVMutableVideoCompositionInstruction()
    instruction.timeRange = CMTimeRange(start: .zero, duration: asset.duration)

    let layerInstruction = AVMutableVideoCompositionLayerInstruction(assetTrack: videoTrack)
    layerInstruction.setTransform(videoTrack.preferredTransform, at: .zero)
    instruction.layerInstructions = [layerInstruction]
    composition.instructions = [instruction]

    guard let exporter = AVAssetExportSession(
        asset: asset,
        presetName: AVAssetExportPresetHighestQuality
    ) else {
        throw NSError(domain: "ScreenCapture", code: 10, userInfo: [
            NSLocalizedDescriptionKey: "Cannot create video exporter",
        ])
    }

    try? FileManager.default.removeItem(at: destination)
    exporter.outputURL = destination
    exporter.outputFileType = .mp4
    exporter.shouldOptimizeForNetworkUse = true
    exporter.videoComposition = composition

    let sem = DispatchSemaphore(value: 0)
    var failed = false
    var failureMessage = "Video export failed"
    exporter.exportAsynchronously {
        if exporter.status != .completed {
            failed = true
            failureMessage = exporter.error?.localizedDescription ?? failureMessage
        }
        sem.signal()
    }
    sem.wait()
    if failed {
        throw NSError(domain: "ScreenCapture", code: 11, userInfo: [
            NSLocalizedDescriptionKey: failureMessage,
        ])
    }
}

func allowScreenCaptureDevices() {
    let element: CMIOObjectPropertyElement
    if #available(macOS 12.0, *) {
        element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    } else {
        element = CMIOObjectPropertyElement(kCMIOObjectPropertyElementMaster)
    }
    var prop = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyAllowScreenCaptureDevices),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
        mElement: element
    )
    var allow: UInt32 = 1
    CMIOObjectSetPropertyData(
        CMIOObjectID(kCMIOObjectSystemObject),
        &prop,
        0,
        nil,
        UInt32(MemoryLayout<UInt32>.size),
        &allow
    )
}

func externalDeviceTypes() -> [AVCaptureDevice.DeviceType] {
    if #available(macOS 14.0, *) {
        return [.external, .externalUnknown]
    }
    return [.external]
}

func isScreenMirror(_ device: AVCaptureDevice) -> Bool {
    let name = device.localizedName.lowercased()
    if name.contains("virtual") || name.contains("obs") {
        return false
    }
    if name.contains("camera") || name.contains("desk view") || name.contains("microphone") {
        return false
    }
    return true
}

func findScreenDevice(timeout: TimeInterval) -> AVCaptureDevice? {
    let _ = AVCaptureDevice.DiscoverySession(
        deviceTypes: [.builtInWideAngleCamera],
        mediaType: .video,
        position: .unspecified
    ).devices
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: externalDeviceTypes(),
            mediaType: .muxed,
            position: .unspecified
        )
        for device in session.devices where isScreenMirror(device) {
            return device
        }
        Thread.sleep(forTimeInterval: 0.25)
    }
    return nil
}

func reply(_ message: String) {
    print(message)
    fflush(stdout)
}

allowScreenCaptureDevices()

guard let device = findScreenDevice(timeout: 10) else {
    reply("error:no USB iPhone screen mirror found — connect via USB and trust this Mac")
    exit(1)
}

let capture = ScreenCapture()
do {
    try capture.start(device: device)
} catch {
    reply("error:\(error.localizedDescription)")
    exit(1)
}

reply("ready:\(device.localizedName)")

while let line = readLine(strippingNewline: true) {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { continue }

    let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
    let command = parts[0].lowercased()
    let argument = parts.count > 1 ? parts[1] : ""

    do {
        switch command {
        case "screenshot":
            guard !argument.isEmpty else {
                reply("error:screenshot requires a file path")
                continue
            }
            try capture.takeScreenshot(path: argument)
            reply("ok")
        case "record":
            guard !argument.isEmpty else {
                reply("error:record requires a file path")
                continue
            }
            try capture.startRecording(path: argument)
            reply("recording")
        case "stop":
            try capture.stopRecording()
            reply("ok")
        case "quit":
            capture.stopSession()
            exit(0)
        default:
            reply("error:unknown command")
        }
    } catch {
        reply("error:\(error.localizedDescription)")
    }
}

capture.stopSession()
