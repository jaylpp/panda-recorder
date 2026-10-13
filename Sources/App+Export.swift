import AVFoundation
import AVKit
import Cocoa
import CoreImage
import CoreMedia
import ScreenCaptureKit

extension App {
  func motionComposition(asset: AVAsset) -> AVVideoComposition {
    let ranges = zoomRanges(clicks: sessionClicks, duration: asset.duration.seconds)
    let magnification = sessionMagnification
    return AVVideoComposition(
      asset: asset,
      applyingCIFiltersWithHandler: { request in
        let image = request.sourceImage
        let bounds = image.extent
        let (x, y, z) = camera(
          at: request.compositionTime.seconds, ranges: ranges, magnification: magnification)
        let cw = bounds.width / z
        let ch = bounds.height / z
        let cx = max(cw / 2, min(bounds.width - cw / 2, x * bounds.width))
        let cy = max(ch / 2, min(bounds.height - ch / 2, (1 - y) * bounds.height))
        let crop = CGRect(
          x: bounds.minX + cx - cw / 2, y: bounds.minY + cy - ch / 2, width: cw, height: ch)
        let frame = image.cropped(to: crop).transformed(
          by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
        ).transformed(by: CGAffineTransform(scaleX: z, y: z))
        request.finish(with: frame, context: nil)
      })
  }
  func exportColumn(_ views: [NSView]) -> NSStackView {
    let stack = NSStackView(views: views)
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 18
    for view in views { view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    return stack
  }
  func installExportStack(_ stack: NSStackView, in sheet: NSWindow) {
    guard let content = sheet.contentView else { return }
    stack.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
      stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
      stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
      stack.topAnchor.constraint(greaterThanOrEqualTo: content.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
    ])
  }
  func updateExportButton() {
    exportButton.title = previewMotion ? "导出运镜视频…" : "导出原片…"
    exportButton.isEnabled =
      !busy && rawURL.map { FileManager.default.fileExists(atPath: $0.path) } == true
  }
  var exportHeights: [Int?] { [720, 1080, 1440, 2160, nil] }
  @objc func updateExportSize() {
    guard let raw = rawURL, let track = AVURLAsset(url: raw).tracks(withMediaType: .video).first
    else { return }
    let size = track.naturalSize
    let limit = exportHeights[max(0, resolution.indexOfSelectedItem)]
    let (w, h) = outputDimensions(source: size, maxHeight: limit)
    exportSize.stringValue = "输出尺寸：\(w) × \(h) · 保持比例，最高为原片尺寸"
  }
  @objc func exportVideo() {
    guard !busy, rawURL != nil, exportSheet == nil else { return }
    previewPlayer.pause()
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 500, height: 280), styleMask: [.titled],
      backing: .buffered, defer: false)
    sheet.title = previewMotion ? "导出运镜视频" : "导出原片"
    exportSheet = sheet
    updateExportSize()
    let saveButton = button("选择保存位置…", #selector(chooseExportDestination))
    saveButton.bezelColor = .systemBlue
    let row = NSStackView(views: [
      button("取消", #selector(closeExportSettings)), NSView(), saveButton,
    ])
    row.orientation = .horizontal
    let heading = NSTextField(labelWithString: previewMotion ? "导出运镜视频" : "导出原片")
    heading.font = .systemFont(ofSize: 20, weight: .semibold)
    let format = NSTextField(labelWithString: "MP4 · 30 FPS")
    format.textColor = .secondaryLabelColor
    let resolutionLabel = NSTextField(labelWithString: "分辨率")
    resolutionLabel.font = .systemFont(ofSize: 14)
    let settings = NSStackView(views: [resolutionLabel, NSView(), resolution])
    settings.orientation = .horizontal
    settings.alignment = .centerY
    settings.spacing = 12
    resolution.widthAnchor.constraint(equalToConstant: 180).isActive = true
    exportSize.font = .systemFont(ofSize: 12)
    exportSize.textColor = .secondaryLabelColor
    exportSize.maximumNumberOfLines = 2
    exportSize.lineBreakMode = .byWordWrapping
    let stack = exportColumn([heading, format, settings, exportSize, row])
    installExportStack(stack, in: sheet)
    window.beginSheet(sheet)
  }
  @objc func closeExportSettings() {
    guard let sheet = exportSheet else { return }
    window.endSheet(sheet)
    sheet.orderOut(nil)
    resolution.removeFromSuperview()
    exportSheet = nil
  }
  @objc func chooseExportDestination() {
    closeExportSettings()
    let panel = NSSavePanel()
    panel.allowedFileTypes = ["mp4"]
    panel.nameFieldStringValue = "熊猫录屏-\(Int(Date().timeIntervalSince1970)).mp4"
    panel.beginSheetModal(for: window) { response in
      if response == .OK, let url = panel.url { self.beginExport(to: url) }
    }
  }
  @objc func cancelExport() {
    exportCancellation?.cancel()
    exportStatus.stringValue = "正在取消…"
  }
  func beginExport(to output: URL) {
    guard !busy, let raw = rawURL else { return }
    let maxHeight = exportHeights[max(0, resolution.indexOfSelectedItem)]
    let staging = output.deletingLastPathComponent().appendingPathComponent(
      ".panda-export-\(UUID().uuidString).mp4")
    let clicks = previewMotion ? sessionClicks : []
    let magnification = previewMotion ? sessionMagnification : 1
    let cancellation = ExportCancellation()
    exportCancellation = cancellation
    busy = true
    startButton.isEnabled = false
    exportButton.isEnabled = false
    previewMode.isEnabled = false
    let sheet = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 480, height: 190), styleMask: [.titled],
      backing: .buffered, defer: false)
    sheet.title = "正在导出"
    exportSheet = sheet
    exportProgress.minValue = 0
    exportProgress.maxValue = 100
    exportProgress.isIndeterminate = false
    exportProgress.doubleValue = 0
    exportStatus.stringValue = "正在导出视频 · 0%"
    let stack = exportColumn([
      exportStatus, exportProgress, button("取消导出", #selector(cancelExport)),
    ])
    installExportStack(stack, in: sheet)
    window.beginSheet(sheet)
    folderButton.isHidden = true
    status.stringValue = "正在导出…"
    DispatchQueue.global(qos: .userInitiated).async {
      defer { try? FileManager.default.removeItem(at: staging) }
      do {
        try render(
          raw: raw, output: staging, clicks: clicks, magnification: magnification,
          maxHeight: maxHeight, cancellation: cancellation
        ) { p in
          DispatchQueue.main.async {
            if self.exportCancellation === cancellation, !cancellation.isCancelled {
              self.exportProgress.doubleValue = p * 100
              self.exportStatus.stringValue = "正在导出视频 · \(Int(p*100))%"
            }
          }
        }
        try cancellation.check()
        if FileManager.default.fileExists(atPath: output.path) {
          _ = try FileManager.default.replaceItemAt(output, withItemAt: staging)
        } else {
          try FileManager.default.moveItem(at: staging, to: output)
        }
        DispatchQueue.main.async {
          self.finishExport()
          self.exportedURL = output
          self.folderButton.isHidden = false
          self.folderButton.isEnabled = true
          self.status.stringValue =
            "已导出\(magnification > 1 ? "运镜视频" : "原片") · \(output.lastPathComponent)"
          NSWorkspace.shared.activateFileViewerSelecting([output])
        }
      } catch {
        DispatchQueue.main.async {
          self.finishExport()
          if error is CancellationError {
            self.status.stringValue = "已取消导出 · 原片已保留"
          } else {
            self.show(error)
          }
        }
      }
    }
  }
  func finishExport() {
    if let sheet = exportSheet {
      window.endSheet(sheet)
      sheet.orderOut(nil)
    }
    exportSheet = nil
    exportCancellation = nil
    resetButtons()
    exportButton.isEnabled = true
    previewMode.isEnabled = true
  }

  func play(_ url: URL) {
    guard FileManager.default.fileExists(atPath: url.path) else { return }

    let wasSwitching = pendingPreview != nil
    previewGeneration += 1
    let generation = previewGeneration
    previewObservation?.invalidate()
    displayObservation?.invalidate()
    pendingPreview?.player?.pause()
    pendingPreview?.player?.replaceCurrentItem(with: nil)
    pendingPreview?.removeFromSuperview()
    pendingPreview = nil
    let comparing = previewURL?.deletingLastPathComponent() == url.deletingLastPathComponent()
    let position =
      comparing ? (wasSwitching ? previewPosition : previewPlayer.currentTime()) : .zero
    let resume = comparing ? (wasSwitching ? previewResume : previewPlayer.rate > 0) : true
    previewPosition = position
    previewResume = resume
    previewPlayer.pause()
    let item = AVPlayerItem(url: url)
    let next = AVPlayer(playerItem: nil)
    let view = AVPlayerView()
    let isMotion = previewMotion
    if isMotion { item.videoComposition = motionComposition(asset: item.asset) }
    next.isMuted = previewPlayer.isMuted
    next.volume = previewPlayer.volume
    view.player = next
    view.controlsStyle = .floating
    view.videoGravity = .resizeAspect
    view.allowsVideoFrameAnalysis = false
    view.wantsLayer = true
    view.layer?.cornerRadius = 16
    view.layer?.masksToBounds = true
    view.translatesAutoresizingMaskIntoConstraints = false
    // Keep the current view above the staging view until the new frame is ready.
    previewContainer.addSubview(view, positioned: .below, relativeTo: playerView)
    NSLayoutConstraint.activate([
      view.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
      view.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
      view.topAnchor.constraint(equalTo: previewContainer.topAnchor),
      view.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
    ])
    pendingPreview = view
    previewMode.isEnabled = true
    previewMode.isHidden = !sessionMotion
    previewObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.previewGeneration == generation else { return }
        if item.status == .failed {
          view.removeFromSuperview()
          self.pendingPreview = nil
          self.previewMode.selectedSegment = self.previewMotion ? 1 : 0
          self.status.stringValue = "预览加载失败，请重试。"
          if resume { self.previewPlayer.play() }
          return
        }
        guard item.status == .readyToPlay else { return }
        let last = CMTimeMaximum(
          .zero, CMTimeSubtract(item.duration, CMTime(value: 1, timescale: 30)))
        let target = position.isNumeric ? CMTimeMinimum(position, last) : .zero
        next.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) {
          [weak self] finished in
          DispatchQueue.main.async {
            guard let self = self, finished, self.previewGeneration == generation else { return }
            self.displayObservation = view.observe(\.isReadyForDisplay, options: [.initial, .new]) {
              [weak self] view, _ in
              DispatchQueue.main.async {
                guard let self = self, self.previewGeneration == generation,
                  self.pendingPreview === view, view.isReadyForDisplay
                else { return }
                self.displayObservation?.invalidate()
                self.previewObservation?.invalidate()
                self.playerView.removeFromSuperview()
                self.previewPlayer.replaceCurrentItem(with: nil)
                self.playerView = view
                self.previewPlayer = next
                self.previewURL = url
                self.pendingPreview = nil
                self.previewMode.selectedSegment = isMotion ? 1 : 0
                self.updateExportButton()
                if resume { next.play() }
              }
            }
          }
        }
      }
    }
    next.replaceCurrentItem(with: item)
  }
  @objc func changePreview() {
    if previewMode.selectedSegment == 0 { previewRaw() } else { previewResult() }
  }
  @objc func previewRaw() {
    previewMotion = false
    updateExportButton()
    if let url = rawURL { play(url) }
  }
  @objc func previewResult() {
    previewMotion = true
    updateExportButton()
    if let url = rawURL { play(url) }
  }
  @objc func openFolder() {
    if let url = exportedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
  }
}
