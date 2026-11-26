import Testing
@testable import TrayletApp

struct AuthorizationGateTests {
    @Test func featuresStayLockedUntilWelcomeCompletes() {
        #expect(!AuthorizationGate.allowsFeatures(welcomeCompleted: false))
        #expect(AuthorizationGate.allowsFeatures(welcomeCompleted: true))
    }

    @Test func welcomeCannotCompleteWithoutScreenRecording() {
        #expect(!AuthorizationGate.canComplete(screenRecordingGranted: false))
        #expect(AuthorizationGate.canComplete(screenRecordingGranted: true))
    }
}
