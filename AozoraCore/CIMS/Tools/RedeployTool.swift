import Foundation

/// Rebuild, sign, install, and restart the Aozora daemon.
///
/// The agent calls this after modifying its own source code. The tool:
/// 1. Runs `swift build -c release` in the project directory
/// 2. Code-signs the binary (with the configured identity, or ad-hoc)
/// 3. Installs to `~/.aozora/bin/aozora`
/// 4. Writes a self-rebuild flag with the reason
/// 5. Triggers `launchctl unload/load` to restart with fresh plist
///
/// On restart, the new instance reads the flag, sends a message telling the
/// agent to continue its work, and notifies the user via Discord DM.
public nonisolated struct RedeployTool: ToolExecutable {
    public let name = "redeploy"

    /// Config store providing the code-signing identity (``ConfigKey/deploySigningIdentity``).
    ///
    /// A specific identity avoids the "ambiguous" codesign error when multiple
    /// Apple Development certs are installed. Empty means ad-hoc signing.
    private let configStore: ConfigStore

    /// Creates a redeploy tool backed by the given config store.
    public init(configStore: ConfigStore) {
        self.configStore = configStore
    }

    public var definition: ToolDefinition {
        ToolDefinition(
            name: "redeploy",
            description: """
            Rebuild, sign, and restart the Aozora daemon. Use after modifying source code. \
            The daemon will be rebuilt with `swift build -c release`, code-signed, installed \
            to ~/.aozora/bin/aozora, then restarted via launchctl. \
            After restart, you will receive a message to continue your work.
            """,
            parameters: [
                ToolParameter(
                    name: "reason",
                    type: .string,
                    description: "Brief description of why the redeploy is needed",
                    optional: true,
                ),
            ],
        )
    }

    public func execute(parameters: sending [String: Any], workingDirectory _: String) async throws -> ToolResult {
        let reason = parameters["reason"] as? String ?? "Self-initiated rebuild"
        let projectDir = NSHomeDirectory() + "/Developer/aozora"
        let buildOutput = projectDir + "/.build/release/Aozora"
        let installPath = NSHomeDirectory() + "/.aozora/bin/aozora"
        let entitlementsPath = projectDir + "/scripts/daemon.entitlements"
        let plistPath = NSHomeDirectory() + "/Library/LaunchAgents/ai.aozora.daemon.plist"
        var notes: [String] = []

        // Step 1: Build release
        let buildResult = try await runProcess(
            "/usr/bin/env", ["swift", "build", "-c", "release", "--product", "Aozora"],
            cwd: projectDir,
            timeoutSeconds: 300,
        )

        guard buildResult.exitCode == 0 else {
            let tail = String(buildResult.output.suffix(1_000))
            return .failure("Build failed (exit \(buildResult.exitCode)):\n\(tail)")
        }
        notes.append("Build succeeded.")

        // Step 2: Code sign with the configured identity, falling back to ad-hoc
        let signingIdentity = await configStore.get(.deploySigningIdentity)
        var signed = false

        if !signingIdentity.isEmpty {
            var signArgs = ["--force", "--sign", signingIdentity]
            if FileManager.default.fileExists(atPath: entitlementsPath) {
                signArgs += ["--options", "runtime", "--entitlements", entitlementsPath]
            }
            signArgs.append(buildOutput)

            let signResult = try await runProcess(
                "/usr/bin/codesign", signArgs,
                cwd: projectDir,
                timeoutSeconds: 30,
            )

            if signResult.exitCode == 0 {
                notes.append("Signed with \(signingIdentity).")
                signed = true
            }
        }

        if !signed {
            _ = try await runProcess(
                "/usr/bin/codesign", ["--force", "--sign", "-", buildOutput],
                cwd: projectDir, timeoutSeconds: 10,
            )
            notes.append(
                signingIdentity.isEmpty
                    ? "Signed ad-hoc (no deploy.signingIdentity configured)."
                    : "Signed ad-hoc (identity signing failed).",
            )
        }

        // Step 3: Install to ~/.aozora/bin/
        try? FileManager.default.createDirectory(
            atPath: NSHomeDirectory() + "/.aozora/bin",
            withIntermediateDirectories: true,
        )
        try? FileManager.default.removeItem(atPath: installPath)
        try FileManager.default.copyItem(atPath: buildOutput, toPath: installPath)
        notes.append("Installed to \(installPath).")

        // Step 4: Write self-rebuild flag
        let flagPath = NSHomeDirectory() + "/.aozora/self-rebuild"
        try? reason.write(toFile: flagPath, atomically: true, encoding: .utf8)

        // Step 5: Restart via unload/load (picks up plist changes unlike kickstart)
        Task.detached {
            try? await Task.sleep(for: .seconds(2))
            let unload = Process()
            unload.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            unload.arguments = ["unload", plistPath]
            try? unload.run()
            unload.waitUntilExit()

            try? await Task.sleep(for: .seconds(1))

            let load = Process()
            load.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            load.arguments = ["load", plistPath]
            try? load.run()
        }

        notes.append("Restarting in 2 seconds...")
        return .success(notes.joined(separator: "\n") + "\nReason: \(reason)")
    }

    private func runProcess(
        _ executable: String,
        _ arguments: [String],
        cwd: String,
        timeoutSeconds: Int,
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        let didTimeout = await waitForProcess(process, timeoutNanoseconds: UInt64(timeoutSeconds) * 1_000_000_000)

        if didTimeout {
            process.terminate()
            return ("Process timed out after \(timeoutSeconds)s", -1)
        }

        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (output, process.terminationStatus)
    }

    private func waitForProcess(_ process: Process, timeoutNanoseconds: UInt64) async -> Bool {
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let workItem = DispatchWorkItem { process.waitUntilExit() }
                DispatchQueue.global().async(execute: workItem)
                let deadline = DispatchTime.now() + .nanoseconds(Int(timeoutNanoseconds))
                continuation.resume(returning: workItem.wait(timeout: deadline) == .timedOut)
            }
        } onCancel: {
            process.terminate()
        }
    }
}
