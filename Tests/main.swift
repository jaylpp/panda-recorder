import Cocoa

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  guard condition() else { fatalError(message) }
}
let expected = [(720, 1112, 720), (1080, 1670, 1080), (1440, 2226, 1440), (2160, 3340, 2160)]
for (height, width, outputHeight) in expected {
  let size = outputDimensions(source: CGSize(width: 3456, height: 2234), maxHeight: height)
  check(size.width == width && size.height == outputHeight, "Incorrect export size for \(height)")
}
let native = outputDimensions(source: CGSize(width: 3456, height: 2234), maxHeight: nil)
check(native.width == 3456 && native.height == 2234, "Native export changed size")
let small = outputDimensions(source: CGSize(width: 920, height: 436), maxHeight: 2160)
check(small.width == 920 && small.height == 436, "Small source was upscaled")
let clicks = [Click(time: 2, x: 0.4, y: 0.4), Click(time: 4, x: 0.7, y: 0.6)]
let ranges = zoomRanges(clicks: clicks, duration: 10)
let arrived = camera(at: 4, ranges: ranges)
check(
  abs(arrived.0 - 0.7) < 0.000001 && abs(arrived.1 - 0.6) < 0.000001, "Camera lags behind click")
let before = camera(at: 3.3, ranges: ranges)
check(abs(before.0 - 0.4) < 0.000001, "Camera moves too early")
let approaching = camera(at: 3.6, ranges: ranges)
check(approaching.0 > 0.4 && approaching.0 < 0.7, "Camera should approach gently before click")
let firstArrival = camera(at: 2, ranges: ranges)
check(abs(firstArrival.2 - 1.75) < 0.000001, "First zoom lags behind click")
let rapid = zoomRanges(
  clicks: [
    Click(time: 2, x: 0.4, y: 0.4),
    Click(time: 2.12, x: 0.7, y: 0.6), Click(time: 2.24, x: 0.5, y: 0.5),
  ], duration: 10)
for click in rapid[0].clicks {
  let pose = camera(at: click.time, ranges: rapid)
  check(
    abs(pose.0 - click.x) < 0.000001 && abs(pose.1 - click.y) < 0.000001,
    "Rapid clicks must arrive without changing earlier targets")
}
let idle = camera(at: 0, ranges: ranges)
check(idle.2 == 1, "Idle camera should not zoom")
let cancellation = ExportCancellation()
try cancellation.check()
cancellation.cancel()
do {
  try cancellation.check()
  fatalError("Cancellation ignored")
} catch is CancellationError {} catch { fatalError("Unexpected cancellation error") }
print("Passed: 5 export sizes, no upscaling, camera timing, cancellation")

// Exercise complete input sequences, including accidental dragging in full-screen mode.
func mouse(_ type: NSEvent.EventType, _ x: CGFloat, _ y: CGFloat) -> NSEvent {
  NSEvent.mouseEvent(
    with: type, location: CGPoint(x: x, y: y), modifierFlags: [], timestamp: 0,
    windowNumber: 0, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
}
let screenPicker = RegionView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
screenPicker.wholeScreen = true
var screenSelections = [CGRect]()
screenPicker.complete = { if let rect = $0 { screenSelections.append(rect) } }
screenPicker.mouseDown(with: mouse(.leftMouseDown, 100, 100))
screenPicker.mouseDragged(with: mouse(.leftMouseDragged, 250, 250))
screenPicker.mouseUp(with: mouse(.leftMouseUp, 250, 250))
check(
  screenSelections.isEmpty && screenPicker.selection == .zero,
  "Full screen should not accept dragging")
screenPicker.mouseDown(with: mouse(.leftMouseDown, 100, 100))
screenPicker.mouseUp(with: mouse(.leftMouseUp, 100, 100))
check(screenSelections == [screenPicker.bounds], "Full screen click should select its whole bounds")
let regionPicker = RegionView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
var pickedRegion: CGRect?
regionPicker.complete = { pickedRegion = $0 }
regionPicker.mouseDown(with: mouse(.leftMouseDown, 100, 100))
regionPicker.mouseDragged(with: mouse(.leftMouseDragged, 300, 250))
regionPicker.mouseUp(with: mouse(.leftMouseUp, 300, 250))
check(
  pickedRegion == CGRect(x: 100, y: 100, width: 200, height: 150),
  "Region drag should select on release")
print("Passed: full-screen click, ignored full-screen drag, region drag and release")
