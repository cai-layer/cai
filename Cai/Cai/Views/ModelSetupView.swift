import SwiftUI
#if canImport(FoundationModels)
import FoundationModels
#endif

/// First-launch setup view for downloading and configuring the built-in LLM.
/// Shown when no external LLM provider (LM Studio, Ollama) is detected.
struct ModelSetupView: View {
    @ObservedObject private var settings = CaiSettings.shared
    @ObservedObject private var downloader = ModelDownloader.shared
    @State private var phase: SetupPhase = .welcome
    @State private var errorMessage: String?
    @State private var appleIntelligenceAvailable: Bool = false

    /// Called when setup is complete or skipped
    var onComplete: () -> Void

    private enum SetupPhase {
        case welcome
        case downloading
        case starting
        case ready
        case error
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 20)

            // Logo
            CaiLogo(color: .caiPrimary)
                .frame(height: 36)
                .padding(.bottom, 16)

            switch phase {
            case .welcome:
                welcomeContent
            case .downloading:
                downloadingContent
            case .starting:
                startingContent
            case .ready:
                readyContent
            case .error:
                errorContent
            }

            Spacer(minLength: 20)
        }
        .frame(width: 360, height: 320)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            // Check Apple Intelligence availability
            appleIntelligenceAvailable = Self.isAppleIntelligenceAvailable()

            // If setup was already completed (download finished in background),
            // show the ready state.
            if settings.builtInSetupDone && !settings.builtInModelPath.isEmpty {
                phase = .ready
            } else if settings.builtInSetupDone && settings.modelProvider == .apple {
                phase = .ready
            } else if downloader.isDownloading {
                // Download is still in progress (window was closed and reopened)
                phase = .downloading
            }
        }
    }

    // MARK: - Welcome

    @ViewBuilder
    private var welcomeContent: some View {
        if appleIntelligenceAvailable {
            welcomeAppleIntelligence
        } else {
            welcomeMinistral
        }
    }

    // MARK: - Welcome (Apple Intelligence)

    private var welcomeAppleIntelligence: some View {
        VStack(spacing: 16) {
            Text("Cai needs a local AI model")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Text("AI-powered actions on your clipboard. Runs locally, never leaves your Mac.")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Apple Intelligence button
            Button(action: { selectAppleIntelligence() }) {
                HStack(spacing: 8) {
                    Image(systemName: "apple.intelligence")
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use Apple Intelligence")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Free \u{2022} No download \u{2022} Recommended")
                            .font(.system(size: 10))
                            .opacity(0.7)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.caiPrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)

            // Download instead
            Button("Download built-in model instead") {
                appleIntelligenceAvailable = false
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.caiPrimary)
            .buttonStyle(.plain)

            // Skip option
            Button("Skip \u{2014} I have my own LLM setup") {
                settings.builtInSetupDone = true
                onComplete()
            }
            .font(.system(size: 11))
            .foregroundColor(.caiTextSecondary)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Welcome (Ministral Download)

    private var welcomeMinistral: some View {
        VStack(spacing: 16) {
            Text("Cai needs a local AI model")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Text("AI-powered actions on your clipboard. Runs locally, never leaves your Mac.")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            // Download button
            Button(action: { startDownload() }) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 16))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Download \(ModelDownloader.defaultModel.name)")
                            .font(.system(size: 13, weight: .semibold))
                        Text("\(ModelDownloader.defaultModel.formattedSize) \u{2022} Fast \u{2022} Recommended")
                            .font(.system(size: 10))
                            .opacity(0.7)
                    }
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(Color.caiPrimary)
                .cornerRadius(8)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 40)

            // Skip option
            Button("Skip \u{2014} I have my own LLM setup") {
                settings.builtInSetupDone = true
                onComplete()
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(.caiPrimary)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Downloading

    private var downloadingContent: some View {
        VStack(spacing: 16) {
            Text("Downloading \(ModelDownloader.defaultModel.name)...")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            VStack(spacing: 6) {
                ProgressView(value: downloader.progress)
                    .progressViewStyle(.linear)
                    .padding(.horizontal, 40)

                HStack {
                    Text(formatBytes(downloader.downloadedBytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.caiTextSecondary)
                    Text("/")
                        .font(.system(size: 11))
                        .foregroundColor(.caiTextSecondary.opacity(0.4))
                    Text(formatBytes(downloader.totalBytes))
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.caiTextSecondary)
                    Spacer()
                    Text("\(Int(downloader.progress * 100))%")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(.caiTextPrimary)
                }
                .padding(.horizontal, 40)
            }

            Button("Cancel") {
                downloader.cancel()
                phase = .welcome
            }
            .font(.system(size: 11))
            .foregroundColor(.caiTextSecondary)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Starting

    private var startingContent: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(0.8)

            Text("Starting AI engine...")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Text("Loading model into memory. This may take a few seconds.")
                .font(.system(size: 11))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
    }

    // MARK: - Ready

    private var readyContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 32))
                .foregroundColor(.caiSuccess)

            Text("Ready!")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Text("Press \u{2325}C with any text selected to start using Cai.")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            Button("Done") {
                onComplete()
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 32)
            .padding(.vertical, 8)
            .background(Color.caiPrimary)
            .cornerRadius(6)
            .buttonStyle(.plain)
        }
    }

    // MARK: - Error

    private var errorContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundColor(.caiError)

            Text("Setup Failed")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.caiTextPrimary)

            Text(errorMessage ?? "An unknown error occurred.")
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)

            HStack(spacing: 12) {
                Button("Try Again") {
                    startDownload()
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.caiPrimary)
                .buttonStyle(.plain)

                Button("Skip for Now") {
                    onComplete()
                }
                .font(.system(size: 12))
                .foregroundColor(.caiTextSecondary)
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func selectAppleIntelligence() {
        settings.modelProvider = .apple
        settings.builtInSetupDone = true
        phase = .ready
    }

    private static func isAppleIntelligenceAvailable() -> Bool {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            return SystemLanguageModel.default.availability == .available
        }
        #endif
        return false
    }

    private func startDownload() {
        phase = .downloading
        errorMessage = nil

        Task {
            do {
                // Download and load the MLX model (MLXInference handles both)
                try await downloader.download(model: ModelDownloader.defaultModel)

                // Configure settings
                await MainActor.run {
                    settings.builtInSetupDone = true
                    settings.modelProvider = .builtIn
                    phase = .ready
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    phase = .error
                }
            }
        }
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
