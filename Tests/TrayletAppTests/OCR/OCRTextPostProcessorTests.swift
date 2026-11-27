import Testing
@testable import TrayletApp

struct OCRTextPostProcessorTests {
    @Test func mergesCJKLinesWithoutExtraSpacesAndPreservesParagraphBreaks() {
        let input = "第一行文字\n第二行文字\r\n\r\n第三段开头\n第四行结尾"
        let output = OCRTextPostProcessor.mergeLineBreaks(input)
        #expect(output == "第一行文字第二行文字\n\n第三段开头第四行结尾")
    }

    @Test func mergesEnglishLinesWithSingleSpace() {
        let input = "Hello\nworld\n\nSecond\nparagraph"
        let output = OCRTextPostProcessor.mergeLineBreaks(input)
        #expect(output == "Hello world\n\nSecond paragraph")
    }

    @Test func joinsCJKAndLatinBoundaryWithoutExtraSpace() {
        let input = "中文\nEnglish\n继续"
        let output = OCRTextPostProcessor.mergeLineBreaks(input)
        #expect(output == "中文English继续")
    }
}
