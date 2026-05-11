// Nix-build stub for `import Sparkle`.
//
// The real Sparkle.framework loads successfully under nixpkgs swift but its
// XPC services (Downloader.xpc, Installer.xpc) trigger a "Code Signature
// Invalid" SIGKILL from dyld during lazy load — even with
// `disable-library-validation` and inside-out ad-hoc signing of every Mach-O.
// Rather than chase that signing issue, we stub Sparkle entirely. Auto-update
// is non-essential for "try cmux out under nix" workflows.
//
// All types/methods are no-ops or return sensible defaults. cmux's
// Sources/Update/* code (UpdateController, UpdateDriver, UpdateDelegate,
// UpdateViewModel, UpdatePopoverView, UpdateTestSupport) compiles unchanged
// and runs at runtime — it just never receives a real "update available"
// signal because we never start the updater.

import AppKit
import Foundation

// MARK: - Constants used in error userInfo lookups

public let SPULatestAppcastItemFoundKey = "SULatestAppcastItemFound"
public let SPUNoUpdateFoundReasonKey = "SUNoUpdateFoundReason"
public let SPUNoUpdateFoundUserInitiatedKey = "SUNoUpdateFoundUserInitiated"
public let SUSparkleErrorDomain = "SUSparkleErrorDomain"

// MARK: - Enums

@objc public enum SPUUserUpdateChoice: Int {
    case install
    case dismiss
    case skip
}

@objc public enum SPUNoUpdateFoundReason: OSStatus {
    case unknown = 0
    case onLatestVersion = 1
    case onNewerThanLatestVersion = 2
    case systemIsTooOld = 3
    case systemIsTooNew = 4
}

@objc public enum SPUUserUpdateStage: Int {
    case notDownloaded
    case downloaded
    case installing
}

// MARK: - Value types

public struct SPUUserUpdateState {
    public let stage: SPUUserUpdateStage
    public let userInitiated: Bool

    public init(stage: SPUUserUpdateStage = .notDownloaded, userInitiated: Bool = false) {
        self.stage = stage
        self.userInitiated = userInitiated
    }
}

public struct SPUDownloadData {
    public let data: Data
    public let url: URL?
    public let textEncodingName: String?
    public let mimeType: String?

    public init(data: Data = Data(), url: URL? = nil, textEncodingName: String? = nil, mimeType: String? = nil) {
        self.data = data
        self.url = url
        self.textEncodingName = textEncodingName
        self.mimeType = mimeType
    }
}

// MARK: - Permission request / response

public final class SUUpdatePermissionResponse: NSObject {
    public let automaticUpdateChecks: Bool
    public let sendSystemProfile: Bool

    public init(automaticUpdateChecks: Bool, sendSystemProfile: Bool) {
        self.automaticUpdateChecks = automaticUpdateChecks
        self.sendSystemProfile = sendSystemProfile
    }
}

public final class SPUUpdatePermissionRequest: NSObject {
    public let systemProfile: [[String: String]]
    private let replyHandler: (@Sendable (SUUpdatePermissionResponse) -> Void)?

    public init(
        systemProfile: [[String: String]] = [],
        reply: (@Sendable (SUUpdatePermissionResponse) -> Void)? = nil
    ) {
        self.systemProfile = systemProfile
        self.replyHandler = reply
    }

    public func reply(_ response: SUUpdatePermissionResponse) {
        replyHandler?(response)
    }
}

// MARK: - Appcast types

public final class SUAppcastItem: NSObject {
    // Real Sparkle exposes these as Obj-C non-null properties (implicitly
    // unwrapped optionals in Swift). cmux code reads them directly without
    // `?`, so we expose them as non-optional Strings with defaults.
    public let displayVersionString: String
    public let versionString: String
    public let fileURL: URL?
    public let releaseNotesURL: URL?
    public let dateString: String?
    public let date: Date?
    public let contentLength: UInt64

    private let backing: [String: Any]

