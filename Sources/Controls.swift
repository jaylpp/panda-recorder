import AVFoundation
import AVKit
import Cocoa
import CoreImage
import CoreMedia
import ScreenCaptureKit

// App-owned text uses three sizes; native menus and alerts retain system typography.
enum Typography {
  static let title: CGFloat = 18
  static let body: CGFloat = 13
  static let caption: CGFloat = 12
}

final class RegionWindow: NSWindow { override var canBecomeKey: Bool { true } }
final class RegionView: NSView {
  var passive = false
  var wholeScreen = false
  var screenName = ""
  private var draggedScreen = false
  var origin: CGPoint?
  var selection = CGRect.zero
  var complete: ((CGRect?) -> Void)?
  override var acceptsFirstResponder: Bool { true }
  // Other displays have non-key overlays; their first press must start the selection.
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { !passive }
  var selectionCursor: NSCursor { wholeScreen ? .arrow : .crosshair }
  override func resetCursorRects() {
    if !passive { addCursorRect(bounds, cursor: selectionCursor) }
  }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    let shade = NSBezierPath(rect: bounds)
    if selection.width > 0 { shade.appendRect(selection) }
    shade.windingRule = .evenOdd
    NSColor.black.withAlphaComponent(0.35).setFill()
    shade.fill()
    if selection.width > 0 {

      NSColor.white.setStroke()
      let line = NSBezierPath(rect: selection.insetBy(dx: -1, dy: -1))
      line.lineWidth = 2
      line.stroke()
    }
    if passive { return }
    let text = wholeScreen ? "点击选择这块屏幕 · Esc 取消 — \(screenName)" : "拖动选择录制区域 · 松开确认 · Esc 取消"
    text.draw(
      at: CGPoint(x: 32, y: bounds.height - 60),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: Typography.body, weight: .medium),
        .foregroundColor: NSColor.white,
      ])
  }
  override func mouseDown(with event: NSEvent) {
    guard !passive else { return }
    draggedScreen = false
    origin = convert(event.locationInWindow, from: nil)
  }
  override func mouseDragged(with event: NSEvent) {
    guard !passive, let a = origin else { return }
    if wholeScreen {
      draggedScreen = true
      return
    }
    let p = convert(event.locationInWindow, from: nil)
    selection = CGRect(
      x: min(a.x, p.x), y: min(a.y, p.y), width: abs(a.x - p.x), height: abs(a.y - p.y)
    ).intersection(bounds)
    needsDisplay = true
  }
  override func mouseUp(with event: NSEvent) {
    guard !passive, origin != nil else { return }
    if wholeScreen {
      origin = nil
      if !draggedScreen { complete?(bounds) }
      return
    }
    mouseDragged(with: event)
    if selection.width >= 64 && selection.height >= 64 {
      complete?(selection)
    } else {
      origin = nil
      selection = .zero
      needsDisplay = true
    }
  }
  override func keyDown(with event: NSEvent) { if event.keyCode == 53 { complete?(nil) } }
}

// Align action icons at the leading edge and center all button titles.
final class PrimaryActionButtonCell: NSButtonCell {
  override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in view: NSView)
    -> NSRect
  {
    let text = NSAttributedString(
      string: title.string,
      attributes: [
        .font: font ?? NSFont.systemFont(ofSize: 16, weight: .medium),
        .foregroundColor: NSColor.white.withAlphaComponent(isEnabled ? 1 : 0.7),
      ])
    let size = text.size()
    let rect = NSRect(
      x: frame.midX - size.width / 2, y: frame.midY - size.height / 2, width: size.width,
      height: size.height)
    text.draw(in: rect)
    return rect
  }
}

final class LeadingActionButtonCell: NSButtonCell {
  override func drawTitle(_ title: NSAttributedString, withFrame frame: NSRect, in view: NSView)
    -> NSRect
  {
    var rect = frame
    rect.origin.x = view.bounds.minX
    rect.size.width = view.bounds.width
    return super.drawTitle(title, withFrame: rect, in: view)
  }
  override func drawImage(_ image: NSImage, withFrame frame: NSRect, in view: NSView) {
    let rect = NSRect(x: view.bounds.minX + 14, y: frame.midY - 6, width: 12, height: 12)
    super.drawImage(image, withFrame: rect, in: view)
  }
}

// Keep each icon and label together regardless of the button's hit-area width.
final class RecordingBarButton: NSButton {
  override func draw(_ dirtyRect: NSRect) {
    let color = (contentTintColor ?? .white).withAlphaComponent(isEnabled ? 1 : 0.45)
    let attrs: [NSAttributedString.Key: Any] = [
      .font: font ?? NSFont.systemFont(ofSize: 13), .foregroundColor: color,
    ]
    let text = title as NSString
    let textSize = text.size(withAttributes: attrs)
    let iconSize: CGFloat = 16
    let gap: CGFloat = 6
    let total = textSize.width + (image == nil ? 0 : iconSize + gap)
    var x = (bounds.width - total) / 2
    if isHighlighted {
      NSColor.white.withAlphaComponent(0.1).setFill()
      NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }
    if let icon = image?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(paletteColors: [color]))
    {
      icon.draw(
        in: NSRect(x: x, y: (bounds.height - iconSize) / 2, width: iconSize, height: iconSize),
        from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
      x += iconSize + gap
    }
    text.draw(
      in: NSRect(
        x: x, y: (bounds.height - textSize.height) / 2, width: textSize.width,
        height: textSize.height), withAttributes: attrs)
  }
}

final class RecordingBarBackground: NSView {
  override var isOpaque: Bool { false }
  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    bounds.fill(using: .copy)
    NSColor(calibratedWhite: 0.12, alpha: 0.88).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12).fill()
  }
}
