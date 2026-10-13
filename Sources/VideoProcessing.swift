import AVFoundation
import AVKit
import Cocoa
import CoreImage
import CoreMedia
import ScreenCaptureKit

// Timing defaults reconstructed from Hh / xi / Os in the inspected application.
// Target selection and frame renderer remain independently implemented.
struct ZoomRange: Codable {
  var start: Double
  var end: Double
  var clicks: [Click]
}
func zoomRanges(clicks: [Click], duration: Double) -> [ZoomRange] {
  var ranges = [ZoomRange]()
  for click in clicks.sorted(by: { $0.time < $1.time }) where click.time < duration - 1 {
    let start = max(0, click.time - 0.65)
    let end = min(floor(click.time * 1000) / 1000 + 2.5, duration - 0.8)
    guard end > start else { continue }
    if !ranges.isEmpty && ranges[ranges.count - 1].end + 2.5 >= start {
      ranges[ranges.count - 1].end = end
      ranges[ranges.count - 1].clicks.append(click)
    } else {
      ranges.append(ZoomRange(start: start, end: end, clicks: [click]))
    }
  }
  return ranges
}

// Independent camera choreography: zero velocity/acceleration at transition ends.
func ease(_ x: Double) -> Double {
  let u = max(0, min(1, x))
  return u * u * u * (u * (u * 6 - 15) + 10)
}
func camera(at t: Double, ranges: [ZoomRange], magnification: Double = 1.75) -> (
  Double, Double, Double
) {
  guard let r = ranges.first(where: { $0.start <= t && t <= $0.end }), let first = r.clicks.first
  else { return (0.5, 0.5, 1) }
  // Use the available lead-in, including clicks near the beginning of a recording.
  let leadIn = max(0.001, first.time - r.start)
  let fade = min(ease((t - r.start) / leadIn), ease((r.end - t) / 0.85))
  let z = 1 + (magnification - 1) * fade
  var x = first.x
  var y = first.y
  // Freeze the composition between clicks; incidental pointer travel does not shake the camera.
  for (i, c) in r.clicks.enumerated() where i > 0 {
    let prev = r.clicks[i - 1]
    // Longer travel needs more time; end at the click and never overlap the previous click.
    let distance = hypot(c.x - prev.x, c.y - prev.y)
    let duration = max(0.001, min(0.38 + distance * 0.65, 0.85, c.time - prev.time))
    let start = c.time - duration
    let u = ease((t - start) / duration)
    x += (c.x - x) * u
    y += (c.y - y) * u
  }
  let half = 0.5 / magnification
  x = max(half, min(1 - half, x))
  y = max(half, min(1 - half, y))
  return (0.5 + (x - 0.5) * fade, 0.5 + (y - 0.5) * fade, z)
}

// Camera processing changes only video; mux the original audio without retiming it.
final class ExportCancellation {
  private let lock = NSLock()
  private var cancelled = false
  func cancel() {
    lock.lock()
    cancelled = true
    lock.unlock()
  }
  var isCancelled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return cancelled
  }
  func check() throws { if isCancelled { throw CancellationError() } }
}

