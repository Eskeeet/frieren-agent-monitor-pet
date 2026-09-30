import Foundation
import CoreGraphics

// Run with swiftc alongside Sources/FrierenMonitor/PetWindowGeometry.swift.
@main
enum PetWindowGeometryTests {
    static func main() {
        let primary = NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let destinations = [
            NSRect(x: 1920, y: 0, width: 2560, height: 1440),
            NSRect(x: -1440, y: -200, width: 1440, height: 900),
            NSRect(x: 300, y: 1080, width: 1600, height: 900),
            NSRect(x: 300, y: -900, width: 1600, height: 900)
        ]
        let cursorPositions = [
            NSPoint(x: 1921, y: 300), NSPoint(x: -1, y: 300),
            NSPoint(x: 900, y: 1081), NSPoint(x: 900, y: -1)
        ]

        for (destination, cursor) in zip(destinations, cursorPositions) {
            let screens = [primary, destination]
            // The previous frame is still on the primary display: the cursor
            // must win even when no part of the panel reaches the destination.
            let oldFrame = NSRect(x: 1000, y: 300, width: 430, height: 260)
            precondition(PetWindowGeometry.targetScreenIndex(
                for: oldFrame, screens: screens, draggingAt: cursor
            ) == 1, "Dragging must follow the cursor to every neighboring display")

            let moved = PetWindowGeometry.constrainedFrame(oldFrame, to: destination)
            precondition(PetWindowGeometry.targetScreenIndex(
                for: moved, screens: screens, draggingAt: nil
            ) == 1, "Releasing must keep the pet on the destination display")

            let collapsed = NSRect(x: moved.maxX - 140, y: moved.minY, width: 140, height: 170)
            precondition(destination.contains(collapsed), "The entire pet must remain visible")
            precondition(PetWindowGeometry.constrainedFrame(collapsed, to: destination) == collapsed,
                         "Collapsing the session card must not move the pet")
        }

        let right = destinations[0]
        // 290 points of the expanded panel are on the first screen, while the
        // 140-point pet is on the second: choosing by panel area was the bug.
        let straddling = NSRect(x: 1630, y: 200, width: 430, height: 260)
        precondition(PetWindowGeometry.targetScreenIndex(
            for: straddling, screens: [primary, right], draggingAt: nil
        ) == 1, "The session card must not determine the pet's display")

        let visible = NSRect(x: 1920, y: 50, width: 2560, height: 1360)
        precondition(PetWindowGeometry.targetScreenIndex(
            for: straddling, screens: [primary, right], draggingAt: NSPoint(x: 2000, y: 10)
        ) == 1, "The cursor's display includes its Dock and menu bar")
        precondition(PetWindowGeometry.constrainedFrame(
            NSRect(x: 1630, y: -20, width: 430, height: 260), to: visible
        ).minY == 50, "Clamping must still respect the Dock")
        precondition(PetWindowGeometry.targetScreenIndex(
            for: straddling, screens: [], draggingAt: nil
        ) == nil, "No displays must be handled safely")
        print("Pet window geometry checks passed: four display directions, release, collapse, card overlap, and Dock bounds.")
    }
}
