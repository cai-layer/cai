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

            // Strip any remaining PII in beforeSend
            options.beforeSend = { event in
                event.user = nil
                event.serverName = nil
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
