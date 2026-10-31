import Foundation
import Combine
import Testing
@testable import TrayletApp

@Suite("Localization") @MainActor struct LocalizationTests {
    @Test func systemLanguageUsesSupportedPreferenceOrder() {
        #expect(V2Localization.usesEnglish(["en-US", "zh-Hans"]))
        #expect(!V2Localization.usesEnglish(["zh-Hans-CN", "en-US"]))
        #expect(!V2Localization.usesEnglish(["zh-Hant-TW"]))
        #expect(!V2Localization.usesEnglish(["fr-FR", "zh_Hans", "en"]))
        #expect(V2Localization.usesEnglish(["fr-FR", "en-GB", "zh"]))
        #expect(V2Localization.usesEnglish(["fr-FR"]))
        #expect(V2Localization.usesEnglish([]))
    }

    @Test func explicitLanguageOverridesInjectedSystemLanguage() {
        let chineseSystem = V2Localization(preferredLanguages: { ["zh-Hans"] })
        #expect(!chineseSystem.english)
        #expect(chineseSystem.text("设置") == "设置")
        chineseSystem.languageCode = "en"
        #expect(chineseSystem.english)
        #expect(chineseSystem.text("设置") == "Settings")
        chineseSystem.languageCode = ""
        #expect(!chineseSystem.english)

        let englishSystem = V2Localization(preferredLanguages: { ["en-US"] })
        #expect(englishSystem.text("复制原文") == "Copy Source")
        englishSystem.languageCode = "zh-Hans"
        #expect(englishSystem.text("复制原文") == "复制原文")
    }

    @Test func followingSystemReadsCurrentLanguageAndUnknownPreferenceFallsBackToSystem() {
        var languages = ["zh-Hans"]
        let localization = V2Localization(preferredLanguages: { languages })
        #expect(!localization.english)
        languages = ["en-US"]
        #expect(localization.english)
        localization.languageCode = "unsupported"
        #expect(localization.english)
    }

    @Test func languageChangesPublishForViewsAndAppKitObservers() {
        let localization = V2Localization(preferredLanguages: { ["zh-Hans"] })
        var codes: [String] = []
        var changes = 0
        let language = localization.$languageCode.sink { codes.append($0) }
        let object = localization.objectWillChange.sink { changes += 1 }
        localization.languageCode = "en"
        #expect(localization.text("删除") == "Delete")
        localization.languageCode = "zh-Hans"
        #expect(localization.text("删除") == "删除")
        #expect(codes == ["", "en", "zh-Hans"])
        #expect(changes == 2)
        withExtendedLifetime((language, object)) {}
    }

    @Test func realInterfaceCopyIncludesErrorsAccessibilityAndConfirmation() {
        let localization = V2Localization(languageCode: "en")
        let examples = [
            ("区域截图", "Region Capture"),
            ("翻译引擎：系统翻译", "Translation Engine: System Translation"),
            ("互换语言", "Swap Languages"),
            ("朗读译文", "Speak Translation"),
            ("暂无匹配历史", "No Matching History"),
            ("清空剪贴板历史？", "Clear clipboard history?"),
            ("模糊画笔直径", "Blur Brush Diameter"),
            ("高斯模糊", "Gaussian Blur"),
            ("未保存的编辑会丢失。", "Unsaved edits will be lost."),
            ("服务拒绝凭据，请检查 API Key。", "The service rejected your credentials. Check the API Key."),
            ("已取消截图文字识别；已有原文和译文已保留。", "Screenshot text recognition cancelled. Your existing source text and translation are preserved.")
        ]
        for (source, expected) in examples { #expect(localization.text(source) == expected) }
    }

    @Test func knownTemplatesLocalizeLabelsAndKeepInsertedValuesVerbatim() {
        let localization = V2Localization(languageCode: "en")
        #expect(String(format: localization.text("%d / %d 条 · 保留 %d 天"), 3, 100, 7) == "3 / 100 items · Keep for 7 days")
        #expect(String(format: localization.text("%d 条"), 100) == "100 items")
        #expect(String(format: localization.text("系统注册失败（%d）。请选择其他组合；原绑定保留。"), -9878) == "System registration failed (-9878). Choose another shortcut; your previous binding is unchanged.")
        let model = "用户模型 %s / 设置"
        #expect(String(format: localization.text("模型：%@"), model) == "Model: " + model)
        let destination = "http://localhost:1234/v1"
        #expect(String(format: localization.text("目标：%@"), destination) == "Destination: " + destination)
    }

    @Test func unknownContentIsNeverPartiallyTranslated() {
        let localization = V2Localization(languageCode: "en")
        for content in ["用户正文：设置、复制原文。", "模型：我的模型", "未识别的错误 123", "设置\n我的私人笔记", "https://example.com/设置", "English text", "", "🧪 中文 café"] {
            #expect(localization.text(content) == content)
        }
    }

    @Test func catalogPreservesFormatPlaceholders() throws {
        let expression = try NSRegularExpression(pattern: "%[ds@]")
        func placeholders(_ value: String) -> [String] {
            expression.matches(in: value, range: NSRange(value.startIndex..., in: value)).map { (value as NSString).substring(with: $0.range) }
        }
        for (source, translation) in V2English.strings {
            #expect(!source.isEmpty && !translation.isEmpty)
            #expect(placeholders(source) == placeholders(translation))
        }
    }
}
