import Foundation

/// Manages the built-in llama-server subprocess for zero-dependency LLM inference.
/// Launches the bundled llama-server binary with a downloaded GGUF model,
/// providing an OpenAI-compatible API on a local port.
actor BuiltInLLM {
    static let shared = BuiltInLLM()

    private var process: Process?
    private var assignedPort: Int = 8690
    private let portRange = 8690...8699

    /// Stored model path for automatic restart after unexpected termination
    private var lastModelPath: String?

    /// Tracks consecutive crash restarts to avoid infinite loops
    private var restartCount = 0
    private let maxRestarts = 3

    /// Set to true during intentional stop() to suppress auto-restart
    private var stoppingIntentionally = false

    /// Base URL for the running server (e.g. "http://127.0.0.1:8690")
    var serverURL: String { "http://127.0.0.1:\(assignedPort)" }

    /// Whether the llama-server process is currently running
    var isRunning: Bool { process?.isRunning ?? false }

    // MARK: - Paths

    /// Path to the bundled llama-server binary inside the app bundle
    private var serverBinaryPath: String? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bin")
            .appendingPathComponent("llama-server")
            .path
    }

    /// Directory for storing downloaded models and PID file
    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cai")
    }

    static var modelsDirectory: URL {
        supportDirectory.appendingPathComponent("models")
    }

    private var pidFilePath: URL {
        Self.supportDirectory.appendingPathComponent("llama-server.pid")
    }

    // MARK: - Start

    /// Starts the llama-server subprocess with the given model.
    /// Finds a free port, launches the process, and waits until the server is responsive.
    func start(modelPath: String) async throws {
        // Don't start if already running
        guard !isRunning else { return }

        guard let binaryPath = serverBinaryPath else {
            throw BuiltInLLMError.binaryNotFound
        }

        guard FileManager.default.fileExists(atPath: binaryPath) else {
            throw BuiltInLLMError.binaryNotFound
        }

        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw BuiltInLLMError.modelNotFound
        }

        // Find a free port
        assignedPort = try findFreePort()

        // Launch the process
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = [
            "--model", modelPath,
            "--port", String(assignedPort),
            "--ctx-size", "2048",
            "--n-gpu-layers", "99",
            "--flash-attn", "on"
        ]

        // Set the working directory to the bin folder so dylibs are found via @rpath
        proc.currentDirectoryURL = URL(fileURLWithPath: binaryPath).deletingLastPathComponent()

        // Add the bin directory to DYLD_LIBRARY_PATH so the dylibs are found
        var env = ProcessInfo.processInfo.environment
        let binDir = URL(fileURLWithPath: binaryPath).deletingLastPathComponent().path
        env["DYLD_LIBRARY_PATH"] = binDir
        proc.environment = env

        // Capture output for debugging
        let outputPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = outputPipe

        // Handle unexpected termination
        proc.terminationHandler = { [weak self] process in
            Task { [weak self] in
                await self?.handleTermination(exitCode: process.terminationStatus)
            }
        }

        do {
            try proc.run()
        } catch {
            throw BuiltInLLMError.launchFailed(error.localizedDescription)
        }

        self.process = proc
        self.lastModelPath = modelPath
        self.stoppingIntentionally = false
        writePIDFile(pid: proc.processIdentifier)

        print("🦙 llama-server started on port \(assignedPort) (PID: \(proc.processIdentifier))")

        // Wait until the server is responsive
        try await waitUntilReady(timeout: 30)

        // Update CaiSettings with the actual port so LLMService connects to the right one
        let port = assignedPort
        await MainActor.run { CaiSettings.shared.builtInPort = port }

        // Successful start — reset crash counter
        restartCount = 0
    }

    // MARK: - Stop

    /// Gracefully stops the llama-server subprocess.
    func stop() {
        stoppingIntentionally = true

        guard let proc = process, proc.isRunning else {
            cleanupPIDFile()
            process = nil
            return
        }

        print("🦙 Stopping llama-server (PID: \(proc.processIdentifier))")
        proc.terminate()

        // Give it 3 seconds to shut down gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [weak proc] in
            if let proc = proc, proc.isRunning {
                print("🦙 Force killing llama-server")
                proc.interrupt() // SIGINT
                DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                    if proc.isRunning {
                        kill(proc.processIdentifier, SIGKILL)
                    }
                }
            }
        }

        cleanupPIDFile()
        process = nil
    }

    // MARK: - Orphan Cleanup

    /// Cleans up any orphaned llama-server process from a previous crash.
    /// Should be called on app launch.
    func cleanupOrphan() {
        guard FileManager.default.fileExists(atPath: pidFilePath.path) else { return }

        guard let pidString = try? String(contentsOf: pidFilePath, encoding: .utf8),
              let pid = Int32(pidString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            cleanupPIDFile()
            return
        }

        // Check if the process is still running
        if kill(pid, 0) == 0 {
            print("🦙 Cleaning up orphaned llama-server (PID: \(pid))")
            kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                if kill(pid, 0) == 0 {
                    kill(pid, SIGKILL)
                }
            }
        }

        cleanupPIDFile()
    }

    // MARK: - Private

    /// Polls the server's /v1/models endpoint until it responds or timeout.
    /// Bails out early if the process exits before becoming ready.
    private func waitUntilReady(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let url = URL(string: "\(serverURL)/v1/models")!

        while Date() < deadline {
            // Check if the process died before it became ready
            guard let proc = process, proc.isRunning else {
                throw BuiltInLLMError.launchFailed("Server process exited before becoming ready")
            }

            do {
                var request = URLRequest(url: url)
                request.timeoutInterval = 2
                let (_, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode == 200 {
                    print("🦙 llama-server is ready on port \(assignedPort)")
                    return
                }
            } catch {
                // Server not ready yet — wait and retry
            }
            try await Task.sleep(nanoseconds: 500_000_000) // 500ms
        }

        // Timeout — kill the process and throw
        stop()
        throw BuiltInLLMError.startupTimeout
    }

    /// Finds the first available port in the port range.
    private func findFreePort() throws -> Int {
        for port in portRange {
            if isPortAvailable(port) {
                return port
            }
        }
        throw BuiltInLLMError.noPortAvailable
    }

    /// Checks if a TCP port is available by attempting to bind to it.
    private func isPortAvailable(_ port: Int) -> Bool {
        let socketFD = socket(AF_INET, SOCK_STREAM, 0)
        guard socketFD >= 0 else { return false }
        defer { close(socketFD) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        return result == 0
    }

    private func handleTermination(exitCode: Int32) {
        cleanupPIDFile()
        process = nil

        // SIGTERM (15) or SIGINT (2) from intentional stop — no restart needed
        if stoppingIntentionally || exitCode == 15 || exitCode == 2 {
            return
        }

        print("🦙 llama-server exited unexpectedly (code: \(exitCode))")

        guard let modelPath = lastModelPath, restartCount < maxRestarts else {
            if restartCount >= maxRestarts {
                print("🦙 Max restart attempts (\(maxRestarts)) reached — giving up")
                postToast("AI engine failed to restart")
            }
            return
        }

        restartCount += 1
        print("🦙 Auto-restarting llama-server (attempt \(restartCount)/\(maxRestarts))")
        postToast("AI engine stopped unexpectedly. Restarting...")

        Task {
            // Brief delay before restart to avoid tight loops
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            do {
                try await start(modelPath: modelPath)
                print("🦙 Auto-restart successful")
            } catch {
                print("🦙 Auto-restart failed: \(error.localizedDescription)")
                if restartCount >= maxRestarts {
                    postToast("AI engine failed to restart")
                }
            }
        }
    }

    /// Posts a toast notification on the main thread via NotificationCenter.
    private func postToast(_ message: String) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .caiShowToast,
                object: nil,
                userInfo: ["message": message]
            )
        }
    }

    private func writePIDFile(pid: Int32) {
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? String(pid).write(to: pidFilePath, atomically: true, encoding: .utf8)
    }

    private func cleanupPIDFile() {
        try? FileManager.default.removeItem(at: pidFilePath)
    }
}

// MARK: - Errors

enum BuiltInLLMError: LocalizedError {
    case binaryNotFound
    case modelNotFound
    case launchFailed(String)
    case startupTimeout
    case noPortAvailable

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            return "Built-in AI engine not found in app bundle"
        case .modelNotFound:
            return "Model file not found. Try re-downloading in Settings."
        case .launchFailed(let reason):
            return "Failed to start AI engine: \(reason)"
        case .startupTimeout:
            return "AI engine took too long to start. The model may be too large for available memory."
        case .noPortAvailable:
            return "No available port for AI engine (8690-8699 all in use)"
        }
    }
}
