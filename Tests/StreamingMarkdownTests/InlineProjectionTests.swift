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
  @Test func bracketsAndAParenWithProseAfterThemAreShownAsWritten() {
    // Whitespace not followed by a title or `)` means the `](` was not a link.
    #expect(InlineProjection.closed("call handlers[i](event and more") == "call handlers[i](event and more")
    #expect(InlineProjection.closed("call handlers[i](event a") == "call handlers[i](event a")
    #expect(InlineProjection.closed("f[i](x\ny **b") == "f[i](x\ny **b**")
    // Until the next character shows which it is, the link is still pending.
    #expect(InlineProjection.closed("call handlers[i](event ") == "call handlersi")
  }
  @Test func aTitleOrAnAngledDestinationKeepsTheLinkPending() {
    #expect(InlineProjection.closed("see [docs](https://e.com \"the ti") == "see docs")
    #expect(InlineProjection.closed("see [docs](https://e.com 'the ti") == "see docs")
    #expect(InlineProjection.closed("see [docs](https://e.com (the ti") == "see docs")
    #expect(InlineProjection.closed("see [docs](<my file> and") == "see docs")
    #expect(
      InlineProjection.closed("see [docs](https://e.com \"the title\") now")
        == "see [docs](https://e.com \"the title\") now")
    #expect(InlineProjection.closed("see [docs](https://e.com ) now") == "see [docs](https://e.com ) now")
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
      "call handlers[i](event and **more [l](u \"t i\") [m](<a b>) [n](x  ( y )) [o](p\nq) *z",
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
