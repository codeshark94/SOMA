import Foundation

/// Converts normalized rectangles between a source image and a square model
/// input prepared with aspect-fit letterboxing. Coordinates retain a top-left
/// origin in both spaces.
public struct NormalizedSquareScaleFit: Equatable, Sendable {
    public let offsetX: Double
    public let offsetY: Double
    public let scaleX: Double
    public let scaleY: Double

    public init(sourceWidth: Int, sourceHeight: Int) {
        guard sourceWidth > 0, sourceHeight > 0 else {
            offsetX = 0
            offsetY = 0
            scaleX = 1
            scaleY = 1
            return
        }
        if sourceWidth >= sourceHeight {
            scaleX = 1
            scaleY = Double(sourceHeight) / Double(sourceWidth)
            offsetX = 0
            offsetY = (1 - scaleY) / 2
        } else {
            scaleX = Double(sourceWidth) / Double(sourceHeight)
            scaleY = 1
            offsetX = (1 - scaleX) / 2
            offsetY = 0
        }
    }

    public func squareRect(for source: NormalizedRect) -> NormalizedRect? {
        guard source.width > 0, source.height > 0 else { return nil }
        return clippedSquareRect(
            NormalizedRect(
                x: offsetX + source.x * scaleX,
                y: offsetY + source.y * scaleY,
                width: source.width * scaleX,
                height: source.height * scaleY
            )
        )
    }

    public func sourceRect(for square: NormalizedRect) -> NormalizedRect? {
        guard let clipped = clippedSquareRect(square) else { return nil }
        return NormalizedRect(
            x: (clipped.x - offsetX) / scaleX,
            y: (clipped.y - offsetY) / scaleY,
            width: clipped.width / scaleX,
            height: clipped.height / scaleY
        )
    }

    public func sourcePoint(x: Double, y: Double) -> (x: Double, y: Double)? {
        guard x >= offsetX, x <= offsetX + scaleX,
              y >= offsetY, y <= offsetY + scaleY else {
            return nil
        }
        return ((x - offsetX) / scaleX, (y - offsetY) / scaleY)
    }

    private func clippedSquareRect(_ rect: NormalizedRect) -> NormalizedRect? {
        guard rect.x.isFinite, rect.y.isFinite,
              rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0,
              scaleX > 0, scaleY > 0 else {
            return nil
        }
        let minimumX = max(rect.x, offsetX)
        let minimumY = max(rect.y, offsetY)
        let maximumX = min(rect.x + rect.width, offsetX + scaleX)
        let maximumY = min(rect.y + rect.height, offsetY + scaleY)
        guard maximumX > minimumX, maximumY > minimumY else { return nil }
        return NormalizedRect(
            x: minimumX,
            y: minimumY,
            width: maximumX - minimumX,
            height: maximumY - minimumY
        )
    }
}
