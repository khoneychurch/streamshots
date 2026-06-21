#!/usr/bin/swift
/**
 * USB iPhone/iPad screen capture for AVFoundation (same mechanism as QuickTime).
 * Stay running while capturing; read commands from stdin, write status to stdout.
 *
 * Commands:
 *   screenshot <path.png>
 *   record <path.mov>
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

final class ScreenCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate
{
    private let session = AVCaptureSession()
    private var device: AVCaptureDevice?
    private let videoOutput = AVCaptureVideoDataOutput()
    private let queue = DispatchQueue(label: "iphone-capture.frames")
    private var screenshotPath: String?
    private var screenshotDone: DispatchSemaphore?
    private var screenshotFailed = false
    private var latestSampleBuffer: CMSampleBuffer?
    private var assetWriter: AVAssetWriter?
    private var writerInput: AVAssetWriterInput?
    private var recordingPath: String?
    private var recordingActive = false

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

        session.commitConfiguration()
        session.startRunning()

        // Drop stale frames from session startup
        Thread.sleep(forTimeInterval: 0.5)
    }

    func stopSession() {
        if recordingActive {
            try? stopRecording()
        }
        session.stopRunning()
    }

    func takeScreenshot(path: String) throws {
        guard !recordingActive else {
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
        guard !recordingActive else { return }
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        recordingPath = path
        recordingActive = true
        assetWriter = nil
        writerInput = nil
    }

    func stopRecording() throws {
        guard recordingActive else { return }
        recordingActive = false
        var writeError: String?

        queue.sync {
            guard let writer = self.assetWriter else {
                writeError = "No frames captured"
                return
            }
            self.writerInput?.markAsFinished()
            let group = DispatchGroup()
            group.enter()
            writer.finishWriting {
                if writer.status == .failed {
                    writeError = writer.error?.localizedDescription ?? "Writer failed"
                }
                group.leave()
            }
            group.wait()
            self.assetWriter = nil
            self.writerInput = nil
        }

        recordingPath = nil
        if let writeError {
            throw NSError(domain: "ScreenCapture", code: 7, userInfo: [
                NSLocalizedDescriptionKey: writeError,
            ])
        }
    }

    private func startWriterIfNeeded(from sampleBuffer: CMSampleBuffer) {
        guard recordingActive, assetWriter == nil, let path = recordingPath else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let width = CVPixelBufferGetWidth(imageBuffer)
        let height = CVPixelBufferGetHeight(imageBuffer)
        let url = URL(fileURLWithPath: path)

        do {
            let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
            let settings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width,
                AVVideoHeightKey: height,
            ]
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { return }
            writer.add(input)
            guard writer.startWriting() else {
                recordingActive = false
                return
            }
            writer.startSession(atSourceTime: CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            assetWriter = writer
            writerInput = input
        } catch {
            recordingActive = false
        }
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
        latestSampleBuffer = sampleBuffer

        if recordingActive {
            startWriterIfNeeded(from: sampleBuffer)
            if let input = writerInput, input.isReadyForMoreMediaData {
                input.append(sampleBuffer)
            }
        }

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
