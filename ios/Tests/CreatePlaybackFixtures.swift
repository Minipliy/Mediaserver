// macOS fixture generator for scripts/check-ios-playback.sh.
// Creates small, self-contained H.264 files without external encoders or user media.
import AVFoundation
import Foundation

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
for (suffix, type) in [("mov", AVFileType.mov), ("mp4", AVFileType.mp4)] {
    let output = destination.appendingPathComponent("sample." + suffix)
    let writer = try AVAssetWriter(outputURL: output, fileType: type)
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90
    ])
    let attributes: [String: Any] = [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90
    ]
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: attributes)
    writer.add(input)
    guard writer.startWriting() else { fatalError("Fixture writer did not start: \(String(describing: writer.error))") }
    writer.startSession(atSourceTime: .zero)
    for frame in 0..<60 {
        while !input.isReadyForMoreMediaData {
            guard writer.status == .writing else { fatalError("Fixture writer failed") }
            Thread.sleep(forTimeInterval: 0.005)
        }
        var optional: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32ARGB, attributes as CFDictionary, &optional)
        guard let buffer = optional else { fatalError("Fixture pixel buffer failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), Int32(frame * 3), CVPixelBufferGetBytesPerRow(buffer) * CVPixelBufferGetHeight(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
            fatalError("Fixture frame encoding failed")
        }
    }
    input.markAsFinished()
    let completion = DispatchSemaphore(value: 0)
    writer.finishWriting { completion.signal() }
    completion.wait()
    guard writer.status == .completed else { fatalError("Fixture encoding failed: \(String(describing: writer.error))") }
}
