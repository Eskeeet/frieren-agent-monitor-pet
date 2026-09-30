import Foundation
import CoreGraphics

enum PetWindowGeometry {
    static let petSize = NSSize(width: 140, height: 170)

    static func targetScreenIndex(
        for panelFrame: NSRect,
        screens: [NSRect],
        draggingAt mouseLocation: NSPoint?
    ) -> Int? {
        // A clamped window cannot cross the boundary by itself. During a drag,
        // the cursor chooses the destination, including its menu bar/Dock area.
        if let mouseLocation,
           let index = screens.firstIndex(where: { $0.contains(mouseLocation) }) {
            return index
        }

        // The expanded session card extends left of the pet and must not pull
        // her back to the previous display when the drag ends or the card hides.
        let petFrame = NSRect(
            x: panelFrame.maxX - min(petSize.width, panelFrame.width),
            y: panelFrame.minY,
            width: min(petSize.width, panelFrame.width),
            height: min(petSize.height, panelFrame.height)
        )
        var bestIndex: Int?
        var largestArea: CGFloat = 0
        for (index, screenFrame) in screens.enumerated() {
            let intersection = screenFrame.intersection(petFrame)
            guard !intersection.isNull else { continue }
            let area = intersection.width * intersection.height
            if area > largestArea {
                bestIndex = index
                largestArea = area
            }
        }
        return bestIndex
    }

    static func constrainedFrame(_ proposedFrame: NSRect, to visibleFrame: NSRect) -> NSRect {
        var result = proposedFrame
        let petWidth = min(petSize.width, result.width, visibleFrame.width)
        let petHeight = min(petSize.height, result.height, visibleFrame.height)
        let minimumX = visibleFrame.minX - result.width + petWidth
        let maximumX = visibleFrame.maxX - result.width
        result.origin.x = min(max(result.origin.x, minimumX), maximumX)
        result.origin.y = min(max(result.origin.y, visibleFrame.minY), visibleFrame.maxY - petHeight)
        return result
    }
}
