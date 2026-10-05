import Foundation

// Compile with the app sources except main.swift, then run the resulting binary.
@main
enum ClaudeDiscoveryTests {
    static func main() {
        let claudePath = "/Users/test/Library/Application Support/Claude/claude-code/2.1.288/claude.app/Contents/MacOS/claude"
        let wrapperPath = "/Applications/Claude.app/Contents/Helpers/disclaimer"
        let paths = SessionMonitor.executablePaths(from: """
          41 \(wrapperPath)
          42 \(claudePath)
          43 /opt/homebrew/bin/claude
          44 /Applications/Claude.app/Contents/MacOS/Claude
          45 /opt/Agent Tools/node
        invalid row
        """)
        precondition(paths[42] == claudePath, "The executable path must retain spaces")
        precondition(paths.count == 5)
        precondition(SessionMonitor.detectHarness(
            "\(claudePath) --output-format stream-json --input-format stream-json",
            executablePath: paths[42]
        ) == .claude, "An already-running Desktop session must be detected without hooks")
        precondition(SessionMonitor.detectHarness("claude", executablePath: paths[42]) == .claude,
                     "A rewritten process title must still use the executable identity")
        precondition(SessionMonitor.detectHarness("claude --resume", executablePath: paths[43]) == .claude)
        precondition(SessionMonitor.detectHarness("/opt/homebrew/bin/claude --resume") == .claude)
        precondition(SessionMonitor.detectHarness("claude --resume", executablePath: "/opt/versions/2.1.288") == .claude)
        precondition(SessionMonitor.detectHarness(
            "\(wrapperPath) --pgroup -- \(claudePath) --output-format stream-json",
            executablePath: paths[41]
        ) == nil, "Desktop's wrapper must not create a duplicate session")
        precondition(SessionMonitor.detectHarness(
            "\(paths[44]!) --type=renderer", executablePath: paths[44]
        ) == nil, "The Desktop app itself is not a coding session")
        for mode in ["daemon", "bg-pty-host", "bg-spare", "--bg-pty-host", "--bg-spare"] {
            precondition(SessionMonitor.detectHarness(
                "\(claudePath) \(mode)", executablePath: paths[42]
            ) == nil, "Claude infrastructure must remain excluded")
        }
        precondition(SessionMonitor.detectHarness(
            "/opt/Agent Tools/node /opt/pi-coding-agent/dist/cli.js", executablePath: paths[45]
        ) == .pi)
        precondition(SessionMonitor.detectHarness("node /opt/pi-coding-agent/dist/cli.js", executablePath: "MainThread") == .pi)
        precondition(SessionMonitor.detectHarness("Cursor Helper (Plugin): extension-host Agents Window") == .cursor)

        if CommandLine.arguments.contains("--live") {
            let livePaths = SessionMonitor.executablePaths(from: ProcessRunner.read("/bin/ps", ["-axo", "pid=,comm="]))
            let expected = Set(livePaths.compactMap { pid, path in
                path.hasSuffix("/claude.app/Contents/MacOS/claude") ? pid : nil
            })
            precondition(!expected.isEmpty, "The live check requires existing Claude Desktop sessions")
            let monitor = SessionMonitor()
            monitor.start()
            defer { monitor.stop() }
            let deadline = Date().addingTimeInterval(20)
            while monitor.lastScan == .distantPast && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            }
            let discovered = Set(monitor.sessions.filter { !$0.isRemote && $0.harness == .claude }.map(\.pid))
            precondition(expected.isSubset(of: discovered), "A cold-start scan must discover all existing Desktop sessions")
            print("Cold-start live scan discovered all \(expected.count) existing Claude Desktop sessions.")
        }
        print("Claude discovery checks passed: paths with spaces, CLI fallback, wrappers, infrastructure, and other harnesses.")
    }
}
