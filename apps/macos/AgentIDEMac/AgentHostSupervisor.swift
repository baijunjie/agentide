import AppKit
import Foundation
import Security

struct AgentHostConnection: Sendable {
    let baseURL: URL
    let authenticationToken: String
}

private struct StartedCompanion {
    let connection: AgentHostConnection
    let process: Process
}

private struct CompanionStartup {
    let generation: Int
    let task: Task<StartedCompanion, Error>
}

@MainActor
final class AgentHostSupervisor: NSObject {
    private var activeConnection: AgentHostConnection?
    private var process: Process?
    private var startupTask: CompanionStartup?
    private var restartTask: Task<Void, Never>?
    private var isStopping = false
    private var generation = 0

    override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    func connection() async throws -> AgentHostConnection {
        guard !isStopping else { throw CompanionError.stopped }
        if let activeConnection, process?.isRunning == true {
            return activeConnection
        }
        if let startupTask {
            return try await awaitStartup(startupTask)
        }

        generation += 1
        let launchGeneration = generation
        let task = Task { try await launch(generation: launchGeneration) }
        let startup = CompanionStartup(generation: launchGeneration, task: task)
        startupTask = startup
        return try await awaitStartup(startup)
    }

    private func awaitStartup(_ startup: CompanionStartup) async throws -> AgentHostConnection {
        do {
            let started = try await startup.task.value
            guard generation == startup.generation, process === started.process,
                  started.process.isRunning, !isStopping else {
                throw CompanionError.superseded
            }
            if startupTask?.generation == startup.generation {
                startupTask = nil
            }
            activeConnection = started.connection
            return started.connection
        } catch {
            if startupTask?.generation == startup.generation {
                startupTask = nil
            }
            if generation == startup.generation, !isStopping {
                scheduleRestart(after: .seconds(1))
            }
            throw error
        }
    }

    @objc private func applicationWillTerminate() {
        stop()
    }

    private func stop() {
        isStopping = true
        generation += 1
        restartTask?.cancel()
        restartTask = nil
        startupTask?.task.cancel()
        startupTask = nil
        activeConnection = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    private func launch(generation launchGeneration: Int) async throws -> StartedCompanion {
        guard let resources = Bundle.main.resourceURL else {
            throw CompanionError.missingResources
        }
        let hostDirectory = resources.appendingPathComponent("AgentHost", isDirectory: true)
        let runtime = hostDirectory.appendingPathComponent("node", isDirectory: false)
        let entrypoint = hostDirectory.appendingPathComponent("dist/main.js", isDirectory: false)
        guard FileManager.default.isExecutableFile(atPath: runtime.path),
              FileManager.default.fileExists(atPath: entrypoint.path) else {
            throw CompanionError.missingRuntime
        }

        let token = try secureToken()
        let output = Pipe()
        let errors = Pipe()
        let probe = CompanionStartupProbe(timeout: 10)
        output.fileHandleForReading.readabilityHandler = { handle in
            probe.receive(handle.availableData)
        }
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let message = String(data: data, encoding: .utf8) else { return }
            NSLog("Agent Host: %@", message.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        let child = Process()
        child.executableURL = runtime
        child.arguments = [entrypoint.path]
        child.currentDirectoryURL = hostDirectory
        child.standardOutput = output
        child.standardError = errors
        var environment = ProcessInfo.processInfo.environment
        environment["AGENT_HOST_PORT"] = "0"
        environment["AGENT_HOST_TOKEN"] = token
        environment["AGENT_HOST_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        child.environment = environment
        child.terminationHandler = { [weak self, weak child] finished in
            probe.processExited(status: finished.terminationStatus)
            Task { @MainActor in
                guard let self, let child, self.process === child else { return }
                self.process = nil
                self.activeConnection = nil
                guard !self.isStopping else { return }
                self.scheduleRestart(after: .seconds(1))
            }
        }

        do {
            guard generation == launchGeneration, !isStopping else { throw CompanionError.superseded }
            try child.run()
            process = child
            let port = try await probe.port()
            guard generation == launchGeneration, process === child, child.isRunning, !isStopping,
                  let baseURL = URL(string: "http://127.0.0.1:\(port)") else {
                throw CompanionError.exitedBeforeReady
            }
            return StartedCompanion(
                connection: AgentHostConnection(baseURL: baseURL, authenticationToken: token),
                process: child
            )
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if child.isRunning { child.terminate() }
            if process === child { process = nil }
            throw error
        }
    }

    private func scheduleRestart(after initialDelay: Duration) {
        guard restartTask == nil, !isStopping else { return }
        restartTask = Task { [weak self] in
            var delay = initialDelay
            while let self, !Task.isCancelled, !self.isStopping {
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, !self.isStopping else { break }
                if self.process?.isRunning == true { break }
                if self.startupTask != nil { continue }
                do {
                    _ = try await self.connection()
                    break
                } catch {
                    NSLog("Agent Host restart failed: %@", error.localizedDescription)
                    delay = min(delay * 2, .seconds(30))
                }
            }
            self?.restartTask = nil
        }
    }

    private func secureToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, buffer.count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw CompanionError.randomTokenFailed(status) }
        return Data(bytes).base64EncodedString()
    }
}

private enum CompanionError: LocalizedError {
    case missingResources
    case missingRuntime
    case stopped
    case superseded
    case randomTokenFailed(OSStatus)
    case invalidReadyMessage
    case exitedBeforeReady
    case startupTimedOut

    var errorDescription: String? {
        switch self {
        case .missingResources: "The application resources are unavailable."
        case .missingRuntime: "The packaged Agent Host runtime is missing."
        case .stopped: "The Agent Host supervisor has stopped."
        case .superseded: "The Agent Host startup was superseded."
        case let .randomTokenFailed(status): "Could not create an Agent Host credential (\(status))."
        case .invalidReadyMessage: "The Agent Host returned an invalid startup response."
        case .exitedBeforeReady: "The Agent Host exited before it became ready."
        case .startupTimedOut: "The Agent Host did not start in time."
        }
    }
}

private final class CompanionStartupProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var continuation: CheckedContinuation<Int, Error>?
    private var result: Result<Int, Error>?

    init(timeout: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(CompanionError.startupTimedOut))
        }
    }

    func port() async throws -> Int {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
                return
            }
            self.continuation = continuation
            lock.unlock()
        }
    }

    func receive(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        guard result == nil else { lock.unlock(); return }
        buffer.append(data)
        guard let newline = buffer.firstIndex(of: 0x0A) else { lock.unlock(); return }
        let line = buffer[..<newline]
        lock.unlock()

        guard let value = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              value["type"] as? String == "ready",
              let port = value["port"] as? Int,
              1...65_535 ~= port else {
            finish(.failure(CompanionError.invalidReadyMessage))
            return
        }
        finish(.success(port))
    }

    func processExited(status: Int32) {
        finish(.failure(NSError(
            domain: "AgentIDE.AgentHost",
            code: Int(status),
            userInfo: [NSLocalizedDescriptionKey: "The Agent Host exited with status \(status)."]
        )))
    }

    private func finish(_ result: Result<Int, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
