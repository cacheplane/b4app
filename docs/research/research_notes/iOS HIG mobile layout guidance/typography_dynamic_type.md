# iOS typography and Dynamic Type for a SwiftUI app with custom fonts (Hanken Grotesk, JetBrains Mono), iOS 26

Source notes. The HIG pages are JavaScript-rendered, so I read the tables from Apple's own DocC JSON behind each page (for example `https://developer.apple.com/tutorials/data/design/human-interface-guidelines/typography.json`). That is the same content the page shows, not a mirror. The Typography page's newest change-log entry is December 16, 2025 ("Added emphasized weights to the Dynamic Type style specifications for each platform"), so the tables below are the current revision for the iOS 26 era. Items marked **[Measured, iOS 26.5 Simulator]** come from small Swift programs I compiled with `swiftc -target arm64-apple-ios26.0-simulator` and ran with `xcrun simctl spawn` on a booted iPhone 17 Pro simulator running iOS 26.5 (23F77). They call `UIFont.preferredFont(forTextStyle:compatibleWith:)`, `UIFontMetrics.scaledValue(for:compatibleWith:)` / `scaledFont(for:compatibleWith:)`, and SwiftUI `Font.resolve(in: EnvironmentValues().fontResolutionContext).pointSize` for each `DynamicTypeSize`. They are observations of the shipping OS, not Apple documentation.

## What are the iOS text styles and their sizes, weights and leading at each Dynamic Type size (Large default, xSmall…xxxLarge, AX1–AX5)?

### Takeaway
At the default Large size, iOS body is 17 pt on 22 pt leading. Large Title is 34/41, Title 1 28/34, Title 2 22/28, Title 3 20/25, Headline 17/22 Semibold, Callout 16/21, Subhead 15/20, Footnote 13/18, Caption 1 12/16, and Caption 2 11/13. Body reaches 23/29 at xxxLarge and 53/62 at AX5. Small styles grow much more than large ones: Caption 2 grows 3.6x by AX5, Large Title only 1.76x. Every style is Regular except Headline, which is Semibold. The bold ("emphasized") variant is Bold for the titles and Semibold for everything else.

