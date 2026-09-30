import AppKit
import SwiftUI

final class PetPanel: NSPanel {
    private static let petSize = PetWindowGeometry.petSize
    var onPetDragged: ((CGFloat, CGFloat) -> Void)?
    var onPetDragEnded: (() -> Void)?
    private var trackingPetDrag = false
    private var lastMouseLocation: NSPoint?
    private var dragOffsetFromPetAnchor: NSPoint?

    init(frame: NSRect) {
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        level = .statusBar
        hasShadow = false
        // Move the pet explicitly so SwiftUI's click/context-menu gestures
        // cannot prevent dragging (or cause a second background-window move).
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
    }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        var shouldConstrainPet = false
        switch event.type {
        case .leftMouseDown:
            let point = event.locationInWindow
            trackingPetDrag = point.x >= frame.width - Self.petSize.width
                && point.y <= Self.petSize.height
            lastMouseLocation = trackingPetDrag ? NSEvent.mouseLocation : nil
            dragOffsetFromPetAnchor = lastMouseLocation.map {
                NSPoint(x: $0.x - frame.maxX, y: $0.y - frame.minY)
            }
        case .leftMouseDragged where trackingPetDrag:
            let location = NSEvent.mouseLocation
            if let previous = lastMouseLocation, let offset = dragOffsetFromPetAnchor {
                let deltaX = location.x - previous.x
                let deltaY = location.y - previous.y
                var proposedFrame = frame
                // Anchor to the cursor, not the last clamped frame. This keeps
                // the grab point stable across screen edges and panel resizing.
                proposedFrame.origin.x = location.x - offset.x - frame.width
                proposedFrame.origin.y = location.y - offset.y
                setFrameOrigin(frameConstrainedToVisibleScreen(proposedFrame).origin)
                onPetDragged?(deltaX, deltaY)
            }
            lastMouseLocation = location
            shouldConstrainPet = true
        case .leftMouseUp:
            if trackingPetDrag {
                onPetDragEnded?()
                shouldConstrainPet = true
            }
            trackingPetDrag = false
            lastMouseLocation = nil
            dragOffsetFromPetAnchor = nil
        default:
            break
        }
        super.sendEvent(event)
        if shouldConstrainPet { constrainPetToVisibleScreen() }
    }

    func frameConstrainedToVisibleScreen(_ proposedFrame: NSRect) -> NSRect {
        guard let visibleFrame = targetScreen(for: proposedFrame)?.visibleFrame else {
            return proposedFrame
        }

        return PetWindowGeometry.constrainedFrame(proposedFrame, to: visibleFrame)
    }

    private func constrainPetToVisibleScreen() {
        let constrainedFrame = frameConstrainedToVisibleScreen(frame)
        if constrainedFrame.origin != frame.origin {
            setFrameOrigin(constrainedFrame.origin)
        }
    }

    private func targetScreen(for proposedFrame: NSRect) -> NSScreen? {
        let screens = NSScreen.screens
        if let index = PetWindowGeometry.targetScreenIndex(
            for: proposedFrame,
            screens: screens.map(\.frame),
            draggingAt: trackingPetDrag ? NSEvent.mouseLocation : nil
        ) {
            return screens[index]
        }
        return screen ?? NSScreen.main
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    private static let collapsedSize = NSSize(width: 140, height: 170)
    private static let expandedSize = NSSize(width: 430, height: 260)
    private let monitor = SessionMonitor()
    private let motion = PetMotion()
    private let characters = CharacterStore()
    private var panel: PetPanel!
    private var collapseWorkItem: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let size = Self.collapsedSize
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let origin = NSPoint(x: visible.maxX - size.width - 18, y: visible.minY + 18)
        panel = PetPanel(frame: NSRect(origin: origin, size: size))
        panel.onPetDragged = { [weak self] deltaX, deltaY in
            self?.motion.updateDrag(deltaX: deltaX, deltaY: deltaY)
        }
        panel.onPetDragEnded = { [weak self] in self?.motion.endDrag() }
        let host = NSHostingView(rootView: PetView(
            monitor: monitor,
            motion: motion,
            characters: characters,
            quit: { NSApplication.shared.terminate(nil) },
            setExpanded: { [weak self] expanded in self?.setExpanded(expanded) }
        ))
        host.frame = NSRect(origin: .zero, size: size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()
        monitor.start()
    }

    func applicationWillTerminate(_ notification: Notification) { monitor.stop() }

    private func setExpanded(_ expanded: Bool) {
        collapseWorkItem?.cancel()
        if expanded {
            apply(size: Self.expandedSize)
            return
        }
        let item = DispatchWorkItem { [weak self] in self?.apply(size: Self.collapsedSize) }
        collapseWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func apply(size: NSSize) {
        var frame = panel.frame
        let right = frame.maxX
        let bottom = frame.minY
        frame.size = size
        frame.origin = NSPoint(x: right - size.width, y: bottom)
        frame = panel.frameConstrainedToVisibleScreen(frame)
        panel.setFrame(frame, display: true, animate: true)
    }
}
