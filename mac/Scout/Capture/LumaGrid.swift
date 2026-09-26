import Accelerate
import CoreVideo

nonisolated struct LumaGrid: Sendable {
    static let columns = 32
    static let rows = 18
    private static let intermediateFactor = 8
    private static let changeThreshold = 6

    let values: [UInt8]

    init?(pixelBuffer: CVPixelBuffer) {
        guard CVPixelBufferIsPlanar(pixelBuffer), CVPixelBufferGetPlaneCount(pixelBuffer) >= 1 else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }

        var source = vImage_Buffer(
            data: luma,
            height: vImagePixelCount(CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)),
            width: vImagePixelCount(CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)),
            rowBytes: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
        )
        let middleWidth = Self.columns * Self.intermediateFactor
        let middleHeight = Self.rows * Self.intermediateFactor
        var middlePixels = [UInt8](repeating: 0, count: middleWidth * middleHeight)
        var gridPixels = [UInt8](repeating: 0, count: Self.columns * Self.rows)
        let succeeded = middlePixels.withUnsafeMutableBytes { middleBytes in
            gridPixels.withUnsafeMutableBytes { gridBytes in
                var middle = vImage_Buffer(data: middleBytes.baseAddress, height: vImagePixelCount(middleHeight), width: vImagePixelCount(middleWidth), rowBytes: middleWidth)
                var grid = vImage_Buffer(data: gridBytes.baseAddress, height: vImagePixelCount(Self.rows), width: vImagePixelCount(Self.columns), rowBytes: Self.columns)
                return vImageScale_Planar8(&source, &middle, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
                    && vImageScale_Planar8(&middle, &grid, nil, vImage_Flags(kvImageNoFlags)) == kvImageNoError
            }
        }
        guard succeeded else { return nil }
        values = gridPixels
    }

    func changedFraction(since previous: LumaGrid) -> Double {
        var changed = 0
        for index in values.indices where abs(Int(values[index]) - Int(previous.values[index])) > Self.changeThreshold {
            changed += 1
        }
        return Double(changed) / Double(values.count)
    }
}
