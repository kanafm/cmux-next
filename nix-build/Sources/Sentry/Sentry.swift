// Nix-build stub for `import Sentry`.
//
// Same story as Sparkle: the real Sentry-cocoa 8.x ships as an XCFramework
// (dynamic + static variants). Under nixpkgs ad-hoc signing, the framework's
// pages or static library content trip dyld's page-hash check at launch,
// yielding "SIGKILL (Code Signature Invalid)". Stubbing keeps cmux's error
// tracking call sites compiling but disables Sentry telemetry in the Nix
// build path.
//
// cmux uses only four SentrySDK APIs:
//   - SentrySDK.start { options in … }
//   - SentrySDK.addBreadcrumb(_:)
//   - SentrySDK.capture(message:scope:)
//   - SentrySDK.crash()

import Foundation

public final class Options: NSObject {
    public var dsn: String?
    public var enableAutoSessionTracking: Bool = true
    public var debug: Bool = false
    public var attachStacktrace: Bool = false
    public var environment: String?
    public var releaseName: String?
    public var dist: String?
    public var maxBreadcrumbs: UInt = 100
    public var sampleRate: NSNumber? = nil
    public var tracesSampleRate: NSNumber? = nil
    public var profilesSampleRate: NSNumber? = nil
    public var beforeSend: ((Any) -> Any?)? = nil
    public var beforeSendSpan: ((Any) -> Any?)? = nil
    public var beforeBreadcrumb: ((Breadcrumb) -> Breadcrumb?)? = nil
    public var ignoredErrorTypes: [String] = []
    public var enableCrashHandler: Bool = true
    public var enableMetricKit: Bool = true
    public var enableTimeToFullDisplayTracing: Bool = false
    public var enableAutoPerformanceTracing: Bool = true
    public var enableNetworkTracking: Bool = true
    public var enableNetworkBreadcrumbs: Bool = true
    public var enableSwizzling: Bool = true
    public var enableFileIOTracing: Bool = true
    public var enableCoreDataTracing: Bool = true
    public var enableAutoBreadcrumbTracking: Bool = true
    public var enableAppLaunchProfiling: Bool = false
    public var enableUserInteractionTracing: Bool = false
    public var initialScope: ((Scope) -> Scope)?
    public var tracesSampler: ((Any) -> NSNumber?)?
    public var inAppIncludes: [String] = []
    public var inAppExcludes: [String] = []
    public var sendDefaultPii: Bool = false
    public var appHangTimeoutInterval: TimeInterval = 2.0
    public var enableAppHangTracking: Bool = true
    public var enableAppHangTrackingV2: Bool = false
    public var enableWatchdogTerminationTracking: Bool = true
    public var enableCaptureFailedRequests: Bool = true
    public var failedRequestStatusCodes: [Any] = []
    public var failedRequestTargets: [String] = []
    public var maxAttachmentSize: UInt = 20 * 1024 * 1024
    public var maxCacheItems: UInt = 30

    public override init() {
        super.init()
    }
}

public final class Scope: NSObject {
    public override init() { super.init() }
    public func setTag(value: String, key: String) {}
    public func setExtra(value: Any?, key: String) {}
    public func setContext(value: [String: Any], key: String) {}
    public func setLevel(_ level: SentryLevel) {}
    public func setEnvironment(_ environment: String) {}
    public func setFingerprint(_ fingerprint: [String]) {}
    public func setUser(_ user: User?) {}
    public func addBreadcrumb(_ crumb: Breadcrumb) {}
    public func clearBreadcrumbs() {}
}

public final class User: NSObject {
    public var userId: String?
    public var email: String?
    public var username: String?
    public override init() { super.init() }
}

public enum SentryLevel: Int {
    case none = 0
    case debug = 1
    case info = 2
    case warning = 3
    case error = 4
    case fatal = 5
}

public final class Breadcrumb: NSObject {
    public var level: SentryLevel = .info
    public var category: String = ""
    public var message: String?
    public var data: [String: Any]?
    public var type: String?
    public var timestamp: Date = Date()
    public override init() { super.init() }
    public init(level: SentryLevel = .info, category: String = "") {
        self.level = level
        self.category = category
        super.init()
    }
}

public final class SentryId: NSObject {
    public static let empty = SentryId()
    public override init() { super.init() }
}

public enum SentrySDK {
    public static var isEnabled: Bool { false }

    public static func start(configureOptions: (Options) -> Void) {
        let opts = Options()
        configureOptions(opts)
        // No-op: don't actually start Sentry.
    }

    public static func addBreadcrumb(_ crumb: Breadcrumb) {}

    @discardableResult
    public static func capture(message: String, scope configureScope: (Scope) -> Void = { _ in }) -> SentryId {
        return .empty
    }

    @discardableResult
    public static func capture(error: Error, scope configureScope: (Scope) -> Void = { _ in }) -> SentryId {
        return .empty
    }

    public static func crash() {}

    public static func close() {}

    public static func flush(timeout: TimeInterval) {}

    public static func configureScope(_ callback: (Scope) -> Void) {
        callback(Scope())
    }
}
