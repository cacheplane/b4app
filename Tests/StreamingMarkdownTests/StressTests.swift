import Foundation
import StreamingMarkdown
import Testing

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

  @Test func oneHundredThousandCharactersOneAtATimeStayLinear() {
    let unit = corpusText("mixed-reply.md")
    #expect(!unit.isEmpty)
    var text = ""
    while text.count < 100_000 { text += unit }
    let characters = Array(text.prefix(100_000))
    var parser = MarkdownParser()
    let clock = ContinuousClock()
    var halves: [Duration] = []
    let total = clock.measure {
      for half in 0..<2 {
        let range = (half * 50_000)..<((half + 1) * 50_000)
        halves.append(
          clock.measure {
            for index in range {
              parser.push(String(characters[index]))
              if index % 16 == 0 { _ = parser.document }
            }
          })
      }
    }
    print("stress: 100k per character \(total), halves \(halves)")
    #expect(total < .seconds(4))
    #expect(halves[1] < halves[0] * 3)
  }

  @Test func oneLongLineWithNoNewlineStaysLinear() {
    let unit = "{\"k\":\"v **x** `y` [z](u)\","
    var text = ""
    while text.count < 100_000 { text += unit }
    let characters = Array(text.prefix(100_000))
    var parser = MarkdownParser()
    let clock = ContinuousClock()
    let total = clock.measure {
      var index = 0
      while index < characters.count {
        let end = min(index + 64, characters.count)
        parser.push(String(characters[index..<end]))
        _ = parser.document
        index = end
      }
    }
    print("stress: one long line \(total)")
    #expect(total < .seconds(4))
  }
}
