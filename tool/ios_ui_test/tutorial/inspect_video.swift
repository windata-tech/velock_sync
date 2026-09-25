import Foundation
import AVFoundation
import AppKit

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let asset = AVURLAsset(url: url)
let duration = try await asset.load(.duration).seconds
let tracks = try await asset.loadTracks(withMediaType: .video)
guard let track = tracks.first else { fatalError("No video track") }
let size = try await track.load(.naturalSize)
print("VIDEO duration=\(duration) dimensions=\(size.width)x\(size.height)")
let generator = AVAssetImageGenerator(asset: asset)
generator.appliesPreferredTrackTransform = true
generator.requestedTimeToleranceBefore = .zero
generator.requestedTimeToleranceAfter = .zero
generator.maximumSize = CGSize(width: 440, height: 960)
for (index, fraction) in [0.02, 0.2, 0.4, 0.6, 0.8, 0.999].enumerated() {
    let time = CMTime(seconds: duration * fraction, preferredTimescale: 600)
    let result = try await generator.image(at: time)
    let png = NSBitmapImageRep(cgImage: result.image).representation(using: .png, properties: [:])!
    try png.write(to: output.appendingPathComponent("frame-\(index).png"))
}
