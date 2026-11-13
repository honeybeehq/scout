import AVFoundation
import ScoutCore
import SwiftUI

enum DemoScreenVideo {
    static let size = CGSize(width: 1920, height: 1200)
    static let framesPerSecond: Int32 = 30

    static let secretPanel = Rect(x: 0.638, y: 0.308, width: 0.258, height: 0.068)
    static let toast = Rect(x: 0.618, y: 0.073, width: 0.346, height: 0.152)
    static let toastRange = TimeRange(start: 1.5, end: 5.2)
    static let popupRange = TimeRange(start: 6.0, end: 7.6)

    static var redaction: ClipRedaction {
        ClipRedaction(
            excluded: [popupRange],
            regions: [
                RedactedRegion(id: "demo-secret-panel", rect: secretPanel),
                RedactedRegion(id: "demo-toast", rect: toast, range: toastRange),
            ]
        )
    }

    @MainActor
    static func make(to url: URL, seconds: Double, busy: Bool = false) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let width = Int(size.width)
        let height = Int(size.height)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 2),
                AVVideoExpectedSourceFrameRateKey: framesPerSecond,
                AVVideoMaxKeyFrameIntervalDurationKey: SegmentedScreenRecorder.segmentInterval + 1,
                AVVideoAllowFrameReorderingKey: false,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
            ],
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        let count = Int(seconds * Double(framesPerSecond))
        for index in 0..<count {
            let time = Double(index) / Double(framesPerSecond)
            let renderer = ImageRenderer(content: Screen(time: time, busy: busy).environment(\.colorScheme, .light))
            renderer.scale = 2
            guard let image = renderer.cgImage, let pool = adaptor.pixelBufferPool else { continue }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            while !input.isReadyForMoreMediaData { try? await Task.sleep(for: .milliseconds(5)) }
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: framesPerSecond))
        }
        input.markAsFinished()
        await writer.finishWriting()
        if let error = writer.error { throw error }
    }

    private struct Screen: View {
        let time: Double
        var busy = false

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color(white: 0.93)
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.8)).frame(width: 10, height: 10) }
                        Text("localhost:3000/checkout")
                            .font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10)
                            .frame(width: 360, height: 24, alignment: .leading)
                            .background(Color.white, in: .rect(cornerRadius: 6))
                            .padding(.leading, 30)
                        Spacer()
                        Text(String(format: "00:%02d", Int(time))).font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    .background(Color(white: 0.86))
                    HStack(alignment: .top, spacing: 28) {
                        if busy { feed } else { checkout }
                        developer
                    }
                    .padding(28)
                    Spacer(minLength: 0)
                }
                if toastRange.contains(time) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Signed in as ada@acme.dev").font(.system(size: 13, weight: .semibold))
                        Text("session tok_demo_8812_FAKE_c41e").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .frame(width: 320, height: 82, alignment: .leading)
                    .background(Color.white, in: .rect(cornerRadius: 10))
                    .shadow(radius: 6)
                    .offset(x: 600, y: 47)
                }
                if popupRange.contains(time) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Password manager").font(.system(size: 14, weight: .bold))
                        Text("Fill password for acme.dev?").font(.system(size: 13))
                        Text("hunter2-DEMO-not-real").font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .padding(8)
                            .background(Color.yellow.opacity(0.3), in: .rect(cornerRadius: 6))
                    }
                    .padding(16)
                    .frame(width: 330)
                    .background(Color.white, in: .rect(cornerRadius: 12))
                    .shadow(radius: 12)
                    .offset(x: 300, y: 220)
                }
                Image(systemName: "cursorarrow")
                    .font(.system(size: 22))
                    .foregroundStyle(.black)
                    .offset(x: 120 + 380 * (0.5 + 0.5 * sin(time * 0.9)), y: 160 + 200 * (0.5 + 0.5 * cos(time * 0.7)))
            }
            .frame(width: size.width / 2, height: size.height / 2)
        }

        private var checkout: some View {
            VStack(alignment: .leading, spacing: 12) {
                Text("Checkout").font(.system(size: 26, weight: .bold))
                ForEach(0..<5) { row in
                    HStack {
                        RoundedRectangle(cornerRadius: 6).fill(Color(hue: Double(row) / 5, saturation: 0.35, brightness: 0.9)).frame(width: 44, height: 44)
                        VStack(alignment: .leading) {
                            Text(["Trail runner", "Wool socks", "Rain shell", "Water bottle", "Headlamp"][row]).font(.system(size: 14, weight: .semibold))
                            Text("Qty \(row + 1)").font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "$%.2f", Double(19 + row * 13) + (row == Int(time) % 5 ? 0.99 : 0))).font(.system(size: 14, design: .monospaced))
                    }
                }
                Text("Total $149.00").font(.system(size: 15))
                Text("Pay now")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 110, height: 30)
                    .background(Color.gray, in: .rect(cornerRadius: 6))
            }
            .padding(20)
            .frame(width: 520, alignment: .leading)
            .background(Color.white, in: .rect(cornerRadius: 12))
        }

        private var feed: some View {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<40) { row in
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(LinearGradient(colors: [Color(hue: (Double(row) / 9 + time / 7).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.9), Color(hue: Double(row) / 13, saturation: 0.4, brightness: 0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 96, height: 60)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Order #\(4200 + row) · \(["Trail runner", "Wool socks", "Rain shell", "Water bottle", "Headlamp"][row % 5]) shipped to warehouse \(row % 7)").font(.system(size: 14, weight: .semibold))
                            Text("Updated \(row * 3 + Int(time)) s ago · tracking 1Z\(String(row * 7919 + Int(time * 10), radix: 16).uppercased())").font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(20)
            .offset(y: -CGFloat(time.truncatingRemainder(dividingBy: 20)) * 90)
            .frame(width: 520, height: 500, alignment: .top)
            .clipped()
            .background(Color.white, in: .rect(cornerRadius: 12))
        }

        private var developer: some View {
            VStack(alignment: .leading, spacing: 10) {
                Text("Developer settings").font(.system(size: 15, weight: .bold))
                Text("Publishable key").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("pk_test_51Hx_DEMO_public").font(.system(size: 13, design: .monospaced))
                Text("Secret key").font(.system(size: 12)).foregroundStyle(.secondary)
                Text("sk_live_51Hx9_FAKE_DEMO_7Qz").font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .padding(6)
                    .background(Color.red.opacity(0.12), in: .rect(cornerRadius: 4))
            }
            .padding(18)
            .frame(width: 300, alignment: .leading)
            .background(Color.white, in: .rect(cornerRadius: 12))
        }
    }
}