    public init(dictionary: [String: Any]) {
        self.backing = dictionary
        self.displayVersionString = (dictionary["sparkle:shortVersionString"] as? String)
            ?? (dictionary["displayVersionString"] as? String)
            ?? ""
        self.versionString = (dictionary["sparkle:version"] as? String)
            ?? (dictionary["versionString"] as? String)
            ?? ""
        if let s = dictionary["url"] as? String { self.fileURL = URL(string: s) }
        else { self.fileURL = nil }
        if let s = dictionary["releaseNotesLink"] as? String { self.releaseNotesURL = URL(string: s) }
        else { self.releaseNotesURL = nil }
        self.dateString = dictionary["pubDate"] as? String ?? dictionary["dateString"] as? String
        self.date = dictionary["date"] as? Date
        self.contentLength = (dictionary["contentLength"] as? UInt64) ?? 0
        super.init()
    }

    @objc public static func empty() -> SUAppcastItem {
        SUAppcastItem(dictionary: [:])
    }
}

public final class SUAppcast: NSObject {
    public let items: [SUAppcastItem]

    public init(items: [SUAppcastItem] = []) {
        self.items = items
    }
}

// MARK: - Updater

/// Stub `SPUUpdater`. Never actually checks for updates; all methods are
/// no-ops or return placeholder values. cmux's UpdateController constructs
/// this and registers itself as the user driver / delegate, but the stub
/// never invokes any of those callbacks so no update UI ever fires.
public final class SPUUpdater: NSObject {
    public weak var userDriver: AnyObject?
    public weak var delegate: SPUUpdaterDelegate?
    public let hostBundle: Bundle
    public let applicationBundle: Bundle

    public var feedURL: URL?
    public var automaticallyChecksForUpdates: Bool = false
    public var automaticallyDownloadsUpdates: Bool = false
    public var updateCheckInterval: TimeInterval = 0
    public var sendsSystemProfile: Bool = false
    public var lastUpdateCheckDate: Date? = nil

    public init(
        hostBundle: Bundle,
        applicationBundle: Bundle,
        userDriver: SPUUserDriver?,
        delegate: SPUUpdaterDelegate?
    ) {
        self.hostBundle = hostBundle
        self.applicationBundle = applicationBundle
        self.userDriver = userDriver
        self.delegate = delegate
        super.init()
    }

    public func start() throws {}

    public func startUpdater() throws {}

    public func checkForUpdates() {}

    public func checkForUpdatesInBackground() {}

    public func checkForUpdateInformation() {}

    public func resetUpdateCycle() {}

    public func resetUpdateCycleAfterShortDelay() {}

    public var canCheckForUpdates: Bool { false }

    public var sessionInProgress: Bool { false }
}

// MARK: - SPUUserDriver protocol

public protocol SPUUserDriver: AnyObject {
    func show(
        _ request: SPUUpdatePermissionRequest,
        reply: @escaping @Sendable (SUUpdatePermissionResponse) -> Void
    )

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void)

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void
    )

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData)
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error)

    func showUpdateNotFoundWithError(_ error: any Error, acknowledgement: @escaping () -> Void)
    func showUpdaterError(_ error: any Error, acknowledgement: @escaping () -> Void)

    func showDownloadInitiated(cancellation: @escaping () -> Void)
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64)
    func showDownloadDidReceiveData(ofLength length: UInt64)
    func showDownloadDidStartExtractingUpdate()
    func showExtractionReceivedProgress(_ progress: Double)

    func showReady(toInstallAndRelaunch reply: @escaping @Sendable (SPUUserUpdateChoice) -> Void)
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    )
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void)

    func showUpdateInFocus()
    func dismissUpdateInstallation()
}

// Defaults so cmux's UpdateDriver doesn't need to implement every method.
public extension SPUUserDriver {
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: any Error) {}
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showDownloadDidStartExtractingUpdate() {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {}
    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        acknowledgement()
    }
    func showUpdateInFocus() {}
}

// MARK: - SPUUpdaterDelegate protocol

public protocol SPUUpdaterDelegate: AnyObject {
    func feedURLString(for updater: SPUUpdater) -> String?
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem)
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast)
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error)

    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval)
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater)
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    )
    func updaterWillRelaunchApplication(_ updater: SPUUpdater)
}

// Defaults — UpdateDelegate implements specific methods it cares about.
public extension SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? { nil }
    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }
    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {}
    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {}
    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {}
    func updater(_ updater: SPUUpdater, willScheduleUpdateCheckAfterDelay delay: TimeInterval) {}
    func updaterWillNotScheduleUpdateCheck(_ updater: SPUUpdater) {}
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool { false }
    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate item: SUAppcastItem,
        state: SPUUserUpdateState
    ) {}
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {}
}
