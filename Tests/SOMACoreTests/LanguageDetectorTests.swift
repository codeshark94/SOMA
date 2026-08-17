import XCTest
@testable import SOMACore

final class LanguageDetectorTests: XCTestCase {
    func testDetectsKorean() {
        XCTAssertEqual(LanguageDetector.detectTag(from: "안녕하세요 오늘 날씨가 좋네요"), "ko")
    }

    func testDetectsJapanese() {
        XCTAssertEqual(LanguageDetector.detectTag(from: "こんにちは、今日はいい天気ですね"), "ja")
    }

    func testDetectsChinese() {
        XCTAssertEqual(LanguageDetector.detectTag(from: "你好，今天天气很好"), "zh")
    }

    func testDetectsEnglish() {
        XCTAssertEqual(LanguageDetector.detectTag(from: "Hello, how are you doing today"), "en")
    }

    func testDetectsCyrillic() {
        XCTAssertEqual(LanguageDetector.detectTag(from: "Привет, как дела сегодня"), "ru")
    }

    func testEmptyOrTooShortReturnsNil() {
        XCTAssertNil(LanguageDetector.detectTag(from: ""))
        XCTAssertNil(LanguageDetector.detectTag(from: "  "))
        XCTAssertNil(LanguageDetector.detectTag(from: "ab"))
    }

    func testMixedKoreanDominates() {
        XCTAssertEqual(LanguageDetector.detectTag(from: "안녕하세요 hello world"), "ko")
    }
}
