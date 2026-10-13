import AVFoundation
import AVKit
import Cocoa
import CoreImage
import CoreMedia
import ScreenCaptureKit

struct Click: Codable {
  let time: Double
  let x: Double
  let y: Double
}
struct Failure: LocalizedError {
  let message: String
  var errorDescription: String? { message }
}

final class VideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
  let queue = DispatchQueue(label: "motionrecorder.video")
  var stream: SCStream?
  var writer: AVAssetWriter!
  var input: AVAssetWriterInput!
  var audioInput: AVAssetWriterInput?
  var audioSampleCount = 0
  var microphoneInput: AVAssetWriterInput?
  var microphoneSampleCount = 0
  var outputURL: URL?
  var firstTime: CMTime?
  var frameCount = 0
  var failure: Error?
  var width = 1280
  var height = 720
  var bounds = CGRect.zero
  var clicks = [Click]()
  var moves = [Click]()
  var seenClicks = 0
  var outsideClicks = 0
  var firstHostReceipt: Double?
  let lock = NSLock()
  func start(
    window: SCWindow?, display: SCDisplay?, region: CGRect? = nil,
    captureAudio: Bool = false, captureMicrophone: Bool = false, url: URL
  ) async throws {
    guard window != nil || display != nil else { throw Failure(message: "请选择录制来源") }
    bounds = region ?? window?.frame ?? display!.frame
    let filter: SCContentFilter
    if let window = window {
      filter = SCContentFilter(desktopIndependentWindow: window)
    } else {
      let content = try await SCShareableContent.excludingDesktopWindows(
        false, onScreenWindowsOnly: true)
      // Exclude the recorder process rather than looking up transient overlay window IDs.
      // High-level panels can be absent from shareableContent.windows when capture starts.
      let recorderApplications = content.applications.filter { $0.processID == getpid() }
      guard !recorderApplications.isEmpty else {
        throw Failure(message: "无法排除录屏控制窗口，请重新打开应用后重试。")
      }
      filter = SCContentFilter(
        display: display!, excludingApplications: recorderApplications, exceptingWindows: [])
    }
    let scale = Double(filter.pointPixelScale)
    width = max(2, Int(bounds.width * scale) / 2 * 2)
    height = max(2, Int(bounds.height * scale) / 2 * 2)
    outputURL = url
    writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
    input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: max(10_000_000, width * height * 5)
        ],
      ])
    input.expectsMediaDataInRealTime = true
    guard writer.canAdd(input) else { throw Failure(message: "无法创建视频编码器") }
    writer.add(input)
    if captureAudio {
      let audio = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2,
          AVEncoderBitRateKey: 192000,
        ])
      audio.expectsMediaDataInRealTime = true
      guard writer.canAdd(audio) else { throw Failure(message: "无法创建音频编码器") }
      writer.add(audio)
      audioInput = audio
    }
    if captureMicrophone {
      guard #available(macOS 15.0, *) else { throw Failure(message: "麦克风录制需要 macOS 15 或更新版本") }
      let mic = AVAssetWriterInput(
        mediaType: .audio,
        outputSettings: [
          AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1,
          AVEncoderBitRateKey: 96000,
        ])
      mic.expectsMediaDataInRealTime = true
      guard writer.canAdd(mic) else { throw Failure(message: "无法创建麦克风编码器") }
      writer.add(mic)
      microphoneInput = mic
    }
    guard writer.startWriting() else { throw writer.error ?? Failure(message: "编码器启动失败") }
    let config = SCStreamConfiguration()
    config.width = width
    config.height = height
    if let region = region, let display = display {
      config.sourceRect = region.offsetBy(dx: -display.frame.minX, dy: -display.frame.minY)
    }
    config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.showsCursor = true
    config.capturesAudio = captureAudio
    if #available(macOS 15.0, *) { config.captureMicrophone = captureMicrophone }
    config.sampleRate = 48000
    config.channelCount = 2
    config.excludesCurrentProcessAudio = true
    config.queueDepth = 5
    config.ignoreShadowsSingleWindow = true
    stream = SCStream(filter: filter, configuration: config, delegate: self)
    try stream!.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
    if captureAudio { try stream!.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
    if #available(macOS 15.0, *), captureMicrophone {
      try stream!.addStreamOutput(self, type: .microphone, sampleHandlerQueue: queue)
    }
    try await stream!.startCapture()
  }
  func stream(_ stream: SCStream, didStopWithError error: Error) {
    lock.lock()
    failure = error
    lock.unlock()
  }
  func stream(
    _ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType
  ) {
    if #available(macOS 15.0, *), type == .microphone {
      guard sample.isValid, let mic = microphoneInput, let first = firstTime,
        CMSampleBufferGetPresentationTimeStamp(sample) >= first
      else { return }
      if mic.isReadyForMoreMediaData {
        if mic.append(sample) {
          microphoneSampleCount += 1
        } else {
          lock.lock()
          failure = writer.error
          lock.unlock()
        }
      }
      return
    }
    if type == .audio {
      guard sample.isValid, let audio = audioInput, let first = firstTime,
        CMSampleBufferGetPresentationTimeStamp(sample) >= first
      else { return }
      if audio.isReadyForMoreMediaData {
        if audio.append(sample) {
          audioSampleCount += 1
        } else {
          lock.lock()
          failure = writer.error
          lock.unlock()
        }
      }
      return
    }
    guard type == .screen, sample.isValid, CMSampleBufferGetImageBuffer(sample) != nil else {
      return
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
      as? [[SCStreamFrameInfo: Any]], let value = attachments.first?[.status] as? Int,
      value != SCFrameStatus.complete.rawValue
    {
      return
    }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    lock.lock()
    if firstTime == nil {
      firstTime = pts
      firstHostReceipt = CMClockGetTime(CMClockGetHostTimeClock()).seconds
      writer.startSession(atSourceTime: pts)
    }
    lock.unlock()
    if input.isReadyForMoreMediaData {
      if input.append(sample) {
        frameCount += 1
      } else {
        lock.lock()
        failure = writer.error
        lock.unlock()
      }
    }
  }
  func elapsedRecordingTime() -> Double? {
    lock.lock()
    defer { lock.unlock() }
    guard let first = firstTime else { return nil }
    return max(0, CMClockGetTime(CMClockGetHostTimeClock()).seconds - first.seconds)
  }
  func click(_ point: CGPoint) {
    lock.lock()
    defer { lock.unlock() }
    seenClicks += 1
    guard bounds.contains(point) else {
      outsideClicks += 1
      return
    }
    guard let first = firstTime else { return }
    let t = CMClockGetTime(CMClockGetHostTimeClock()).seconds - first.seconds
    guard t >= 0 else { return }
    clicks.append(
      Click(
        time: t, x: (point.x - bounds.minX) / bounds.width,
        y: (point.y - bounds.minY) / bounds.height))
  }
  func move(_ point: CGPoint) {
    lock.lock()
    defer { lock.unlock() }
    guard let first = firstTime, bounds.contains(point) else { return }
    let t = CMClockGetTime(CMClockGetHostTimeClock()).seconds - first.seconds
    guard t >= 0, t - (moves.last?.time ?? -1) >= 1.0 / 60 else { return }
    moves.append(
      Click(
        time: t, x: (point.x - bounds.minX) / bounds.width,
        y: (point.y - bounds.minY) / bounds.height))
  }
  func stop() async throws -> [Click] {
    try await stream?.stopCapture()
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
      queue.async { c.resume() }
    }
    guard firstTime != nil, frameCount > 0 else {
      writer.cancelWriting()
      throw Failure(message: "没有捕获到画面，请检查录屏权限与目标窗口")
    }
    input.markAsFinished()
    audioInput?.markAsFinished()
    microphoneInput?.markAsFinished()
    await writer.finishWriting()
    if writer.status != .completed { throw writer.error ?? Failure(message: "原始录屏写入失败") }
    if let error = failure { throw error }
    if microphoneInput != nil, audioInput != nil, let url = outputURL {
      try await mixAudioTracks(at: url)
    }
    return lock.withLock { clicks }
  }
}

// Normalize simultaneous system and microphone tracks into one widely playable audio track.
func mixAudioTracks(at url: URL) async throws {
  let asset = AVURLAsset(url: url)
  let tracks = asset.tracks(withMediaType: .audio)
  guard tracks.count > 1 else { return }
  let mix = AVMutableAudioMix()
  mix.inputParameters = tracks.map { track in
    let parameter = AVMutableAudioMixInputParameters(track: track)
    parameter.setVolume(0.5, at: .zero)  // Leave headroom when both sources are loud.
    return parameter
  }
  let temporary = url.deletingLastPathComponent().appendingPathComponent(
    "mixed-\(UUID().uuidString).mp4")
  defer { try? FileManager.default.removeItem(at: temporary) }
  guard
    let exporter = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality)
  else { throw Failure(message: "无法创建声音混合器") }
  exporter.audioMix = mix
  exporter.outputURL = temporary
  exporter.outputFileType = .mp4
  await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
    exporter.exportAsynchronously { c.resume() }
  }
  guard exporter.status == .completed else {
    throw exporter.error ?? Failure(message: "混合麦克风与系统声音失败")
  }
  _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
}
