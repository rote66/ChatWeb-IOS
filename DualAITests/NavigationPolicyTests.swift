import XCTest
@testable import DualAI

final class NavigationPolicyTests: XCTestCase {
    private let policy = NavigationPolicy()

    func testTrustedChatGPTAndOpenAISubdomainsStayInWebView() {
        XCTAssertEqual(policy.decision(for: URL(string: "https://chatgpt.com/c/123")!), .allowInWebView)
        XCTAssertEqual(policy.decision(for: URL(string: "https://auth.openai.com/login")!), .allowInWebView)
    }

    func testKnownAuthenticationHostCanStayInWebView() {
        XCTAssertEqual(policy.decision(for: URL(string: "https://accounts.google.com/signin")!), .allowInWebView)
        XCTAssertTrue(policy.isAuthenticationURL(URL(string: "https://login.microsoftonline.com/common")!))
    }

    func testExactCloudflareChallengeHostStaysInWebViewButIsNotPersisted() {
        let challenge = URL(string: "https://challenges.cloudflare.com/cdn-cgi/challenge-platform/test")!
        XCTAssertEqual(policy.decision(for: challenge), .allowInWebView)
        XCTAssertNil(policy.safeURLForPersistence(challenge))
        XCTAssertEqual(policy.decision(for: URL(string: "https://example.cloudflare.com/")!), .openInSafari)
    }

    func testUnknownAndMisleadingHostsOpenInSafari() {
        XCTAssertEqual(policy.decision(for: URL(string: "https://example.com/help")!), .openInSafari)
        XCTAssertEqual(policy.decision(for: URL(string: "https://chatgpt.com.evil.example/")!), .openInSafari)
        XCTAssertEqual(policy.decision(for: URL(string: "https://maps.google.com/")!), .openInSafari)
    }

    func testWebKitAndSystemSchemesAreHandledWithoutBroadeningWebAccess() {
        XCTAssertEqual(policy.decision(for: URL(string: "about:blank")!), .allowInWebView)
        XCTAssertEqual(policy.decision(for: URL(string: "about:blank#blocked")!), .allowInWebView)
        XCTAssertEqual(policy.decision(for: URL(string: "about:srcdoc")!), .rejectUnsupported)
        XCTAssertEqual(policy.decision(for: URL(string: "mailto:test@example.com")!), .openInSystem)
        XCTAssertEqual(policy.decision(for: URL(string: "tel:+123456789")!), .openInSystem)
        XCTAssertEqual(policy.decision(for: URL(string: "javascript:alert(1)")!), .rejectUnsupported)
        XCTAssertEqual(policy.decision(for: URL(string: "file:///private/data")!), .rejectUnsupported)
        XCTAssertEqual(policy.decision(for: URL(string: "blob:https://chatgpt.com/id")!), .blobDownloadUnavailable)
    }

    func testExternalNavigationRequiresAnExplicitUserAction() {
        XCTAssertFalse(policy.shouldOpenExternally(.openInSafari, userInitiated: false))
        XCTAssertFalse(policy.shouldOpenExternally(.openInSystem, userInitiated: false))
        XCTAssertTrue(policy.shouldOpenExternally(.openInSafari, userInitiated: true))
        XCTAssertTrue(policy.shouldOpenExternally(.openInSystem, userInitiated: true))
        XCTAssertFalse(policy.shouldOpenExternally(.allowInWebView, userInitiated: true))
    }

    func testSafeURLPersistenceRejectsSensitiveLocations() {
        XCTAssertNotNil(policy.safeURLForPersistence(URL(string: "https://chatgpt.com/c/abc")!))
        XCTAssertNil(policy.safeURLForPersistence(NavigationPolicy.chatGPTLoginURL))
        XCTAssertNil(policy.safeURLForPersistence(URL(string: "https://chatgpt.com/api/auth/callback?code=secret")!))
        XCTAssertNil(policy.safeURLForPersistence(URL(string: "https://chatgpt.com/logout")!))
        XCTAssertNil(policy.safeURLForPersistence(URL(string: "https://chatgpt.com/c/abc?token=secret")!))
        XCTAssertNil(policy.safeURLForPersistence(URL(string: "https://chatgpt.com/?q=private-prompt")!))
        XCTAssertNil(policy.safeURLForPersistence(URL(string: "https://accounts.google.com/signin")!))
    }

    func testBenignQueryOnTrustedURLMayBePersisted() {
        XCTAssertNotNil(policy.safeURLForPersistence(URL(string: "https://chatgpt.com/?model=auto")!))
    }

    func testOfficialServiceEntryPoints() {
        XCTAssertEqual(NavigationPolicy.geminiHomeURL.absoluteString, "https://gemini.google.com/app")
        XCTAssertEqual(NavigationPolicy(service: .gemini).homeURL, NavigationPolicy.geminiHomeURL)
        XCTAssertEqual(NavigationPolicy(service: .gemini).loginURL, NavigationPolicy.geminiLoginURL)
        XCTAssertTrue(policy.isChatGPTLoginURL(NavigationPolicy.chatGPTLoginURL))
        XCTAssertTrue(policy.isAuthenticationURL(NavigationPolicy.chatGPTLoginURL))
    }

    func testGeminiPolicyKeepsOnlyGeminiAndGoogleLoginInWebView() {
        let geminiPolicy = NavigationPolicy(service: .gemini)
        XCTAssertEqual(geminiPolicy.decision(for: URL(string: "https://gemini.google.com/app")!), .allowInWebView)
        XCTAssertEqual(geminiPolicy.decision(for: URL(string: "https://accounts.google.com/ServiceLogin")!), .allowInWebView)
        XCTAssertEqual(geminiPolicy.decision(for: URL(string: "https://maps.google.com/")!), .openInSafari)
        XCTAssertEqual(geminiPolicy.decision(for: URL(string: "https://challenges.cloudflare.com/test")!), .openInSafari)
    }

    func testGeminiSafeURLPersistenceExcludesLoginAndSensitiveQueries() {
        let geminiPolicy = NavigationPolicy(service: .gemini)
        XCTAssertNotNil(geminiPolicy.safeURLForPersistence(URL(string: "https://gemini.google.com/app")!))
        XCTAssertNotNil(geminiPolicy.safeURLForPersistence(URL(string: "https://gemini.google.com/app?hl=zh-CN")!))
        XCTAssertNil(geminiPolicy.safeURLForPersistence(NavigationPolicy.geminiLoginURL))
        XCTAssertNil(geminiPolicy.safeURLForPersistence(URL(string: "https://gemini.google.com/app?token=secret")!))
    }
}
