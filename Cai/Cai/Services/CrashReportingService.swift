import Foundation
import Sentry

/// Manages opt-in crash reporting via Sentry.
/// Privacy-first: disabled by default, no PII, no session tracking.
/// Wraps all Sentry SDK calls — other code should only interact through this service.
final class CrashReportingService {
    static let shared = CrashReportingService()

    private var isStarted = false

    private init() {}

    /// Starts Sentry if crash reporting is enabled. Safe to call multiple times.
    func startIfEnabled() {
        guard CaiSettings.shared.crashReportingEnabled, !isStarted else { return }

        SentrySDK.start { options in
            options.dsn = "https://151d035b44dc198bab23af96f04d1f27@o4510895861989376.ingest.de.sentry.io/4510895872213072"
            options.debug = false

            // Privacy: no PII, no session tracking, no performance tracing
            options.sendDefaultPii = false
            options.enableAutoSessionTracking = false
            options.tracesSampleRate = 0
            options.enableAutoPerformanceTracing = false
            options.enableCaptureFailedRequests = false

            // Strip any remaining PII in beforeSend, and drop known false-positive
            // app hangs that originate inside third-party frameworks we can't fix.
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil

                // Sparkle shows "no update found" / error alerts via NSAlert.runModal,
                // which blocks the main runloop while the user reads the alert.
                // Sentry's hang detector flags this as a 2s+ hang the moment the user
                // takes >2s to click OK. It's a UX choice in Sparkle, not a bug in Cai.
                // Drop these so they don't drown out real hangs.
                if event.exceptions?.contains(where: { $0.type == "App Hanging" }) == true {
                    let frames = (event.threads ?? []).flatMap { $0.stacktrace?.frames ?? [] }
                    let inSparkle = frames.contains { frame in
                        (frame.package?.contains("Sparkle") == true) ||
                        (frame.module?.contains("Sparkle") == true) ||
                        (frame.function?.contains("SPU") == true) ||
                        (frame.function?.contains("Sparkle") == true)
                    }
                    if inSparkle { return nil }
                }

                return event
            }

            // Set release to app version for dSYM matching
            let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "0"
            options.releaseName = "com.soyasis.cai@\(version)+\(build)"

            // Environment based on build configuration
            #if DEBUG
            options.environment = "development"
            #else
            options.environment = "production"
            #endif
        }

        isStarted = true
        print("🐛 Crash reporting started")
    }

    /// Stops Sentry. Safe to call if not started.
    func stop() {
        guard isStarted else { return }
        SentrySDK.close()
        isStarted = false
        print("🐛 Crash reporting stopped")
    }

    // MARK: - Breadcrumbs

    /// Adds a non-PII breadcrumb for crash context. No-op if Sentry is not started.
    func addBreadcrumb(category: String, message: String, level: SentryLevel = .info) {
        guard isStarted else { return }
        let crumb = Breadcrumb(level: level, category: category)
        crumb.message = message
        SentrySDK.addBreadcrumb(crumb)
    }

    // MARK: - Error Capture

    /// Captures a non-fatal error with optional context. No-op if Sentry is not started.
    func captureError(_ error: Error, context: [String: Any]? = nil) {
        guard isStarted else { return }
        SentrySDK.capture(error: error) { scope in
            if let context = context {
                for (key, value) in context {
                    scope.setExtra(value: value, key: key)
                }
            }
        }
    }
}
