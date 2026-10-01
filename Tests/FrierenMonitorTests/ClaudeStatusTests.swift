import Foundation

// Compile with the app sources except main.swift, then run the resulting binary.
@main
enum ClaudeStatusTests {
    static func main() throws {
        let base = Date().addingTimeInterval(-100)
        func date(_ seconds: Double) -> Date { base.addingTimeInterval(seconds) }
        func sidecar(_ status: String, statusTime: Double?, metadataTime: Double = 30) throws -> ClaudeSidecar {
            var values: [String: Any] = ["status": status, "updatedAt": date(metadataTime).timeIntervalSince1970 * 1000]
            if let statusTime { values["statusUpdatedAt"] = date(statusTime).timeIntervalSince1970 * 1000 }
            return try JSONDecoder().decode(ClaudeSidecar.self, from: JSONSerialization.data(withJSONObject: values))
        }
        func hook(_ event: String, _ time: Double, _ key: String? = nil, pid: Int = 42) -> HookRecord {
            HookRecord(timestamp: date(time).timeIntervalSince1970, agent: "claude-code",
                       event: event, projectPath: "/project", pid: pid,
                       title: event == "start" ? "Latest prompt" : nil, requestKey: key)
        }
        func merged(_ sidecar: ClaudeSidecar, _ hooks: [HookRecord]) -> AgentSession {
            let monitor = SessionMonitor()
            let session = AgentSession(id: "local:claude:42", pid: 42, harness: .claude,
                remoteHost: nil, sshTarget: nil, projectPath: "/project", title: nil,
                startedAt: base, updatedAt: sidecar.authoritativeStatusDate
                    ?? sidecar.updatedAt.map { Date(timeIntervalSince1970: $0 / 1000) } ?? base,
                state: sidecar.state, claudeStatusUpdatedAt: sidecar.authoritativeStatusDate)
            monitor.merge(previous: [], discovered: [session], hooks: hooks,
                          knownSources: ["local"], scannedSources: ["local"])
            return monitor.sessions[0]
        }

        let busy = try sidecar("busy", statusTime: 20)
        let resolved = merged(busy, [hook("start", 5), hook("permission", 10, "original"),
                                    hook("resume", 21, "edited")])
        precondition(resolved.state == .running, "New busy transition must clear the stale permission")
        precondition(abs(resolved.updatedAt.timeIntervalSince(date(20))) < 0.001)
        precondition(resolved.title == "Latest prompt", "Prompt metadata must be preserved")
        precondition(merged(busy, [hook("permission", 10, "old"), hook("permission", 25, "new"),
                                  hook("resume", 26, "subagent")]).state == .waiting,
                     "New permissions must survive unrelated tool activity")
        precondition(merged(busy, [hook("permission", 25, "tool"), hook("resume", 26, "tool")]).state == .running)
        precondition(merged(busy, [hook("stop", 25)]).state == .finished)
        for time: Double? in [nil, 5] {
            let renamed = try sidecar("busy", statusTime: time)
            precondition(merged(renamed, [hook("permission", 10, "tool")]).state == .waiting,
                         "A metadata update or missing transition time must not clear a permission")
        }
        for status in ["idle", "shell"] {
            let inactive = try sidecar(status, statusTime: 20)
            precondition(merged(inactive, [hook("start", 5), hook("permission", 10, "tool")]).state == .idle)
            precondition(merged(inactive, [hook("start", 25)]).state == .running)
            precondition(merged(inactive, [hook("permission", 25, "tool")]).state == .waiting)
            let legacy = try sidecar(status, statusTime: nil)
            precondition(merged(legacy, [hook("permission", 10, "tool")]).state == .idle)
        }
        print("Claude status checks passed: changed approval input, newer prompts, unrelated tools, stop, rename, and legacy sidecars.")
    }
}
