# Keep SF Symbols, draw the keycap yourself

Keep SF Symbols for both the keys and the row icons, draw the keycap in SwiftUI, and do not adopt an icon pack. Apple publishes no rule for key hints inside a custom panel: its design guidance covers only the four modifier glyphs and their order, and its writing guidance spells keys out as words. The stock Tab glyph is hard to read for a real reason, and no icon pack fixes it, because every set surveyed draws Tab with the same arrow-into-a-bar idea. What the palette can change is how the glyph is drawn: today the footer prints the Unicode characters ⇥, ⇧⇥ and ↩ as 12 pt monospaced text with no cap, and the row icons are 12 pt light. The recommended design puts each key in its own flat keycap, takes the glyphs from SF Symbols at medium weight, keeps "esc" as a word, names the key in a tooltip and in the VoiceOver label, and raises row icons to the row text's size and weight. A custom-drawn Tab symbol is a fallback for the Tab key only, if the stock glyph still fails once it is in a cap. No screenshots were inspected in this research, so every statement about how another app looks comes from documentation or source code, and the recommended numbers have not been tried on screen.

## Apple specifies four modifier glyphs and nothing about keycaps

The Human Interface Guidelines give a symbol table for Command, Shift, Option and Control only, and fix their order as **Control, Option, Shift, Command** ([HIG Keyboards](https://developer.apple.com/design/human-interface-guidelines/keyboards)). The same page shows no glyph for Tab, Return or Escape, writes "Shift-Tab" and "Esc" as words in its own shortcut tables, and adds no macOS-specific advice on displaying shortcuts. None of the HIG pages read (Keyboards, Menus, The menu bar, Toolbars, Search fields, Offering help, Buttons) says how to draw a key hint in a footer, palette or tooltip, and none mentions keycaps either way.

The glyphs for the other keys come from Apple's help pages. The Mac User Guide lists Return, Escape, "Tab Right" and "Tab Left" among the symbols menus use, always beside the key's name ([Mac User Guide](https://support.apple.com/guide/mac-help/cpmh0011/mac)). Apple's two pages disagree on Return: the support article prints ⏎, while the user guide's image is the hooked ↩ form that the SF Symbol `return` also uses ([Apple Support](https://support.apple.com/en-us/102650)). That Apple needs a help page titled "What are those symbols shown in menus on Mac?" suggests it knows the glyphs do not explain themselves.

The Apple Style Guide governs running text, not interface drawing. It capitalises key names, abbreviates only Escape and Function, treats a symbol after the name as optional, and has one sentence on drawn keys: graphic representations of key combinations take a plus sign between keys ([Apple Style Guide](https://support.apple.com/guide/applestyleguide/k-apsgf9067ae8/web)). So a word in a footer follows Apple's writing rules, a glyph follows its menu convention, and neither is prescribed for this case.

For small icons the guidance is firmer. Apple says to **match the weight of an icon to the adjacent text**, and to keep every interface icon in an app consistent in size, detail and stroke weight ([HIG Icons](https://developer.apple.com/design/human-interface-guidelines/icons)). Symbols come in nine weights that correspond to San Francisco's, and in three scales meant to change emphasis without breaking that match; outline variants suit lists, and enclosing shapes "can improve legibility at small sizes" ([HIG SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)). Apple gives no minimum point size for a symbol. The nearest figures are the macOS text default of 13 pt and minimum of 10 pt ([HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)). Text and icons up to 17 pt need 4.5:1 contrast, and any icon that carries meaning needs a text alternative ([HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility)). The palette's 12 pt light row icons beside regular-weight row text depart from the weight rule.

## SF Symbols has every bare key glyph but only two keycaps

The system set has carried `arrow.right.to.line` (Tab), `arrow.left.to.line`, `return`, `escape`, `shift`, `command`, `option` and `control` since 2019, so all of them are available on the app's macOS 26 target. Enclosed variants exist only for Command and the two tab arrows. There is no `return.square`, `escape.square`, `shift.square`, `option.square` or `control.square`, and no symbol named `tab` or `keycap`. These names were read from the SF Symbols metadata on a Mac running macOS 26.5 and confirmed by loading each name ([SF Symbols](https://developer.apple.com/sf-symbols/)). SwiftUI leaves a symbol unchanged when the requested variant does not exist ([symbolVariant](https://developer.apple.com/documentation/swiftui/view/symbolvariant(_:))). A consistent keycap therefore cannot come from stock enclosed symbols: the app has to draw the cap.

Using `Image(systemName:)` instead of Unicode characters also fixes a weight problem. A Unicode ⇥ is drawn by whichever font holds it and ignores symbol weight, so today the key glyphs and the row icons sit on different weight axes.

The licence allows all of this. Apple licenses system-provided images for developing applications for Apple-branded products, forbids them (and confusingly similar images) in app icons, logos and trademarks, and ties nothing to App Store distribution ([Xcode and Apple SDKs Agreement](https://www.apple.com/legal/sla/docs/xcode.pdf)). Ordinary symbols may be exported and edited into custom symbols; symbols depicting Apple products may not ([HIG SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)). That a Developer ID app is covered is a reading of the text, not an Apple statement. The notes cite the clause as section 2.11 in the Xcode copy installed locally and 2.10 in the web PDF dated June 2026; the wording matches.

## Verified apps use flat chips or bespoke key icons

Only four sources gave checkable drawing details, and all are flat: a border or a fill, no shadow or "3D key" effect.

| Source | How a key is drawn | Tab | Escape |
|---|---|---|---|
| VS Code | One bordered chip per key: 1 px border, 3 px radius, 11 px text, 3 × 5 px padding, 12 px minimum width, 4 px between chips | Not confirmed | Not confirmed |
| Zed | Purpose-drawn vector icons, muted, small, no chip | Own icon | Own icon |
| GitHub Primer (condensed) | One glyph per key | ⇥ | The word "Esc" |
| Raycast manual | Glyphs for ⇧ ⌘ ↵ | The word "Tab" | The word "Esc" |

VS Code's numbers come from its stylesheet, and on macOS it joins modifier glyphs with no separator while giving screen readers the spoken names ([keybindingLabel.css](https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/base/browser/ui/keybindingLabel/keybindingLabel.css), [keybindingLabels.ts](https://raw.githubusercontent.com/microsoft/vscode/main/src/vs/base/common/keybindingLabels.ts)). Zed maps Tab, Return, Escape and the arrows to its own icons instead of font glyphs, which is the one precedent for keeping Tab as a symbol without relying on the font's ⇥ ([Zed keybinding.rs](https://raw.githubusercontent.com/zed-industries/zed/main/crates/ui/src/components/keybinding.rs)). Primer says condensed glyphs should be "intuitive (not archaic)" and still falls back to a word for Escape, and it keeps a separate map of spoken key names ([Primer key-names.ts](https://raw.githubusercontent.com/primer/react/main/packages/react/src/KeybindingHint/key-names.ts)). Raycast, the closest product to this palette, writes "⇧ Tab" in its own manual ([Raycast Manual](https://manual.raycast.com/keyboard-shortcuts.md)).

The evidence on recognition is guidance and anecdote; no controlled study of ⇥, ⌥, ⌃ or ⎋ was found. Nielsen Norman Group says many users do not know what key symbols mean and advises always associating a symbol with the name of the key ([NN/g](https://www.nngroup.com/articles/ui-copy/)). On that evidence the word "Tab" in a cap is the best-supported choice, and the owner's preferred symbol-in-a-cap is the second, with Zed and Primer as precedent. The recommendation below honours the preference and adds the name where it costs no space.

One finding raises the stakes. Among the products checked, Tab never opens actions. It completes text in Alfred, scopes a search in Spotlight, and moves between fields in Raycast, while actions sit on ⌘K in Raycast and on the right arrow in Alfred ([Alfred Help](https://www.alfredapp.com/help/features/universal-actions/), [Mac User Guide: Spotlight](https://support.apple.com/guide/mac-help/mh26783), [Raycast Manual](https://manual.raycast.com/keyboard-shortcuts.md)). Keeping Tab is consistent with its "go deeper, Shift-Tab to come back" meaning, but users arrive without the association, so the footer hint is the only teacher.

## Icon packs add a dependency and no better Tab

No third-party pack has an actively developed official Swift package that behaves like SF Symbols. Phosphor's official SwiftUI package was last tagged in April 2024 ([phosphor-icons/swift](https://github.com/phosphor-icons/swift)). Lucide has no official Swift package, only two community ones that sync automatically ([lucide-icons-swift](https://github.com/JakubMazur/lucide-icons-swift), [lucide-swift](https://github.com/ajaxjiang96/lucide-swift)). Fluent's official package lives in a repository of about 915 MB with fixed pixel sizes ([fluentui-system-icons](https://github.com/microsoft/fluentui-system-icons)). Remix Icon moved to a custom licence in January 2026 ([Remix Icon License](https://github.com/Remix-Design/RemixIcon/blob/master/License)).

A pack icon in an ordinary image set is a tintable picture. Apple's description of custom symbols implies what it lacks: symbols align to the text baseline and cap height and adapt to text size, and only symbol image sets take symbol effects ([Creating custom symbols](https://developer.apple.com/documentation/technologyoverviews/custom-sf-symbols)). A pack in the palette would also sit apart from the system chrome around it, against Apple's consistency rule; that risk is reasoned, not measured against Liquid Glass.

On the question that started this, the packs offer nothing. Lucide's `arrow-right-to-line`, Phosphor's `arrow-line-right`, Tabler's `arrow-bar-to-right`, Material's `keyboard_tab` and Fluent's `Keyboard Tab` are all the arrow-and-bar. None ships a keycap family.

A custom symbol is the sound way to redraw one glyph. Apple's workflow is to duplicate a similar symbol in the SF Symbols app, export its template, edit the SVG and re-import it. A static template holding only the variants in use is enough for a glyph shown at one size and weight ([Creating custom symbols](https://developer.apple.com/documentation/technologyoverviews/custom-sf-symbols)). Apple advises against drawing enclosures into a custom symbol, which is another reason to keep the cap in code ([HIG SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)). NetNewsWire follows this pattern, with stock symbols and four custom symbol sets ([NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire)). Raycast took the opposite route and commissioned a full set, for an app with a deliberately non-system look ([Raycast blog](https://www.raycast.com/blog/a-fresh-look-and-feel)).

## Recommended design: one flat cap per key, glyphs from SF Symbols

The numbers below adapt VS Code's verified chip to the palette's 12 pt footer text. They are a starting point to check on screen, not measured values.

| Element | Recommendation |
|---|---|
| Keycap | One cap per key. 18 pt high, 18 pt minimum width, 5 pt horizontal padding for a word, 4 pt continuous corner radius. Subtle fill plus a 1 px border in the app's rule colour. Flat, no shadow. |
| Spacing | 3 pt between caps of one chord, no "+" (the Mac menu convention). 6 pt between a label and its cap. Label first, then cap, as now. |
| Glyph in cap | `Image(systemName:)` at 11 pt, medium weight, monochrome, in the muted colour if it reaches 4.5:1 on the footer, otherwise the ink colour. |
| Tab | `arrow.right.to.line` in a cap. Compare `arrow.right.to.line.compact` at the same size and keep the clearer one. Add `.help("Tab")` to the hint. |
| Shift-Tab | Two caps, `shift` then the same Tab glyph, in HIG order. Do not use `arrow.left.to.line`: the hint should show the same key the user just learned. |
| Return | `return` in a cap, replacing the Unicode ↩. It is the form Apple's user guide shows. |
| Esc | The word "esc" in a cap, as the palette already writes it. Primer and Raycast both avoid the ⎋ glyph. Apple's text style would capitalise it as "Esc". |
| Row icons | The row text's point size and regular weight (not 12 pt light), `imageScale(.small)` if they read too strong, outline variants, monochrome muted colour, centred in a fixed-width column of about 18 pt so titles align. |
| VoiceOver | One element per hint, glyph images hidden, key named in words: "Actions, Tab", "Back, Shift-Tab", "Open, Return" (or the current primary label), "Close, Escape". Today the hint's label is the title alone and the key is never spoken. |

The Tab row carries the main decision. The cap, the heavier weight and the tooltip are the cheap changes, and they should be judged on screen first. If the glyph still does not read as Tab, there are two fallbacks. The first keeps the owner's preference: a custom Tab symbol authored from the `arrow.right.to.line` template with a longer shaft and heavier bar tuned for 11 pt, as Zed does, in a static template. Only the Tab glyph needs redrawing; redrawing Return, Shift or the modifiers would move them away from the forms menus teach. The second fallback is the one the evidence favours most: the word "tab" in the same cap.

### What is unverified

- **Appearance of other apps.** No screenshots were inspected. How Raycast, Linear, Spotlight, Xcode's Open Quickly, Things, Notion, Slack, Arc or 1Password draw key hints and row icons, including chip geometry and icon sizes, is not established. Claims in this report rest on VS Code, Zed, Primer, Raycast's manual and Apple's documents only.
- **The recommended numbers.** The cap size, radius, spacing, 11 pt medium glyph and row icon size were not rendered or measured. The contrast of the muted colour on the palette's material was not measured in light or dark, or with Increase Contrast on.
- **Whether a redrawn Tab reads better.** No recognition study exists, and the candidate Tab glyphs were not compared side by side at small sizes.
- **VoiceOver.** How VoiceOver speaks ⇥, ↩ or ⎋ as text characters was not tested, which is one more reason to hide the glyphs and supply labels.
- **Key legends.** That US Apple keyboards print "tab" and "esc" as words while international layouts print glyphs is general knowledge, not sourced here.
- **Right-to-left.** Apple does not say whether a Tab hint should mirror. `arrow.right.to.line` does not mirror; the `forward` variant does.
- **Newer symbols.** Whether the 2026 SF Symbols release for macOS 27 added enclosed key variants or a keycap family was not checked. The Mac used runs macOS 26.5.
- **Licence details.** The licence text shown inside the SF Symbols app was not read, and whether that app flags any key glyph as non-customisable needs a look in its info panel before a custom Tab symbol is derived from Apple's template.
- **VS Code's Tab label.** Whether VS Code shows Tab as a word or a glyph on macOS was not confirmed from source.

## Conclusion

The choice among "SF Symbols, custom symbols, or a pack" turned out to matter less than where the glyph comes from and what surrounds it. The footer's legibility problem is mostly a text-rendering one: thin Unicode characters in a monospaced face, with no container, at a muted colour. Moving the same shapes to SF Symbols at a matched weight inside a cap changes all four of those at once and adds no asset or dependency.

Tab is the exception because its glyph is the least taught and the binding is unusual for a launcher. The glyph can stay if its name is one hover or one VoiceOver phrase away, and the design leaves room to swap in a custom drawing or the word without changing the cap. The next step is a side-by-side look at the three Tab candidates in the running palette, which will settle more than further reading.
