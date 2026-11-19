import Foundation
import StreamingMarkdown
import Testing

/// Linear cost on long input is checked by `ParserTimingTests`, which runs only with `B4APP_TIMING`.
@Suite struct StressTests {
  @Test func adversarialInputNeverCrashes() {
    let alphabet = Array("*_`[]()!\\#>|-~:. \n\t\r0123456789ax")
    var rng = SplitMix64(seed: 0x5EED)
    for _ in 0..<500 {
      let length = Int.random(in: 0...400, using: &rng)
      let text = String((0..<length).map { _ in alphabet.randomElement(using: &rng)! })
      var parser = MarkdownParser()
      for piece in text.isEmpty ? [] : randomChunks(text, maxSize: 12, using: &rng) {
        parser.push(piece)
        _ = parser.document
      }
      parser.finish()
      _ = parser.document
    }
  }
}
