// macOS only: swift scripts/create-demo-video.swift
// Generates a silent H.264 video for streaming/offline checks, without downloads.
import AVFoundation
import CoreGraphics
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("media")
let output = root.appendingPathComponent("Filme/Mediaserver Demo.mp4")
try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
if !FileManager.default.fileExists(atPath: output.path) {
    let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
    let settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 640, AVVideoHeightKey: 360]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    let attributes: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 640, kCVPixelBufferHeightKey as String: 360, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    writer.add(input)
    guard writer.startWriting() else { fatalError("Cannot create demo video") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<300 {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.005) }
        var optional: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 640, 360, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &optional)
        guard let buffer = optional else { fatalError("Pixel buffer failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        context.setFillColor(CGColor(red: 0.025, green: 0.07, blue: 0.11, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        context.setFillColor(CGColor(red: 0.3, green: 0.9, blue: 0.7, alpha: 1))
        context.fillEllipse(in: CGRect(x: 50 + frame % 250, y: 100, width: 130, height: 130))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else { fatalError("Video encoding failed") }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else { fatalError("Video failed: \(String(describing: writer.error))") }
}
let episode = root.appendingPathComponent("Serien/Mediaserver/Staffel 01/S01E01 - Erste Folge.mp4")
try FileManager.default.createDirectory(at: episode.deletingLastPathComponent(), withIntermediateDirectories: true)
if !FileManager.default.fileExists(atPath: episode.path) { try FileManager.default.copyItem(at: output, to: episode) }
print("Demo-Film und Serienfolge erstellt.")
