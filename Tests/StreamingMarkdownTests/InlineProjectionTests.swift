import Testing

@testable import StreamingMarkdown

@Suite struct InlineProjectionTests {
  @Test func closesUnfinishedEmphasis() {
    #expect(InlineProjection.closed("a **bo") == "a **bo**")
    #expect(InlineProjection.closed("a *it") == "a *it*")
    #expect(InlineProjection.closed("~~gone") == "~~gone~~")
    #expect(InlineProjection.closed("**bold *it") == "**bold *it***")
    #expect(InlineProjection.closed("run `ls -") == "run `ls -`")
  }
  @Test func leavesArithmeticAndFinishedMarkupAlone() {
    #expect(InlineProjection.closed("2 * 3") == "2 * 3")
    #expect(InlineProjection.closed("**done** and") == "**done** and")
    #expect(InlineProjection.closed("snake_case_name") == "snake_case_name")
    #expect(InlineProjection.closed("`a * b`") == "`a * b`")
  }
  @Test func holdsATrailingOpenerWithNothingAfterIt() {
    #expect(InlineProjection.closed("a **") == "a ")
    #expect(InlineProjection.closed("a `") == "a ")
  }
  @Test func aHalfTypedLinkShowsItsTextOnly() {
    #expect(InlineProjection.closed("see [the docs](https://exa") == "see the docs")
    #expect(
      InlineProjection.closed("see [the docs](https://example.com) now")
        == "see [the docs](https://example.com) now")
    #expect(InlineProjection.closed("see [the do") == "see [the do")
    #expect(InlineProjection.closed("![a cat](http") == "a cat")
  }
  @Test func aScanKeptAcrossReadsEqualsAFreshScanAtEveryPrefix() {
    let lines = [
      "see [the docs](https://example.com) and **bold *it** `code` ~~gone~~ end",
      "` a ``b`` c ` then **x",
      "a ` b ` c `d e",
      "![a cat](http://x/y) _it_ snake_case \\*not\\* **",
      "**bold *it`code **in* code` done ***",
      "[link **b](u `x` ) **after [open](par",
      "é_b_ ~one~ ~~two~~~ `` a ` b `` [x] [y](",
    ]
    for line in lines {
      var kept = InlineProjection.Scan()
      var prefix = ""
      for character in line {
        prefix.append(character)
        #expect(kept.closed(prefix) == InlineProjection.closed(prefix), "at \(prefix.debugDescription)")
      }
    }
  }
  @Test func aScanGivenTextThatDoesNotExtendItStartsAgain() {
    var kept = InlineProjection.Scan()
    _ = kept.closed("a **bold")
    #expect(kept.closed("a *it") == "a *it*")
    #expect(kept.closed("") == "")
  }
}