### Cited Findings
- A text style "specifies a combination of font weight, point size, and leading values for each text size". Text styles "allow text to scale proportionately when people change the system's text size". — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- Emphasized variants come from symbolic traits: SwiftUI `bold()`, UIKit `traitBold`. "The emphasized weights can be medium, semibold, bold, or heavy." — [HIG Typography, Specifications](https://developer.apple.com/design/human-interface-guidelines/typography)
- The weight is the same at every size. Regular for every style except Headline (Semibold). Emphasized weight is Bold for Large Title, Title 1 and Title 2, and Semibold for Title 3 through Caption 2. — [HIG Typography, Specifications](https://developer.apple.com/design/human-interface-guidelines/typography)
- **iOS/iPadOS Dynamic Type sizes, size/leading in points** (transcribed from the HIG "iOS, iPadOS Dynamic Type sizes" and "iOS, iPadOS larger accessibility type sizes" tabs) — [HIG Typography, Specifications](https://developer.apple.com/design/human-interface-guidelines/typography):

| Style (SwiftUI) | xSmall | Small | Medium | **Large (default)** | xLarge | xxLarge | **xxxLarge** | AX1 | AX2 | AX3 | AX4 | **AX5** |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Large Title (`.largeTitle`) | 31/38 | 32/39 | 33/40 | **34/41** | 36/43 | 38/46 | **40/48** | 44/52 | 48/57 | 52/61 | 56/66 | **60/70** |
| Title 1 (`.title`) | 25/31 | 26/32 | 27/33 | **28/34** | 30/37 | 32/39 | **34/41** | 38/46 | 43/51 | 48/57 | 53/62 | **58/68** |
| Title 2 (`.title2`) | 19/24 | 20/25 | 21/26 | **22/28** | 24/30 | 26/32 | **28/34** | 34/41 | 39/47 | 44/52 | 50/59 | **56/66** |
| Title 3 (`.title3`) | 17/22 | 18/23 | 19/24 | **20/25** | 22/28 | 24/30 | **26/32** | 31/38 | 37/44 | 43/51 | 49/58 | **55/65** |
| Headline (`.headline`, Semibold) | 14/19 | 15/20 | 16/21 | **17/22** | 19/24 | 21/26 | **23/29** | 28/34 | 33/40 | 40/48 | 47/56 | **53/62** |
| Body (`.body`) | 14/19 | 15/20 | 16/21 | **17/22** | 19/24 | 21/26 | **23/29** | 28/34 | 33/40 | 40/48 | 47/56 | **53/62** |
| Callout (`.callout`) | 13/18 | 14/19 | 15/20 | **16/21** | 18/23 | 20/25 | **22/28** | 26/32 | 32/39 | 38/46 | 44/52 | **51/60** |
| Subhead (`.subheadline`) | 12/16 | 13/18 | 14/19 | **15/20** | 17/22 | 19/24 | **21/28** | 25/31 | 30/37 | 36/43 | 42/50 | **49/58** |
| Footnote (`.footnote`) | 12/16 | 12/16 | 12/16 | **13/18** | 15/20 | 17/22 | **19/24** | 23/29 | 27/33 | 33/40 | 38/46 | **44/52** |
| Caption 1 (`.caption`) | 11/13 | 11/13 | 11/13 | **12/16** | 14/19 | 16/21 | **18/23** | 22/28 | 26/32 | 32/39 | 37/44 | **43/51** |
| Caption 2 (`.caption2`) | 11/13 | 11/13 | 11/13 | **11/13** | 13/18 | 15/20 | **17/22** | 20/25 | 24/30 | 29/35 | 34/41 | **40/48** |

- AX1–AX5 correspond to `DynamicTypeSize.accessibility1…accessibility5`. Those are UIKit's `.accessibilityMedium`, `.accessibilityLarge`, `.accessibilityExtraLarge`, `.accessibilityExtraExtraLarge` and `.accessibilityExtraExtraExtraLarge`. "The five sizes whose names begin with `accessibility` are much larger than the rest." — [DynamicTypeSize](https://developer.apple.com/documentation/swiftui/dynamictypesize)
- There are 7 standard sizes by default. Turning on Larger Accessibility Sizes (Settings > Accessibility > Display & Text Size > Larger Text) adds 5 more. The text-size control can also go in Control Center. — [WWDC24 "Get started with Dynamic Type"](https://developer.apple.com/videos/play/wwdc2024/10074/)
- The default `dynamicTypeSize` environment value "is device-dependent". On macOS it can't be changed and doesn't affect text size. — [EnvironmentValues.dynamicTypeSize](https://developer.apple.com/documentation/swiftui/environmentvalues/dynamictypesize)
- **[Measured, iOS 26.5 Simulator]** `UIFont.preferredFont(forTextStyle:compatibleWith:)` returns exactly the HIG point sizes above for all 11 styles × 12 sizes. For example, body is 14, 15, 16, 17, 19, 21, 23, 28, 33, 40, 47, 53 and caption2 is 11, 11, 11, 11, 13, 15, 17, 20, 24, 29, 34, 40. So the HIG table matches iOS 26.5. SwiftUI's `.body` / `.footnote` / `.caption2` resolve to the same sizes through `Font.resolve(in:)`.
- **[Measured, iOS 26.5 Simulator]** The SF font's `UIFont.lineHeight` (ascender + descender) is smaller than the HIG "leading". Body at Large is 20.3 pt vs the HIG's 22 pt, and 63.2 pt vs 62 at AX5. The HIG "Leading" column is the designed line-to-line spacing, not the font's intrinsic line height.
- Tracking: the HIG publishes per-size tracking for SF Pro, for example +0.06 pt at 11 pt, −0.43 pt at 17 pt and +0.40 pt at 34 pt. "In a running app, the system font dynamically adjusts tracking at every point size". The tables exist so mockups are accurate. — [HIG Typography, Tracking values](https://developer.apple.com/design/human-interface-guidelines/typography)
- You can download the Dynamic Type size tables "in the Apple Design Resources for each platform". — [HIG Typography, Supporting Dynamic Type](https://developer.apple.com/design/human-interface-guidelines/typography)

### Inferences
- Growth from Large to AX5 (HIG point sizes): Large Title ×1.76, Title 1 ×2.07, Title 2 ×2.55, Title 3 ×2.75, Body/Headline ×3.12, Callout ×3.19, Subhead ×3.27, Footnote ×3.38, Caption 1 ×3.58, Caption 2 ×3.64. The hierarchy compresses: at AX5 Large Title (60) is barely bigger than Body (53). Using weight and color for hierarchy, not size alone, becomes important at accessibility sizes.
- xSmall–Medium never go below 11 pt. Footnote, Caption 1 and Caption 2 bottom out at 12/11/11, which is the HIG minimum.
- The SF Pro tracking table does not apply to Hanken Grotesk or JetBrains Mono. Custom fonts carry their own spacing, and the system's automatic per-size tracking is a system-font feature.

### Gaps
- One HIG value looks inconsistent. Subhead at xxxLarge is listed as 21 pt with **28** pt leading. Neighbours suggest 26 (the other styles' leading is size + 5–7 pt), and the UIFontMetrics multiplier I measured for subheadline at xxxLarge (1.300 = 26/20) implies 26. I am reporting the HIG figure as published and flagging it as a probable typo; I found no erratum.
- I did not download the Apple Design Resources (Sketch/Figma) to cross-check the tables. The HIG JSON and the measured iOS 26.5 values agree on point sizes; leading was not independently verified beyond the multiplier check below.

## What does the HIG say about default and minimum text sizes on iOS, font weights, and custom fonts?

### Takeaway
On iOS the default size is 17 pt and the minimum is 11 pt, "for both custom and system fonts". Prefer Regular, Medium, Semibold or Bold, and avoid Ultralight, Thin and Light. A custom font must be legible and must implement Dynamic Type and Bold Text itself. Ideally text should be enlargeable to at least 200%.

### Cited Findings
- "Follow the recommended default and minimum text sizes for each platform — for both custom and system fonts". iOS, iPadOS: **default 17 pt, minimum 11 pt** (macOS 13/10, tvOS 29/23, visionOS 17/12, watchOS 16/12). — [HIG Typography, Ensuring legibility](https://developer.apple.com/design/human-interface-guidelines/typography); the same table is under "Use recommended defaults for custom type sizes" in [HIG Accessibility, Vision](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- "If you use a custom font with a thin weight, aim for larger than the recommended sizes to increase legibility." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- "In general, avoid light font weights… prefer Regular, Medium, Semibold, or Bold font weights, and avoid Ultralight, Thin, and Light font weights, which can be difficult to see, especially when text is small." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Make sure custom fonts are legible… be guided by the recommended minimum font sizes for various styles and weights in Specifications." — [HIG Typography, Using custom fonts](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Implement accessibility features for custom fonts. System fonts automatically support Dynamic Type (where available) and respond when people turn on accessibility features, such as Bold Text. If you use a custom font, make sure it implements the same behaviors." — [HIG Typography, Using custom fonts](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Minimize the number of typefaces you use, even in a highly customized interface." — [HIG Typography, Conveying hierarchy](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Ideally, give people the option to enlarge text by at least 200 percent (or 140 percent in watchOS apps)." — [HIG Accessibility, Vision](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Contrast minimums (WCAG AA, as used by Accessibility Inspector): text up to 17 pt needs 4.5:1; 18 pt and up needs 3:1; bold text at any size needs 3:1. Check both light and dark appearances. — [HIG Accessibility, Vision](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Leading: use loose leading for wide columns and long passages, and tight leading only in height-constrained places like list rows. "If you need to display three or more lines of text, avoid tight leading even in areas where height is limited." SwiftUI API: `leading(_:)`. — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Prioritize important content when responding to text-size changes… when people increase text size to read the content in a tabbed window, they don't expect the tab titles to increase in size." — [HIG Typography, Conveying hierarchy](https://developer.apple.com/design/human-interface-guidelines/typography)
- The SwiftUI Bold Text setting is exposed as `EnvironmentValues.legibilityWeight`. It "reflects the value of the Bold Text display setting found in the Accessibility settings." — [legibilityWeight](https://developer.apple.com/documentation/swiftui/environmentvalues/legibilityweight)
- "SwiftUI doesn't synthesize bold or italic styling for fonts. If the font supports weighted or italic variants, you can customize the typography… using the weight(_:) or italic() modifiers." — [Applying custom fonts to text](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text)
- Minimum control size on iOS/iPadOS: default 44×44 pt, minimum 28×28 pt. — [HIG Accessibility, Mobility](https://developer.apple.com/design/human-interface-guidelines/accessibility)
- Change log: the Accessibility page moved its Dynamic Type guidance to Typography on March 7, 2025; Typography "Expanded guidance for Dynamic Type" the same day. — [HIG Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility); [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- **[Measured, macOS CoreText on the repo's bundled font files]** Metrics per em: Hanken Grotesk Regular has x-height 0.493, cap height 0.697, ascent 1.000, descent 0.303, natural line height 1.303. JetBrains Mono (variable) has x-height 0.550, cap height 0.730, ascent 1.020, descent 0.300, line height 1.320, digit advance 0.600. For comparison, SF Pro has x-height 0.508, cap height 0.705, line height 1.178, and SF Mono has x-height 0.529. Files: `Sources/WorkspaceUI/Resources/Fonts/`.
- **[Measured, same]** The default instance of `JetBrainsMono-Variable.ttf` reports PostScript name `JetBrainsMonoRoman-Thin`. If you load the file's default face you get Thin, the weight the HIG says to avoid. You need a named instance (`JetBrainsMono-Regular`, which is what `Sources/WorkspaceUI/Theme/LLAFonts.swift` requests) or an explicit `.weight(_:)`.

### Inferences
- Bold Text for Hanken Grotesk: the bundle ships only Regular (400) and SemiBold (600). When `legibilityWeight == .bold`, the app has to map Regular to SemiBold itself and SemiBold to something heavier (or keep it). SwiftUI won't synthesize bold for a custom face. The HIG says custom fonts must "implement the same behaviors" as the system font.
- Hanken Grotesk's x-height (0.493 em) is about 3% smaller than SF Pro's (0.508). At the same nominal size it reads a little smaller, so 17 pt Hanken looks roughly like 16.5 pt SF. That is no reason to go below the HIG's 17 pt default for body. Its natural line height (1.303 em, 22.2 pt at 17 pt) is close to the HIG body leading of 22 pt, so you rarely need extra line spacing.
- The 11 pt minimum is a floor at the Large setting for custom fonts too. Caption-sized custom text shouldn't be set below 11 pt even if it scales up later.

### Gaps
- The HIG doesn't say how a custom font should respond to Bold Text beyond "implement the same behaviors". There is no weight-mapping table.

## Which SwiftUI APIs make custom fonts scale, and how does `relativeTo:` actually scale them?

### Takeaway
Use `Font.custom(name, size: s, relativeTo: style)`, where `s` is the size at Large. `Font.custom(name, size:)` scales relative to `.body`. `Font.custom(name, fixedSize:)` and `Font.system(size:)` never scale. Scale non-text metrics (padding, icon frames) with `@ScaledMetric(relativeTo:)`. Clamp with `.dynamicTypeSize(range)` and pair any clamp with the Large Content Viewer. Measured on iOS 26.5, a custom font does **not** follow the system font's point-size curve. It scales by the ratio of the style's HIG *leading* to its leading at Large, rounded to whole points. So a 17 pt custom font relative to `.body` reaches 22 pt at xxxLarge and 48 pt at AX5, not the system's 23 and 53.

### Cited Findings
- `static func custom(_ name: String, size: CGFloat, relativeTo textStyle: Font.TextStyle) -> Font`: "Create a custom font with the given `name` and `size` that scales relative to the given `textStyle`." — [Font.custom(_:size:relativeTo:)](https://developer.apple.com/documentation/swiftui/font/custom(_:size:relativeto:))
- `static func custom(_ name: String, size: CGFloat) -> Font`: "…that scales with the body text style." — [Font.custom(_:size:)](https://developer.apple.com/documentation/swiftui/font/custom(_:size:))
- `static func custom(_ name: String, fixedSize: CGFloat) -> Font`: "…a fixed `size` that does not scale with Dynamic Type." — [Font.custom(_:fixedSize:)](https://developer.apple.com/documentation/swiftui/font/custom(_:fixedsize:))
- Use the font's **PostScript name** (Font Book > Font Info). "If SwiftUI can't retrieve and apply your font, it renders the text view with the default system font instead." On iOS, list the font files under the `UIAppFonts` Info.plist key. The doc's example: `Font.custom("MyFont", size: 32, relativeTo: .title)`. — [Applying custom fonts to text](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text)
- `@propertyWrapper struct ScaledMetric<Value> where Value : BinaryFloatingPoint`, "A dynamic property that scales a numeric value". `init(wrappedValue:relativeTo:)` "Creates the scaled metric with an unscaled value and a text style to scale relative to." — [ScaledMetric](https://developer.apple.com/documentation/swiftui/scaledmetric); [init(wrappedValue:relativeTo:)](https://developer.apple.com/documentation/swiftui/scaledmetric/init(wrappedvalue:relativeto:))
- Apple's example: `@ScaledMetric(relativeTo: .body) var scaledPadding: CGFloat = 10` applied as `.padding(scaledPadding)` around `Font.custom("MyFont", size: 18)` text. Preview at a given size with `.environment(\.dynamicTypeSize, .accessibility2)`. — [Applying custom fonts to text](https://developer.apple.com/documentation/swiftui/applying-custom-fonts-to-text)
- WWDC24 example: `@ScaledMetric var imageWidth = 125.0` used as `.frame(width: imageWidth)` on a resizable asset image. "If the image is an SF Symbol, the SF Symbol will resize automatically!" — [WWDC24 "Get started with Dynamic Type"](https://developer.apple.com/videos/play/wwdc2024/10074/)
- Clamping: `func dynamicTypeSize<T>(_ range: T) -> some View where T : RangeExpression, T.Bound == DynamicTypeSize`, for example `.dynamicTypeSize(...DynamicTypeSize.large)`. Several ranges intersect: `.dynamicTypeSize(.small...)` plus `.dynamicTypeSize(...DynamicTypeSize.large)` gives small…large. "When limiting the Dynamic Type size, consider if adding a large content view with accessibilityShowsLargeContentViewer() would be appropriate." — [View.dynamicTypeSize(_:) (range)](https://developer.apple.com/documentation/swiftui/view/dynamictypesize(_:)-26aj0)
- Pinning: `func dynamicTypeSize(_ size: DynamicTypeSize) -> some View`, for example `.dynamicTypeSize(.xLarge)`, which is useful in previews. "If a Dynamic Type size range is applied after setting a value, the value is limited by that range." — [View.dynamicTypeSize(_:) (value)](https://developer.apple.com/documentation/swiftui/view/dynamictypesize(_:))
- `DynamicTypeSize` is ordered and comparable (`dynamicTypeSize >= .accessibility1`). `isAccessibilitySize` is "A Boolean value indicating whether the size is one that is associated with accessibility". — [DynamicTypeSize](https://developer.apple.com/documentation/swiftui/dynamictypesize); [isAccessibilitySize](https://developer.apple.com/documentation/swiftui/dynamictypesize/isaccessibilitysize)
- UIKit equivalent: `UIFontMetrics(forTextStyle:)` with `scaledFont(for:)`, `scaledFont(for:maximumPointSize:)` (a max-size cap that SwiftUI's `Font.custom` doesn't expose), and `scaledValue(for:)` for layout values. — [UIFontMetrics](https://developer.apple.com/documentation/uikit/uifontmetrics); [scaledFont(for:maximumPointSize:)](https://developer.apple.com/documentation/uikit/uifontmetrics/scaledfont(for:maximumpointsize:))
- Pass `scaledFont(for:)` "a reference to the custom font that's at a point size suitable for use with large. This is the default value for the Dynamic Type setting." In UIKit, set `adjustsFontForContentSizeCategory = true`. "Fonts created through UIFontMetrics… scale to match the user's selected text size in a manner that's **similar** to the way the text style you supply is scaled." — [Scaling fonts automatically](https://developer.apple.com/documentation/uikit/scaling-fonts-automatically)
- **[Measured, iOS 26.5 Simulator] UIFontMetrics multiplier per text style** (`scaledValue(for: 1000)/1000`; Large = 1.000):

| relativeTo | xS | S | M | L | xL | xxL | xxxL | AX1 | AX2 | AX3 | AX4 | AX5 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| largeTitle | 0.927 | 0.951 | 0.976 | 1 | 1.049 | 1.122 | 1.171 | 1.268 | 1.390 | 1.488 | 1.610 | 1.707 |
| title (title1) | 0.912 | 0.941 | 0.971 | 1 | 1.059 | 1.118 | 1.206 | 1.353 | 1.500 | 1.676 | 1.794 | 2.000 |
| title2 | 0.857 | 0.893 | 0.929 | 1 | 1.071 | 1.143 | 1.214 | 1.464 | 1.679 | 1.857 | 2.107 | 2.357 |
| title3 | 0.880 | 0.920 | 0.960 | 1 | 1.120 | 1.200 | 1.280 | 1.520 | 1.760 | 2.040 | 2.320 | 2.600 |
| headline | 0.864 | 0.909 | 0.955 | 1 | 1.091 | 1.182 | 1.318 | 1.545 | 1.818 | 2.182 | **2.318** | 2.818 |
| body | 0.864 | 0.909 | 0.955 | 1 | 1.091 | 1.182 | 1.318 | 1.545 | 1.818 | 2.182 | 2.545 | 2.818 |
| callout | 0.857 | 0.905 | 0.952 | 1 | 1.095 | 1.190 | 1.333 | 1.524 | 1.857 | 2.190 | 2.476 | 2.857 |
| subheadline | 0.800 | 0.900 | 0.950 | 1 | 1.100 | 1.200 | 1.300 | 1.550 | 1.800 | 2.150 | 2.500 | 2.900 |
| footnote | 0.889 | 0.889 | 0.889 | 1 | 1.111 | 1.222 | 1.333 | 1.611 | 1.833 | 2.222 | 2.556 | 2.889 |
| caption (caption1) | 0.813 | 0.813 | 0.813 | 1 | 1.188 | 1.313 | 1.438 | 1.688 | 2.000 | 2.438 | 2.750 | 3.188 |
| caption2 | 1.000 | 1.000 | 1.000 | 1 | 1.385 | 1.538 | 1.692 | 1.923 | 2.231 | 2.692 | 3.154 | 3.692 |

- **[Measured, iOS 26.5 Simulator]** These multipliers equal the HIG *leading* ratio, leading(size)/leading(Large), not the point-size ratio. Body AX5 62/22 = 2.818 (point-size ratio 53/17 = 3.118). Caption 2 xLarge 18/13 = 1.385 (point-size ratio 13/11 = 1.18). Footnote xSmall 16/18 = 0.889. Large Title AX5 70/41 = 1.707. Two anomalies: headline at AX4 is 2.318 where body is 2.545 (HIG headline leading at AX4 is 56, which implies 2.545), and subheadline at xxxLarge is 1.300 (26/20), not the HIG's 28/20.
- **[Measured, iOS 26.5 Simulator] SwiftUI `Font.custom(_:size:relativeTo:)` resolves to the same curve, rounded to whole points** (`Font.resolve(in:).pointSize`, Menlo as a stand-in custom face):
  - 17 pt rel. `.body`: 15, 15, 16, **17**, 19, 20, **22**, 26, 31, 37, 43, **48** (system `.body`: 14…17…23…53)
  - 15 pt rel. `.body` (also the result of `custom(_:size:)` with no `relativeTo`): 13, 14, 14, **15**, 16, 18, **20**, 23, 27, 33, 38, **42**
  - 13 pt rel. `.footnote`: 12, 12, 12, **13**, 14, 16, **17**, 21, 24, 29, 33, **38**
  - 11 pt rel. `.caption2`: 11, 11, 11, **11**, 15, 17, **19**, 21, 25, 30, 35, **41** (jumps 11→15 at xLarge, past system caption2's 13)
  - 34 pt rel. `.largeTitle`: 32, 32, 33, **34**, 36, 38, **40**, 43, 47, 51, 55, **58**
  - 17 pt rel. `.headline`: same as body except AX4 = 39 (body gives 43)
  - `custom(_:fixedSize: 15)` and `Font.system(size: 15)` stay at 15 at every size.
  - UIKit `scaledFont(for: 15pt, maximumPointSize: 28)` relative to body caps at 28 from AX2 up (15, 15, 16, 17, 19, 20, 22, 26, 28, 28, 28, 28 for a 17 pt base).
- A third-party write-up describes the same mechanism: `scaledFont(for:)` applies a per-style multiplier keyed to the Large size, so one custom size in different styles can land at slightly different sizes. — [Sarunw, "Scaling custom fonts automatically with Dynamic Type"](https://sarunw.com/posts/scaling-custom-fonts-automatically-with-dynamic-type/). Use Your Loaf saw `.caption2` scale "larger than `.caption1`" despite its smaller base size, which matches the 1.385 jump above. — [Use Your Loaf, "Using A Custom Font With Dynamic Type"](https://useyourloaf.com/blog/using-a-custom-font-with-dynamic-type/)

### Inferences
- Set each custom style's base size to the HIG Large value and pick the `relativeTo` style whose role matches: body 17 → `.body`, secondary 15 → `.subheadline`, code 15 → `.callout` or `.body`, and so on. Expect custom text to run about 1 pt smaller than system text at xxxLarge and about 10% smaller at AX5 (48 vs 53 for body). That still clears the HIG's "at least 200 percent" (17 → 48 is ×2.8).
- Don't use `relativeTo: .caption2` for anything that should stay small at xLarge. It jumps 11 → 15 at the first step above default, a bigger step than any other style. `.caption` (12 → 14) or `.footnote` (13 → 14) is smoother.
- `Font.system(size:)` is a fixed size. A fallback path like `LLAFont.sans`'s `.system(size:weight:)` (in `Sources/WorkspaceUI/Theme/LLAFonts.swift`) silently drops Dynamic Type if the custom fonts fail to register. A scaling fallback would be `Font.system(style, design:)` with `.weight(_:)`, or keeping `.custom` (which already falls back to the system font while still scaling).
- SwiftUI has no `maximumPointSize`. To cap a single element, apply `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` (or similar) to that view and add `accessibilityShowsLargeContentViewer()` where appropriate.
- `@ScaledMetric` uses the same multipliers. A 44 pt tap-target height marked `@ScaledMetric(relativeTo: .body)` becomes about 124 pt at AX5 (×2.818).

### Gaps
- Apple doesn't document the custom-font scaling curve. It only says "similar to the way the text style you supply is scaled". The leading-ratio relationship and the anomalies are measured on iOS 26.5 only and could change in a later release.
- I couldn't find Apple documentation on whether `Font.custom(…relativeTo:)` applies the custom font's own line height or the style's leading. SwiftUI uses the font's own line metrics, and you adjust with `.lineSpacing(_:)`. I didn't measure line spacing in SwiftUI.

## Monospaced / code text: any Apple guidance, and what size relative to body?

### Takeaway
Apple's typography guidance has no iOS rule for code text size. It offers SF Mono, `Font.monospaced()` and `Font.Design.monospaced`, and on macOS a "Monospaced document text" system variant. Pick the size by matching x-height to body. JetBrains Mono's larger x-height means 15 pt JetBrains Mono looks about as big as 17 pt Hanken Grotesk, and that size should scale with Dynamic Type like body text.

### Cited Findings
- SF Mono is part of the San Francisco family. Use `Font.Design` constants for system fonts, and "don't embed system fonts in your app". — [HIG Typography, Using system fonts](https://developer.apple.com/design/human-interface-guidelines/typography)
- The macOS dynamic system font variants include "Monospaced document text (user fixed pitch)" → `userFixedPitchFont(ofSize:)`. This is macOS only; iOS has no equivalent row. — [HIG Typography, macOS](https://developer.apple.com/design/human-interface-guidelines/typography)
- `Font.monospaced()` "Returns a fixed-width font from the same family as the base font… a default fixed-width font otherwise". To mix code with prose in one `Text`, use an `AttributedString`; Markdown backticks apply "code voice". — [Font.monospaced()](https://developer.apple.com/documentation/swiftui/font/monospaced())
- **[Measured, macOS CoreText]** x-height in points: JetBrains Mono 0.550 em → 15 pt = 8.25 pt and 16 pt = 8.80 pt. Hanken Grotesk 0.493 em → 17 pt = 8.38 pt and 15 pt = 7.40 pt. SF Mono 0.529 em, SF Pro 0.508 em.

### Inferences
- JetBrains Mono at 15 pt has about the same x-height as Hanken Grotesk at 17 pt (8.25 vs 8.38). At 13 pt it matches Hanken at about 14.5 pt. Code 1–2 pt below the body size will look the same size optically, not smaller.
- Code blocks shouldn't go below the 11 pt minimum. Because they're dense, long lines (where horizontal scrolling or wrapping matters more than size) favour 13–15 pt at Large, scaling relative to `.callout`/`.body` (or `.footnote` for inline metadata).
- Monospaced code can't reflow by word the way prose can. At accessibility sizes, either wrap lines (and accept broken alignment) or put code in a horizontal `ScrollView`. The HIG's no-truncation rule ("Avoid truncating text in scrollable regions") argues against truncating code.

### Gaps
- I found no Apple guidance (HIG or WWDC) on code-text size relative to body on iOS, and no official JetBrains guidance on line height or size. A search turned up only unverified third-party claims, which I excluded.

## How should layout adapt at accessibility sizes?

### Takeaway
At accessibility sizes, switch horizontal arrangements to vertical stacks, keep the hierarchy, let text wrap instead of truncating, scale meaningful icons, and reduce columns. Keep the default layout at default sizes. Use `dynamicTypeSize.isAccessibilitySize` with `AnyLayout` or `ViewThatFits`. Reserve the Large Content Viewer for controls that must stay small, like tab bars.

### Cited Findings
- "Make sure your app's layout adapts to all font sizes… turn on Larger Accessibility Text Sizes in Settings > Accessibility > Display & Text Size > Larger Text, and confirm that your app remains comfortably readable." — [HIG Typography, Supporting Dynamic Type](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Increase the size of meaningful interface icons as font size increases… When you use SF Symbols, you get icons that scale automatically with Dynamic Type size changes." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Keep text truncation to a minimum as font size increases. In general, aim to display as much useful text at the largest accessibility font size as you do at the largest standard font size. Avoid truncating text in scrollable regions unless people can open a separate view to read the rest of the content." — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Consider adjusting your layout at large font sizes… inline items (like glyphs and timestamps) and container boundaries can crowd text… consider using a stacked layout where text appears above secondary items… Reduce the number of columns when the font size increases". Developer API: `isAccessibilityCategory`. — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- "Maintain a consistent information hierarchy regardless of the current font size… keep primary elements toward the top of a view". — [HIG Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- Apple's sample: `if dynamicTypeSize >= .accessibility1 { VStack { BatteryIcon(); Text("Charging") } } else { HStack { … } }`. Or use `isAccessibilitySize`. — [DynamicTypeSize](https://developer.apple.com/documentation/swiftui/dynamictypesize)
- WWDC24: "change the layout in response to larger text, but preserve the layout with default or smaller sizes". The sample switches `AnyLayout(HStackLayout())` and `AnyLayout(VStackLayout())` on `dynamicTypeSize.isAccessibilitySize`. Text "may become truncated" or "clipped, because its container has a fixed frame", so avoid fixed frames. In UIKit, use `numberOfLines = 0`. "Apps should prioritize scaling essential content over decorative views". When images don't scale, "ensure that text wraps under the unscaled image". Content in a SwiftUI `List` wraps under icons automatically. — [WWDC24 "Get started with Dynamic Type"](https://developer.apple.com/videos/play/wwdc2024/10074/)
- WWDC24 on the Large Content Viewer: a tab bar "taking less than 10% of the height of the screen" would take "almost a quarter of the screen" at large sizes. System bars already support the viewer. Custom bars use `.accessibilityShowsLargeContentViewer { Label(…) }`. — [WWDC24 "Get started with Dynamic Type"](https://developer.apple.com/videos/play/wwdc2024/10074/)
- "Rely on the large content viewer only in situations where items must remain small due to unavoidable design constraints… Don't use the large content viewer as a replacement for proper Dynamic Type support." — [accessibilityShowsLargeContentViewer()](https://developer.apple.com/documentation/swiftui/view/accessibilityshowslargecontentviewer())
- `ViewThatFits` "selects the first child whose ideal size on the constrained axes fits within the proposed size". Children are listed in order of preference, for example `ViewThatFits(in: .horizontal) { HStack{…}; VStack{…} }`. — [ViewThatFits](https://developer.apple.com/documentation/swiftui/viewthatfits)
- Testing: Xcode Preview canvas > Variants > **Dynamic Type Variants** renders every size. The Xcode debugger's environment overrides can set Dynamic Type at runtime. Accessibility audits flag clipped text and can run in UI tests. — [WWDC24 "Get started with Dynamic Type"](https://developer.apple.com/videos/play/wwdc2024/10074/)

### Inferences
- In a chat-style app (thread list rows with title, timestamp and badges; message transcripts; composer), the HIG pattern means rows stack at `isAccessibilitySize`: title on its own wrapped line, timestamp and status below. Remove `lineLimit(1)` on primary text, or raise it to 2–3 at accessibility sizes. Size icon frames with `@ScaledMetric`, or use SF Symbols, which scale on their own.
- Custom bottom bars or tab-like controls that can't grow should get `accessibilityShowsLargeContentViewer` plus a local `.dynamicTypeSize(...DynamicTypeSize.xxxLarge)` clamp, never a clamp on the whole app.
- `.fixedSize(horizontal: false, vertical: true)` (used throughout `Sources/WorkspaceUI`) is consistent with "wrap instead of truncate". Fixed `frame(height:)` values on text containers are the clipping risk WWDC24 calls out.

### Gaps
- WWDC24's transcript doesn't cover custom fonts or Accessibility Inspector by name, and I didn't review the older "Make your app accessible to everyone" session. No guidance beyond the above came from it.
- The HIG gives no breakpoint for switching layouts. `isAccessibilitySize` (AX1 and up) is Apple's sample threshold, and dense layouts may need to switch earlier, at xxxLarge.
