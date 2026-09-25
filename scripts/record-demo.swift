// Records the island window while `MeetingGuru --demo-tour` plays, as numbered PNG frames
// with transparency. Usage: swift scripts/record-demo.swift <MeetingGuru binary> <frames dir> [fps]
// Needs Screen Recording permission for the terminal that runs it.
import AppKit
import CoreImage
import ScreenCaptureKit
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: record-demo.swift <binary> <frames dir> [fps]\n".utf8))
    exit(2)
}
let binary = URL(fileURLWithPath: arguments[1])
let output = URL(fileURLWithPath: arguments[2], isDirectory: true)
let fps = arguments.count > 3 ? Double(arguments[3]) ?? 25 : 25
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

final class Sampler: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CGImage?
    private let context = CIContext()

    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let pixels = buffer.imageBuffer else { return }
        let image = CIImage(cvPixelBuffer: pixels)
        guard let cgImage = context.createCGImage(image, from: image.extent) else { return }
        lock.withLock { latest = cgImage }
    }

    var frame: CGImage? { lock.withLock { latest } }
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let app = Process()
app.executableURL = binary
app.arguments = ["--demo-tour"]
try app.run()

var island: SCWindow?
for _ in 0..<100 where island == nil {
    try await Task.sleep(for: .milliseconds(100))
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    island = content.windows.first { $0.owningApplication?.processID == app.processIdentifier && $0.frame.width > 100 }
}
guard let island else {
    app.terminate()
    FileHandle.standardError.write(Data("island window not found (Screen Recording permission?)\n".utf8))
    exit(1)
}

let scale = NSScreen.main?.backingScaleFactor ?? 2
let configuration = SCStreamConfiguration()
configuration.width = Int(island.frame.width * scale)
configuration.height = Int(island.frame.height * scale)
configuration.minimumFrameInterval = CMTime(value: 1, timescale: 60)
configuration.pixelFormat = kCVPixelFormatType_32BGRA
configuration.showsCursor = false
configuration.shouldBeOpaque = false
configuration.ignoreShadowsSingleWindow = true
configuration.backgroundColor = .clear

let sampler = Sampler()
let stream = SCStream(filter: SCContentFilter(desktopIndependentWindow: island), configuration: configuration, delegate: nil)
try stream.addStreamOutput(sampler, type: .screen, sampleHandlerQueue: DispatchQueue(label: "frames"))
try await stream.startCapture()

// Frames are numbered by wall-clock time so the recording plays back at real speed.
let started = Date()
var index = 0
while app.isRunning {
    if let frame = sampler.frame {
        let due = Int(Date().timeIntervalSince(started) * fps)
        let first = output.appendingPathComponent(String(format: "%05d.png", index))
        write(frame, to: first)
        index += 1
        while index <= due {
            try? FileManager.default.copyItem(at: first, to: output.appendingPathComponent(String(format: "%05d.png", index)))
            index += 1
        }
    }
    try await Task.sleep(for: .seconds(1 / fps))
}
try? await stream.stopCapture()
print("\(index) frames in \(output.path)")
