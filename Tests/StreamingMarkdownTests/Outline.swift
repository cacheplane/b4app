import StreamingMarkdown

/// One line per block, two spaces of indent per level, ids omitted.
func outline(_ document: MarkdownDocument) -> String {
  var lines: [String] = []
  append(document.blocks, depth: 0, to: &lines)
  return lines.joined(separator: "\n")
}

private func quoted(_ text: String) -> String {
  let escaped = text.replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n")
  return "\"\(escaped)\""
}

private func append(_ blocks: [MarkdownBlock], depth: Int, to lines: inout [String]) {
  let pad = String(repeating: "  ", count: depth)
  for block in blocks {
    switch block.kind {
    case .paragraph(let text):
      lines.append("\(pad)p \(quoted(text))")
    case .heading(let level, let text):
      lines.append("\(pad)h\(level) \(quoted(text))")
    case .thematicBreak:
      lines.append("\(pad)hr")
    case .code(let language, let text, let closed):
      lines.append("\(pad)code \(language ?? "-") \(closed ? "closed" : "open") \(quoted(text))")
    case .quote(let children):
      lines.append("\(pad)quote")
      append(children, depth: depth + 1, to: &lines)
    case .list(let list):
      lines.append("\(pad)list \(list.ordered ? "ol \(list.start)" : "ul")")
      for item in list.items {
        let task = item.task.map { $0 ? " [x]" : " [ ]" } ?? ""
        lines.append("\(pad)  item\(task)")
        append(item.blocks, depth: depth + 2, to: &lines)
      }
    case .table(let table):
      let marks = table.alignments.map { alignment -> String in
        switch alignment {
        case .leading: "l"
        case .center: "c"
        case .trailing: "r"
        case nil: "-"
        }
      }
      lines.append("\(pad)table \(marks.joined(separator: " "))")
      lines.append("\(pad)  head \(table.header.map(quoted).joined(separator: " | "))")
      for row in table.rows { lines.append("\(pad)  row \(row.map(quoted).joined(separator: " | "))") }
    }
  }
}
