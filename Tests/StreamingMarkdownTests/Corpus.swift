import Foundation

/// A deterministic generator, so a failing split can be replayed.
struct SplitMix64: RandomNumberGenerator {
  var state: UInt64
  init(seed: UInt64) { state = seed }
  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }
}

/// A seed from a name that is the same in every process (`hashValue` is not).
func stableSeed(_ name: String) -> UInt64 {
  var hash: UInt64 = 0xCBF2_9CE4_8422_2325
  for byte in name.utf8 { hash = (hash ^ UInt64(byte)) &* 0x0000_0100_0000_01B3 }
  return hash
}

/// Every document of `Corpus/`, by file name, in name order.
func corpus() -> [(name: String, text: String)] {
  guard let root = Bundle.module.resourceURL?.appendingPathComponent("Corpus"),
    let names = try? FileManager.default.contentsOfDirectory(atPath: root.path)
  else { return [] }
  return names.filter { $0.hasSuffix(".md") }.sorted().compactMap { name in
    (try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)).map { (name, $0) }
  }
}

struct MissingCorpusFile: Error, CustomStringConvertible {
  let name: String
  var description: String { "no corpus file \(name)" }
}

/// The text of one corpus document; throws when there is none of that name.
func corpusText(_ name: String) throws -> String {
  guard let text = corpus().first(where: { $0.name == name })?.text else {
    throw MissingCorpusFile(name: name)
  }
  return text
}

/// `text` cut into pieces of 1...`maxSize` characters.
func randomChunks(_ text: String, maxSize: Int, using rng: inout SplitMix64) -> [String] {
  var pieces: [String] = []
  var index = text.startIndex
  while index < text.endIndex {
    let size = Int.random(in: 1...maxSize, using: &rng)
    let end = text.index(index, offsetBy: size, limitedBy: text.endIndex) ?? text.endIndex
    pieces.append(String(text[index..<end]))
    index = end
  }
  return pieces
}
