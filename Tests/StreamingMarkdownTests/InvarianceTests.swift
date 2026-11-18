import Foundation
import StreamingMarkdown
import Testing

private let names = corpus().map(\.name)

@Suite struct InvarianceTests {
  @Test func theCorpusIsThere() {
    #expect(names.count >= 11)
    #expect(corpus().allSatisfy { !$0.text.isEmpty })
  }

  @Test(arguments: names) func everyTwoWaySplitEndsInTheSameDocument(name: String) throws {
    let text = try corpusText(name)
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

  @Test(arguments: names) func everyTwoWayScalarSplitEndsInTheSameDocument(name: String) throws {
    // Cuts on unicode-scalar offsets, so a cut can fall between the "\r" and "\n" of one Character.
    let scalars = try corpusText(name).unicodeScalars
    let expected = MarkdownParser.parse(String(scalars))
    var cut = scalars.startIndex
    while true {
      var parser = MarkdownParser()
      parser.push(String(scalars[..<cut]))
      parser.push(String(scalars[cut...]))
      parser.finish()
      let offset = scalars.distance(from: scalars.startIndex, to: cut)
      #expect(parser.document == expected, "\(name) split at scalar \(offset)")
      if cut == scalars.endIndex { break }
      cut = scalars.index(after: cut)
    }
  }

  @Test func adversarialTextCutOnScalarsEndsInTheSameDocument() {
    let alphabet = Array("*_`[]()!\\#>|-~:. \n\t\r0123456789ax".unicodeScalars)
    var rng = SplitMix64(seed: 0x0C0D)
    for round in 0..<300 {
      let length = Int.random(in: 0...200, using: &rng)
      let scalars = (0..<length).map { _ in alphabet.randomElement(using: &rng)! }
      let expected = MarkdownParser.parse(String(String.UnicodeScalarView(scalars)))
      var parser = MarkdownParser()
      var index = 0
      while index < scalars.count {
        let end = min(index + Int.random(in: 1...6, using: &rng), scalars.count)
        parser.push(String(String.UnicodeScalarView(scalars[index..<end])))
        index = end
      }
      parser.finish()
      #expect(parser.document == expected, "round \(round)")
    }
  }

  @Test func aCarriageReturnBeforeACrlfIsKeptHoweverItArrives() {
    let text = "a\r\r\nb"
    let expected = MarkdownParser.parse(text)
    var scalarByScalar = MarkdownParser()
    for scalar in text.unicodeScalars { scalarByScalar.push(String(scalar)) }
    scalarByScalar.finish()
    var characterByCharacter = MarkdownParser()
    for character in text { characterByCharacter.push(String(character)) }
    characterByCharacter.finish()
    #expect(scalarByScalar.document == expected)
    #expect(characterByCharacter.document == expected)
    // One "\r" before the "\n" ends the line; the other is trailing whitespace of the line "a\r".
    #expect(outline(expected) == "p \"a b\"")
  }

  @Test(arguments: names) func oneCharacterAtATimeEndsInTheSameDocument(name: String) throws {
    let text = try corpusText(name)
    var parser = MarkdownParser()
    for character in text { parser.push(String(character)) }
    parser.finish()
    #expect(parser.document == MarkdownParser.parse(text))
  }

  @Test(arguments: names) func seededRandomSplitsEndInTheSameDocument(name: String) throws {
    let text = try corpusText(name)
    let expected = MarkdownParser.parse(text)
    var rng = SplitMix64(seed: stableSeed(name))
    for round in 0..<200 {
      var parser = MarkdownParser()
      for piece in randomChunks(text, maxSize: 40, using: &rng) { parser.push(piece) }
      parser.finish()
      #expect(parser.document == expected, "\(name) round \(round)")
    }
  }

  @Test(arguments: names) func everyPrefixProjectsTheSameHoweverItArrived(name: String) throws {
    let text = try corpusText(name)
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

  @Test(arguments: names) func aCommittedBlockNeverChanges(name: String) throws {
    let text = try corpusText(name)
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