func render(
  raw: URL, output: URL, clicks: [Click], moves: [Click] = [], magnification: Double = 1.75,
  maxHeight: Int? = nil, cancellation: ExportCancellation? = nil,
  progress: @escaping (Double) -> Void
) throws {
  let source = AVURLAsset(url: raw)
  guard let audio = source.tracks(withMediaType: .audio).first else {
    try renderVideo(
      raw: raw, output: output, clicks: clicks, moves: moves, magnification: magnification,
      maxHeight: maxHeight, cancellation: cancellation, progress: progress)
    return
  }
  let temporary = output.deletingLastPathComponent().appendingPathComponent(
    "camera-\(UUID().uuidString).mp4")
  defer { try? FileManager.default.removeItem(at: temporary) }
  try renderVideo(
    raw: raw, output: temporary, clicks: clicks, moves: moves, magnification: magnification,
    maxHeight: maxHeight, cancellation: cancellation
  ) { progress($0 * 0.95) }
  let videoAsset = AVURLAsset(url: temporary)
  guard let video = videoAsset.tracks(withMediaType: .video).first else {
    throw Failure(message: "运镜视频轨缺失")
  }
  let composition = AVMutableComposition()
  let v = composition.addMutableTrack(
    withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
  try v.insertTimeRange(
    CMTimeRange(start: .zero, duration: videoAsset.duration), of: video, at: .zero)
  let a = composition.addMutableTrack(
    withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
  let sourceVideoStart = source.tracks(withMediaType: .video).first?.timeRange.start ?? .zero
  let audioStart = CMTimeMaximum(audio.timeRange.start, sourceVideoStart)
  let audioEnd = CMTimeMinimum(
    CMTimeRangeGetEnd(audio.timeRange), CMTimeAdd(sourceVideoStart, videoAsset.duration))
  if audioEnd > audioStart {
    try a.insertTimeRange(
      CMTimeRange(start: audioStart, end: audioEnd), of: audio,
      at: CMTimeSubtract(audioStart, sourceVideoStart))
  }
  guard
    let exporter = AVAssetExportSession(
      asset: composition, presetName: AVAssetExportPresetPassthrough)
  else { throw Failure(message: "无法创建音视频合成器") }
  exporter.outputURL = output
  exporter.outputFileType = .mp4
  let done = DispatchSemaphore(value: 0)
  exporter.exportAsynchronously { done.signal() }
  while done.wait(timeout: .now() + 0.05) == .timedOut {
    if cancellation?.isCancelled == true { exporter.cancelExport() }
  }
  try cancellation?.check()
  guard exporter.status == .completed else { throw exporter.error ?? Failure(message: "合成音频失败") }
  progress(1)
}

// Shared by the export dialog and encoder so displayed and written dimensions agree.
func outputDimensions(source: CGSize, maxHeight: Int?) -> (width: Int, height: Int) {
  let ratio = maxHeight.map { min(1, Double($0) / source.height) } ?? 1
  return (Int(source.width * ratio) / 2 * 2, Int(source.height * ratio) / 2 * 2)
}

func renderVideo(
  raw: URL, output: URL, clicks: [Click], moves: [Click] = [], magnification: Double = 1.75,
  maxHeight: Int? = nil, cancellation: ExportCancellation? = nil,
  progress: @escaping (Double) -> Void
) throws {
  let asset = AVURLAsset(url: raw)
  guard let track = asset.tracks(withMediaType: .video).first else {
    throw Failure(message: "原始视频没有视频轨")
  }
  let size = track.naturalSize
  let sw = Int(size.width)
  let sh = Int(size.height)
  let (w, h) = outputDimensions(source: size, maxHeight: maxHeight)
  let reader = try AVAssetReader(asset: asset)
  let read = AVAssetReaderTrackOutput(
    track: track,
    outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
  read.alwaysCopiesSampleData = false
  reader.add(read)
  let writer = try AVAssetWriter(outputURL: output, fileType: .mp4)
  let input = AVAssetWriterInput(
    mediaType: .video,
    outputSettings: [
      AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: w, AVVideoHeightKey: h,
      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: max(10_000_000, w * h * 5)],
    ])
  let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ])
  writer.add(input)
  guard writer.startWriting(), reader.startReading() else {
    throw writer.error ?? reader.error ?? Failure(message: "导出初始化失败")
  }
  defer {
    if writer.status == .writing { writer.cancelWriting() }
    if reader.status == .reading { reader.cancelReading() }
  }
  writer.startSession(atSourceTime: .zero)
  let context = CIContext(options: [.cacheIntermediates: false])
  var first: CMTime?
  var frames = 0
  let duration = max(asset.duration.seconds, 0.01)
  let ranges = zoomRanges(clicks: clicks, duration: duration)
  while let sample = read.copyNextSampleBuffer() {
    try cancellation?.check()
    try autoreleasepool {
      guard let buffer = CMSampleBufferGetImageBuffer(sample) else { return }
      let pts = CMSampleBufferGetPresentationTimeStamp(sample)
      if first == nil { first = pts }
      let time = CMTimeSubtract(pts, first!)
      let t = time.seconds
      let (x, y, z) = camera(at: t, ranges: ranges, magnification: magnification)
      let cw = Double(sw) / z
      let ch = Double(sh) / z
      let cx = max(cw / 2, min(Double(sw) - cw / 2, x * Double(sw)))
      let cy = max(ch / 2, min(Double(sh) - ch / 2, (1 - y) * Double(sh)))
      let crop = CGRect(x: cx - cw / 2, y: cy - ch / 2, width: cw, height: ch)
      let image = CIImage(cvPixelBuffer: buffer).cropped(to: crop).transformed(
        by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
      ).transformed(
        by: CGAffineTransform(scaleX: z * Double(w) / Double(sw), y: z * Double(h) / Double(sh)))
      var destination: CVPixelBuffer?
      guard let pool = adaptor.pixelBufferPool,
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &destination) == kCVReturnSuccess,
        let destination = destination
      else { throw Failure(message: "分配输出帧失败") }
      context.render(
        image, to: destination, bounds: CGRect(x: 0, y: 0, width: w, height: h),
        colorSpace: CGColorSpaceCreateDeviceRGB())
      while !input.isReadyForMoreMediaData {
        try cancellation?.check()
        if writer.status == .failed { throw writer.error! }
        Thread.sleep(forTimeInterval: 0.003)
      }
      guard adaptor.append(destination, withPresentationTime: time) else {
        throw writer.error ?? Failure(message: "输出帧写入失败")
      }
      frames += 1
      if frames % 15 == 0 { progress(min(0.99, t / duration)) }
    }
  }
  if reader.status == .failed { throw reader.error ?? Failure(message: "读取视频失败") }
  try cancellation?.check()
  input.markAsFinished()
  let done = DispatchSemaphore(value: 0)
  writer.finishWriting { done.signal() }
  done.wait()
  guard writer.status == .completed else { throw writer.error ?? Failure(message: "输出视频未完成") }
  progress(1)
}
