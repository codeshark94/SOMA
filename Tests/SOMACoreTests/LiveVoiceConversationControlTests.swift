import Testing
@testable import SOMACore

struct LiveVoiceConversationControlTests {
    private let classifier = LiveVoiceConversationControlClassifier()

    @Test
    func explicitKoreanVoiceTerminationIsOwnedByTheHost() {
        #expect(classifier.classify("음성 끊어") == .endConversation)
        #expect(classifier.classify("음성 세션 종료해줘") == .endConversation)
        #expect(classifier.classify("말 그만해") == .endConversation)
        #expect(classifier.classify("종료 안 됐잖아. 종료할 줄 몰라?") == .endConversation)
    }

    @Test
    func negatedOrDescriptiveLanguageDoesNotEndTheConversation() {
        #expect(classifier.classify("음성 세션 종료하지 마") == nil)
        #expect(classifier.classify("대화를 끝내지 말고 계속해") == nil)
        #expect(classifier.classify("음성 세션 종료 기능이 어떻게 작동해?") == nil)
        #expect(classifier.classify("Please don't stop the voice session") == nil)
    }

    @Test
    func explicitEnglishAndCjkControlsAreRecognized() {
        #expect(classifier.classify("Stop the voice session") == .endConversation)
        #expect(classifier.classify("Please end this conversation") == .endConversation)
        #expect(classifier.classify("音声セッションを終了して") == .endConversation)
        #expect(classifier.classify("请结束语音会话") == .endConversation)
    }

    @Test
    func OrdinaryConversationIsNotAControlCommand() {
        #expect(classifier.classify("우리 태림이한테 재밌는 옛날이야기 해줘") == nil)
        #expect(classifier.classify("What happens at the end of the story?") == nil)
        #expect(classifier.classify("") == nil)
    }
}
