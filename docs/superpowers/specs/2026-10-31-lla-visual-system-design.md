# LiveLoveApp visual system for the workspace app

Date: 2026-10-31. Owner: Brian Love. Status: approved for build at the owner's direction ("let's start to bring in the LLA visual palette, design, and UI"; "I want a modern interface"). Calls marked *(my call)* were made by the implementer and can be reversed cheaply.

## Intent

The workspace app should look and feel like the LiveLoveApp site at `~/repos/liveloveapp`: ink on white, one cobalt accent, Hanken Grotesk and JetBrains Mono, hairlines and generous space instead of boxes and shadows, pill buttons, and real content over decoration. The app is a tool Brian lives in for hours, so the system must also hold up in dark mode, at small sizes, and with dense state (running turns, pending approvals, failures).

## Source of truth

`~/repos/liveloveapp/src/app/globals.css` (tokens), `docs/design-rules.md` (the eleven rules), `src/app/brand/page.tsx` (colours, the mark, the icon, clear space), `src/components/{Header,Section,SectionHead,Wordmark}.tsx` (layout habits). Assets are vendored into `Sources/WorkspaceUI/Resources/Brand` (the outlined SVGs) and `Sources/WorkspaceUI/Resources/Fonts` (OFL fonts from the LLA repo and the owner's font folder; licences beside them).

## Goals

- One token file both apps read; no literal colours, radii, or font names in views.
- Every LLA design rule that applies to an app holds: no gradients, glows, coloured shadows, glass, uppercase labels, letter-spaced caps, eyebrows, stat tiles, icon-in-square tiles, or decorative icon sets; one accent, used for links, focus, the mark, and nothing else (one exception below).
- Dark mode derived from the same palette, since the site has none.
- The sidebar, thread view, transcript, composer, approvals, connections, local servers, diagnostics, the new-thread sheet, and the empty states are all restyled. The iOS target compiles and renders the same system.
- Model and coordinator code do not change. Accessibility identifiers used by tests stay.

## Non-goals

- No new features, no information-architecture change beyond what the restyle needs.
- No animation system. At most one moving element per view (the running dot's ring).
- No custom window chrome or title-bar tricks; native toolbars and split views stay.

## Anti-goals

- A "dashboard" look: stat rows, cards in grids with icons on top, badges everywhere.
- Accent sprawl: cobalt selection highlights, cobalt buttons, cobalt status.
- Faux-brand: typing "LLA" in a font instead of the drawn mark.

## Tokens

Colours, light then dark *(dark is my call; the site is light only)*:

| Token | Light | Dark | Use |
| --- | --- | --- | --- |
| `bg` | `#ffffff` | `#0d0d0d` | Detail and sheet backgrounds |
| `surface` | `#f7f7f8` | `#161617` | Sidebar, inputs, secondary buttons, user messages |
| `surfaceRaised` | `#ececee` | `#202022` | Selected row, secondary button hover |
| `ink` | `#0d0d0d` | `#ececec` | Text, primary buttons |
| `muted` | `#5d5d5d` | `#9c9c9c` | Secondary text |
| `rule` | `#e8e8e8` | `#262628` | Hairlines, card borders |
| `accent` | `#002fa7` | `#7f98e0` | Links, focus ring, the mark when coloured, "waiting for you" |
| `accentHover` | `#00247f` | `#a3b5ea` | Link hover |
| `danger` | `#962e1f` | `#e07a6a` | Failures, destructive buttons |
| `codeBg` | `#0d0d0d` | `#161617` | Code and command output blocks |
| `codeFg` | `#ececec` | `#ececec` | Text in code blocks |
| `selection` | `#d9e0f5` | `#1f2a4d` | Text selection |

Radii: input 8, card 16 (the site's `shot`), pill 999. Hairline 1 pt in `rule`. No shadows.

Type: Hanken Grotesk Regular (400) and SemiBold (600), JetBrains Mono (variable, used at 400 and 600). Scale (points, weight, tracking): display 26/600/-0.02em (thread title, sheet title), title 19/600/-0.01em (section heads), body 15/400 with 1.45 line height, small 13/400, caption 12/400 muted, mono 13/400. Fonts register once at first view construction from the bundle; if registration fails the system font is used and nothing else breaks.

## State colour *(my call)*

An app needs to signal state; the site does not. Thread and turn states use ink shades first and colour only where it carries meaning:

| State | Dot | Text |
| --- | --- | --- |
| idle | `rule` filled | muted label |
| running, stopping | `ink` filled, with a 40% ring that pulses (static when Reduce Motion is on) | label |
| waiting for you | `accent` filled | label; this is the one place the accent marks state, because it is the thing to click |
| unknown (reconciling) | hollow, `danger` stroke | label |
| reconnecting | `muted` filled | label |
| error | `danger` filled | label |

Connection and server health badges: `ready` is plain ink text on `surface`; `error`, `incompatible`, `offline`, `unhealthy` use `danger` text; everything else is muted. Badges are pills with 12-pt text, never uppercase.

## Components (`Sources/WorkspaceUI/Theme/`)

- `LLA.Color`, `LLA.Font`, `LLA.Radius`, `LLA.Space` statics; `LLAFonts.register()`.
- `LLAButtonStyle` with `.primary` (ink pill, `bg` text), `.secondary` (`surface` pill, ink text, `surfaceRaised` on hover), `.danger` (`danger` text on `surface`), `.link` (accent text, no pill). Min height 32 on macOS, 44 on iOS. Disabled: 45% opacity.
- `LLACard`: `rule` border, radius 16, `bg` or `surface` fill, 16-pt padding.
- `Hairline`: 1-pt `rule` line.
- `LLABadge(text, tone)`.
- `LLAStateDot(state)`.
- `LLASectionHead(title, intro)`: title in `title` type, intro in body muted; replaces `.font(.headline)` labels.
- `LLAEmptyState(title, text, actions)`: a heading, a sentence, and link or pill buttons; replaces `ContentUnavailableView` and any dark CTA.
- `LLAMark(variant: .full | .icon)`: a `Shape` built from the vendored SVG's `M L Q Z` path data, filled even-odd in `ink` (or `accent` where the brand page allows a single colour).
- `LLATextFieldStyle` and the composer field: `surface` fill, `rule` border, radius 8 (fields) or 16 (composer), focus ring 2 pt `accent`.

## Screens

- **Sidebar**: `surface` background; the mark (24 pt high) and the words "Agent Workspace" in body weight 600 at the top; the four surfaces as text rows (no symbols), selected row ink on `surfaceRaised`; a "Threads" section head with the connection picker beneath when there is more than one connection; thread rows with the state dot, title, and a muted meta line; the archived section as today with the toggle restyled; the link status as a muted caption row above the bottom edge.
- **Thread detail**: header with the title in `display`, archived as a badge, the turn status badge on the right; meta line muted with the connection label, kind, and directory or route; hairline; transcript in a 720-pt column centred; user messages right-aligned in `surface` with radius 16; assistant prose in body; reasoning and tool cards as `LLACard` rows with a mono title and a muted status; command output in `codeBg` blocks with radius 16; system notes as muted captions.
- **Composer**: a radius-16 `surface` field with a `rule` border; inside it, the editor and a bottom row with the hint caption on the left and pill buttons on the right (Stop as secondary, Send as primary, Check again as secondary, Abandon turn as danger). The error banner above it is a `LLACard` with `danger` text, the code in mono muted, and the remediation action as a secondary pill.
- **Approvals**: `LLACard` with a `rule` border (no orange tint); the title in `title` type; the command in mono; Allow once primary, Allow for session secondary, Deny danger.
- **Continuity banner**: `LLACard` on `surface`; heading, sentence, Check again secondary, New thread primary.
- **Connections, Local servers, Diagnostics**: section heads instead of bold labels; each configured item as a `LLACard`; forms as stacked `LLATextFieldStyle` fields with the trust sentence in caption muted; lists (routes, recent errors) as hairline-separated rows, not nested cards.
- **New thread sheet**: title in `display`, fields, caption, Cancel secondary, Create primary.
- **Empty states**: `LLAEmptyState`.

## Icon and name *(my call)*

The app icon is the LLA icon (ink tile with the snow-capped A knocked out) rasterised from the vendored SVG by `Scripts/make-app-icon.swift` into `Apps/Shared/Assets.xcassets/AppIcon.appiconset` for both targets. The display name stays "Agent Workspace".

## Left to the builder

Exact paddings inside the tokens, the sidebar row height, and how the toolbar buttons are grouped on macOS 26. Keep the accessibility identifiers listed in `Tests/WorkspaceUITests` and the coordinator tests.
