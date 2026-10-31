import Testing
@testable import TrayletApp

struct AuthorizationGateTests {
    @Test func featuresStayLockedUntilWelcomeCompletes() {
        #expect(!V2AuthorizationGate.allowsFeatures(welcomeCompleted: false))
        #expect(V2AuthorizationGate.allowsFeatures(welcomeCompleted: true))
    }

    @Test func welcomeCannotCompleteWithoutScreenRecording() {
        #expect(!V2AuthorizationGate.canComplete(screenRecordingGranted: false))
        #expect(V2AuthorizationGate.canComplete(screenRecordingGranted: true))
    }
}
