// Nix-build stub for `import PostHog`.
//
// The real posthog-ios SDK vendors PHPLCrashReporter (Objective-C/C++) which
// fails to compile under nixpkgs' cc-wrapper + apple-sdk-14.4 combination:
// the Foundation.h precompiled headers don't propagate Objective-C language
// mode to nested PCH consumers, and PLCrashReporter's resource_bundle_accessor.m
// errors out on `@class NSString;`.
//
// cmux uses PostHog purely for opt-in usage telemetry (PostHogAnalytics.swift).
// Stubbing it out has no functional impact for "try it out" builds. When the
// app calls .shared.setup / .register / .capture / .flush these become no-ops.
//
// Surface required by Sources/PostHogAnalytics.swift only.

import Foundation

public final class PostHogConfig {
    public var captureApplicationLifecycleEvents: Bool = false
    public var captureScreenViews: Bool = false
    public var debug: Bool = false
    public let apiKey: String
    public let host: String

    public init(apiKey: String, host: String) {
        self.apiKey = apiKey
        self.host = host
    }
}

public final class PostHogSDK {
    public static let shared = PostHogSDK()
    private init() {}

    public func setup(_ config: PostHogConfig) {}
    public func register(_ properties: [String: Any]) {}
    public func capture(_ event: String, properties: [String: Any]? = nil) {}
    public func flush() {}
}
