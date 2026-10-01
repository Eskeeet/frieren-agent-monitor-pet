import Foundation
import SwiftUI

enum Harness: String, CaseIterable, Codable {
    case claude, codex, cursor, pi

    var label: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .cursor: return "Cursor"
        case .pi: return "Pi"
        }
    }

    var color: Color {
        switch self {
        case .claude: return Color(red: 0.87, green: 0.48, blue: 0.31)
        case .codex: return Color(red: 0.20, green: 0.78, blue: 0.52)
        case .cursor: return Color(red: 0.52, green: 0.57, blue: 0.98)
        case .pi: return Color(red: 0.64, green: 0.43, blue: 0.85)
        }
    }
}

enum MonitorState: String, Codable {
    case running, waiting, finished, idle

    var label: String {
        switch self {
        case .running: return "Running"
        case .waiting: return "Needs input"
        case .finished: return "Finished"
        case .idle: return "Idle"
        }
    }
}

struct AgentSession: Identifiable, Equatable {
    let id: String
    let pid: Int
    let harness: Harness
    let remoteHost: String?
    let sshTarget: String?
    var projectPath: String?
    var title: String?
    let startedAt: Date
    var updatedAt: Date
    var state: MonitorState
    var claudeStatusUpdatedAt: Date? = nil

    var isRemote: Bool { remoteHost != nil }

    var sourceID: String { remoteHost.map { "remote:\($0)" } ?? "local" }

    var displayName: String {
        if let title, !title.isEmpty, title != "main-agent" { return title }
        if let projectPath, projectPath != "/" {
            let name = URL(fileURLWithPath: projectPath).lastPathComponent
            // Cursor runs user hooks from its own configuration directory when
            // it does not provide workspace metadata. That is not a session name.
            if !name.isEmpty, !(harness == .cursor && name == ".cursor") { return name }
        }
        return harness.label
    }
}

struct RemoteHostStatus: Identifiable, Equatable {
    let id: String
    let sshTarget: String
    let isOnline: Bool
    let error: String?
}

enum PetMood: Hashable {
    case sleeping, watching, working, needsInput, celebrating
}

enum PetTravelDirection: Equatable {
    case left, right
}

final class PetMotion: ObservableObject {
    @Published private(set) var dragDirection: PetTravelDirection?
    private var lastDirection: PetTravelDirection = .right

    var isDragging: Bool { dragDirection != nil }

    func updateDrag(deltaX: CGFloat, deltaY: CGFloat) {
        guard abs(deltaX) + abs(deltaY) > 0.25 else { return }
        if abs(deltaX) > 0.25 {
            lastDirection = deltaX < 0 ? .left : .right
        }
        dragDirection = lastDirection
    }

    func endDrag() {
        dragDirection = nil
    }
}
