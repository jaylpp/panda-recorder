import AVFoundation
import AVKit
import Cocoa
import CoreImage
import CoreMedia
import ScreenCaptureKit

if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--render" {
  do {
    let raw = URL(fileURLWithPath: CommandLine.arguments[2])
    let clicks = try JSONDecoder().decode(
      [Click].self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[3])))
    let moveURL = raw.deletingLastPathComponent().appendingPathComponent("moves.json")
    let moves = (try? JSONDecoder().decode([Click].self, from: Data(contentsOf: moveURL))) ?? []
    try render(
      raw: raw, output: URL(fileURLWithPath: CommandLine.arguments[4]), clicks: clicks, moves: moves
    ) { _ in }
    print("Render complete")
  } catch {
    fputs("Render failed: \(error.localizedDescription)\n", stderr)
    exit(1)
  }
} else {
  let delegate = App()
  let application = NSApplication.shared
  application.delegate = delegate
  application.run()
}
