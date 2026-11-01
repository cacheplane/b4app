import SwiftUI
import WorkspaceProtocol

/// The runtime's logo, ghosted: the OpenAI mark for Codex, the Anthropic mark for Claude Code, and a
/// "B4" monogram for B4. Decorative; the row it sits in names the runtime for assistive technology.
public struct RuntimeMark: View {
  public var kind: ConnectionKind
  public var height: CGFloat

  public init(kind: ConnectionKind, height: CGFloat = 14) {
    self.kind = kind
    self.height = height
  }

  public var body: some View {
    Group {
      switch kind {
      case .codex: vector("openai")
      case .claude: vector("anthropic")
      case .b4:
        Text("B4")
          .font(LLAFont.sans(height * 0.8, weight: .semibold))
          .foregroundStyle(LLA.Color.ghost)
          .fixedSize()
          .frame(height: height)
      }
    }
    .accessibilityHidden(true)
  }

  private func vector(_ name: String) -> some View {
    let art = BrandArt.load(named: name)
    let aspect = art.map { $0.viewBox.height > 0 ? $0.viewBox.width / $0.viewBox.height : 1 } ?? 1
    return BrandShape(name: name)
      .fill(LLA.Color.ghost, style: FillStyle(eoFill: true))
      .frame(width: height * aspect, height: height)
  }
}

/// A vendored SVG from `Resources/Brand` scaled to fit, centred.
nonisolated struct BrandShape: Shape {
  var name: String

  func path(in rect: CGRect) -> Path {
    guard let art = BrandArt.load(named: name), art.viewBox.width > 0, art.viewBox.height > 0 else {
      return Path()
    }
    let scale = min(rect.width / art.viewBox.width, rect.height / art.viewBox.height)
    let width = art.viewBox.width * scale
    let height = art.viewBox.height * scale
    let transform = CGAffineTransform(
      translationX: rect.minX + (rect.width - width) / 2 - art.viewBox.minX * scale,
      y: rect.minY + (rect.height - height) / 2 - art.viewBox.minY * scale
    ).scaledBy(x: scale, y: scale)
    return art.path.applying(transform)
  }
}
