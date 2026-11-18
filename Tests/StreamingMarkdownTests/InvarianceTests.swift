import Foundation
import StreamingMarkdown
import Testing

private let names = corpus().map(\.name)

@Suite struct InvarianceTests {
  @Test func theCorpusIsThere() {
    #expect(names.count >= 11)
    #expect(corpus().allSatisfy { !$0.text.isEmpty })
  }

  @Test(arguments: names) func everyTwoWaySplitEndsInTheSameDocument(name: String) {
    let text = corpusText(name)
    let expected = MarkdownParser.parse(text)
    var cut = text.startIndex
    while true {
      var parser = MarkdownParser()
      parser.push(String(text[..<cut]))
      parser.push(String(text[cut...]))
      parser.finish()
      let offset = text.distance(from: text.startIndex, to: cut)
      #expect(parser.document == expected, "\(name) split at \(offset)")
      if cut == text.endIndex { break }
      cut = text.index(after: cut)
    }
  }

  @Test(arguments: names) func oneCharacterAtATimeEndsInTheSameDocument(name: String) {
    let text = corpusText(name)
    var parser = MarkdownParser()
    for character in text { parser.push(String(character)) }
    parser.finish()
    #expect(parser.document == MarkdownParser.parse(text))
  }

  @Test(arguments: names) func seededRandomSplitsEndInTheSameDocument(name: String) {
    let text = corpusText(name)
    let expected = MarkdownParser.parse(text)
    var rng = SplitMix64(seed: stableSeed(name))
    for round in 0..<200 {
      var parser = MarkdownParser()
      for piece in randomChunks(text, maxSize: 40, using: &rng) { parser.push(piece) }
      parser.finish()
      #expect(parser.document == expected, "\(name) round \(round)")
    }
  }

  @Test(arguments: names) func everyPrefixProjectsTheSameHoweverItArrived(name: String) {
    let text = corpusText(name)
    var stepped = MarkdownParser()
    var prefix = ""
    for character in text {
      stepped.push(String(character))
      prefix.append(character)
      var once = MarkdownParser()
      once.push(prefix)
      #expect(once.document == stepped.document, "\(name) prefix \(prefix.count)")
      if once.document != stepped.document { return }
    }
  }

  @Test(arguments: names) func aCommittedBlockNeverChanges(name: String) {
    let text = corpusText(name)
    let final = MarkdownParser.parse(text).blocks
    var parser = MarkdownParser()
    var count = 0
    for character in text {
      parser.push(String(character))
      count += 1
      let blocks = parser.document.blocks
      for index in 0..<max(0, blocks.count - 1) {
        let ok = index < final.count && blocks[index] == final[index]
        #expect(ok, "\(name) block \(index) changed after \(count) characters")
        if !ok { return }
      }
    }
  }
}
