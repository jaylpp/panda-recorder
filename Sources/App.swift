import AVFoundation
import AVKit
import Cocoa
import CoreImage
import CoreMedia
import ScreenCaptureKit

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
  var auxiliaryControls = [NSButton]()
  var window: NSWindow!
  var sourceRow = NSStackView()
  let screenHint = NSTextField(labelWithString: "")
  var popup = NSPopUpButton()
  var mode = NSSegmentedControl()
  var displays = [SCDisplay]()
  var status = NSTextField(labelWithString: "选择一个窗口，录下真实操作。")
  var detail = NSTextField(labelWithString: "仅录视频与窗口内点击 · 不录音 · 全程本地处理")
  var startButton = NSButton(), stopButton = NSButton(), refreshButton = NSButton(),
    folderButton = NSButton()
  var bar = NSProgressIndicator()
  var playerView = AVPlayerView()
  var previewPlayer = AVPlayer()
  var previewContainer = NSView()
  var pendingPreview: AVPlayerView?
  var displayObservation: NSKeyValueObservation?
  var previewURL: URL?
  var previewResume = false
  var previewPosition = CMTime.zero
  var previewObservation: NSKeyValueObservation?
  var previewGeneration = 0

  var motionToggle = NSSwitch()
  var magnificationControl = NSSegmentedControl()
  var magnificationRow = NSStackView()
  var windowNote = NSTextField(labelWithString: "窗口录制时，请保持位置和大小不变。")
  var sessionMotion = true
  var sessionMagnification = 1.75
  var previewMode = NSSegmentedControl()
  var resolution = NSPopUpButton()
  var exportButton = NSButton()
  var exportCancellation: ExportCancellation?
  var exportSheet: NSWindow?
  var exportProgress = NSProgressIndicator()
  var exportStatus = NSTextField(labelWithString: "")
  var exportSize = NSTextField(labelWithString: "")
  var sessionClicks = [Click]()
  var previewMotion = false
  var exportedURL: URL?
  var microphoneToggle = NSSwitch()
  var audioToggle = NSSwitch()
  var available = [SCWindow]()
  var capture: VideoCapture?
  var monitor: Any?, localMonitor: Any?
  var session: URL?
  var rawURL: URL?, resultURL: URL?
  var busy = false
  var exitAlert: NSAlert?
  func dismissExitAlert() {
    guard let alert = exitAlert else { return }
    exitAlert = nil
    if alert.window.sheetParent != nil { window.endSheet(alert.window) }
    alert.window.orderOut(nil)
  }
  func updateExitAlert() {
    guard let alert = exitAlert else { return }
    alert.messageText = stopButton.isEnabled ? "正在录制" : "正在保存视频"
    alert.informativeText = stopButton.isEnabled ? "请先停止或取消录制，再退出应用。" : "视频保存完成后，此提示会自动关闭。"
  }
  var selectedDisplayID: CGDirectDisplayID?
  var selectionWindows = [RegionWindow]()
  var sourceGeneration = 0
  var choosing = false
  var screenPermissionRequested = false
  var requestingScreenPermission = false
  var permissionAlert: NSAlert?
  var awaitingScreenPermission = false
  var screenObserver: NSObjectProtocol?
  var screenConfiguration = [String]()
  var region: CGRect?
  var regionWindow: RegionWindow?
  var regionButton = NSButton()
  var recordingPanel: NSPanel?
  var floatingStop: NSButton?
  var recordingItem: NSStatusItem?
  var recordingTimer: Timer?
  @objc func restartRecording() { discardRecording(restart: true) }
  @objc func cancelRecording() {
    if busy {
      discardRecording(restart: false)
    } else {
      closeSelection()
      hideRecordingControls()
      clearRegion()
      selectedDisplayID = nil
      updateScreenHint()
      window.makeKeyAndOrderFront(nil)
    }
  }
  func discardRecording(restart: Bool) {
    guard stopButton.isEnabled, let recorder = capture, let dir = session else { return }
    stopButton.isEnabled = false
    hideRecordingControls()
    if let m = monitor {
      NSEvent.removeMonitor(m)
      monitor = nil
    }
    if let m = localMonitor {
      NSEvent.removeMonitor(m)
      localMonitor = nil
    }
    Task {
      _ = try? await recorder.stop()
      await MainActor.run {
        do { try FileManager.default.trashItem(at: dir, resultingItemURL: nil) } catch {
          self.resetButtons()
          self.show(error)
          return
        }
        self.dismissExitAlert()
        self.capture = nil
        self.busy = false
        self.rawURL = nil
        self.resultURL = nil
        self.session = nil
        if restart {
          self.start()
        } else {
          self.resetButtons()
          self.status.stringValue = "已取消录制，本次素材已移到废纸篓。"
        }
      }
    }
  }
  var emptyPreview = NSTextField(labelWithString: "录好之后，在这里看成片\n点击附近自动放大 · 平滑移镜 · 本地导出")
  @objc func start() {
    guard !busy else { return }
    guard ensureScreenPermission() else { return }
    if microphoneToggle.state == .on {
      guard #available(macOS 15.0, *) else {
        show(Failure(message: "麦克风录制需要 macOS 15 或更新版本"))
        return
      }
      switch AVCaptureDevice.authorizationStatus(for: .audio) {
      case .notDetermined:
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          DispatchQueue.main.async {
            if granted {
              self.start()
            } else {
              self.show(Failure(message: "麦克风未授权，请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"))
            }
          }
        }
        return
      case .authorized: break
      default:
        show(Failure(message: "麦克风未授权，请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"))
        return
      }
    }

    if mode.selectedSegment != 1 {
      guard let id = selectedDisplayID else {
        selectRegion()
        return
      }
      guard
        NSScreen.screens.contains(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == id
        }), let index = displays.firstIndex(where: { $0.displayID == id })
      else {
        selectedDisplayID = nil
        clearRegion()
        selectRegion()
        return
      }
      popup.selectItem(at: index)
    }
    let index = popup.indexOfSelectedItem
    guard !busy, index >= 0 else { return }
    let whole = mode.selectedSegment != 1
    if mode.selectedSegment == 2 && region == nil {
      selectRegion()
      return
    }
    guard whole ? index < displays.count : index < available.count else { return }
    let selected: SCWindow? = whole ? nil : available[index]
    let display: SCDisplay? = whole ? displays[index] : nil
    let selectedRegion = mode.selectedSegment == 2 ? region : nil
    let sourceName =
      selectedRegion != nil ? "自选区域" : whole ? "屏幕 \(index+1)" : (selected?.title ?? "窗口")
    if selectedRegion != nil { showRegionIndicator() }
    window.orderOut(nil)
    playerView.player?.pause()
    showRecordingControls()
    regionButton.isEnabled = false
    let captureAudio = audioToggle.state == .on
    audioToggle.isEnabled = false
    let captureMicrophone = microphoneToggle.state == .on
    microphoneToggle.isEnabled = false
    mode.isEnabled = false
    sessionMotion = motionToggle.state == .on
    sessionMagnification = [1.5, 1.75, 2.0][max(0, magnificationControl.selectedSegment)]
    motionToggle.isEnabled = false
    magnificationControl.isEnabled = false
    exportButton.isEnabled = false
    resolution.isEnabled = false
    previewMode.isEnabled = false
    busy = true
    startButton.isEnabled = false
    refreshButton.isEnabled = false
    popup.isEnabled = false
    folderButton.isEnabled = false
    folderButton.isHidden = true
    bar.doubleValue = 0
    do {
      let base = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
        "Movies/REA-MotionRecorder", isDirectory: true)
      let dir = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      session = dir
      rawURL = dir.appendingPathComponent("original.mp4")
      resultURL = dir.appendingPathComponent("motion.mp4")
      let recorder = VideoCapture()
      capture = recorder
      status.stringValue = "正在开始录制…"
      Task {
        do {
          try await recorder.start(
            window: selected, display: display, region: selectedRegion,
            captureAudio: captureAudio,
            captureMicrophone: captureMicrophone, url: self.rawURL!)
          await MainActor.run {
            self.monitor = NSEvent.addGlobalMonitorForEvents(matching: [
              .leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            ]) { e in
              if let p = e.cgEvent?.location {
                if e.type == .leftMouseDown || e.type == .rightMouseDown {
                  recorder.click(p)
                } else {
                  recorder.move(p)
                }
              }
            }
            self.localMonitor = NSEvent.addLocalMonitorForEvents(matching: [
              .leftMouseDown, .rightMouseDown, .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            ]) { e in
              if let p = e.cgEvent?.location {
                if e.type == .leftMouseDown || e.type == .rightMouseDown {
                  recorder.click(p)
                } else {
                  recorder.move(p)
                }
              }
              return e
            }
            self.beginRecordingTimer()
            for control in self.auxiliaryControls { control.isEnabled = true }
            self.floatingStop?.isEnabled = true
            self.stopButton.isEnabled = true
            self.status.stringValue = "● 正在录制 \(sourceName)，完成后点停止。"
            self.detail.stringValue = "录制中 · 点击悬浮停止按钮或菜单栏停止，预览后选择分辨率导出。"
          }
        } catch {
          await MainActor.run {
            self.resetButtons()
            self.show(error)
          }
        }
      }
    } catch {
      resetButtons()
      show(error)
    }
  }
  func revealMainWindow() {
    if window.isMiniaturized { window.deminiaturize(nil) }
    NSApp.activate(ignoringOtherApps: true)
    window.makeKeyAndOrderFront(nil)
  }
  @objc func stop() {
    guard stopButton.isEnabled, let recorder = capture, let dir = session, let raw = rawURL else {
      return
    }
    hideRegionIndicator()
    hideRecordingControls()
    stopButton.isEnabled = false
    if let monitor = monitor {
      NSEvent.removeMonitor(monitor)
      self.monitor = nil
    }
    if let localMonitor = localMonitor {
      NSEvent.removeMonitor(localMonitor)
      self.localMonitor = nil
    }
    updateExitAlert()
    status.stringValue = "正在结束录制…"
    Task {
      do {
        let clicks = try await recorder.stop()
        await MainActor.run { self.revealMainWindow() }
        let data = try JSONEncoder().encode(clicks)
        try data.write(to: dir.appendingPathComponent("clicks.json"))
        let moves = recorder.moves
        try JSONEncoder().encode(moves).write(to: dir.appendingPathComponent("moves.json"))
        let meta: [String: Any] = [
          "autoMotion": self.sessionMotion, "magnification": self.sessionMagnification,
          "microphoneSampleCount": recorder.microphoneSampleCount,
          "microphoneEnabled": recorder.microphoneInput != nil,
          "audioSampleCount": recorder.audioSampleCount,
          "systemAudioEnabled": recorder.audioInput != nil, "seenClicks": recorder.seenClicks,
          "outsideClicks": recorder.outsideClicks, "firstPTS": recorder.firstTime?.seconds ?? -1,
          "firstHostReceipt": recorder.firstHostReceipt ?? -1, "frameCount": recorder.frameCount,
          "bounds": [
            recorder.bounds.minX, recorder.bounds.minY, recorder.bounds.width,
            recorder.bounds.height,
          ], "mouseEventSource": "NSEvent.cgEvent.location",
        ]
        try JSONSerialization.data(withJSONObject: meta, options: .prettyPrinted).write(
          to: dir.appendingPathComponent("capture-metadata.json"))
        await MainActor.run {
          self.sessionClicks = clicks
          self.exportedURL = nil
          self.folderButton.isHidden = true
          self.resultURL = nil
          self.resetButtons()
          self.folderButton.isEnabled = true
          self.exportButton.isEnabled = true
          self.status.stringValue = "录制完成 · 选择分辨率后导出"
          self.previewMotion = self.sessionMotion
          self.play(raw)
        }
      } catch {
        await MainActor.run {
          self.resetButtons()
          self.show(error)
        }
      }
    }
  }
  func resetButtons() {
    resolution.isEnabled = true
    motionToggle.isEnabled = true
    magnificationControl.isEnabled = true
    bar.isHidden = true
    microphoneToggle.isEnabled = true
    audioToggle.isEnabled = true
    dismissExitAlert()
    hideRegionIndicator()
    hideRecordingControls()
    revealMainWindow()
    regionButton.isEnabled = true
    busy = false
    mode.isEnabled = true
    detail.stringValue = "停止后预览 · 选择分辨率后导出"
    startButton.isEnabled = true
    refreshButton.isEnabled = true
    popup.isEnabled = true
    stopButton.isEnabled = false
    capture = nil
  }
  func showPermissionStatus() {
    awaitingScreenPermission = true
    startButton.title = "授权录屏"
    startButton.image = actionIcon("lock")
    status.stringValue = "首次使用，请先允许熊猫录屏访问屏幕。"
  }
  func ensureScreenPermission() -> Bool {
    if CGPreflightScreenCaptureAccess() {
      startButton.title = "开始录制"
      startButton.image = actionIcon("circle.fill")
      return true
    }
    showPermissionStatus()
    guard permissionAlert == nil, !requestingScreenPermission else { return false }
    let alert = NSAlert()
    permissionAlert = alert
    alert.messageText = "允许录制屏幕"
    alert.informativeText =
      screenPermissionRequested
      ? "在系统设置的「录屏与系统录音」中开启熊猫录屏，再按系统提示重新打开应用。"
      : "接下来会显示 macOS 的录屏授权提示。请通过系统提示打开设置，并开启熊猫录屏。"
    alert.addButton(withTitle: screenPermissionRequested ? "打开系统设置" : "前往授权")
    alert.addButton(withTitle: "暂不")
    alert.beginSheetModal(for: window) { [weak self] response in
      guard let self = self else { return }
      self.permissionAlert = nil
      guard response == .alertFirstButtonReturn else { return }
      if self.screenPermissionRequested {
        NSWorkspace.shared.open(
          URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        )
      } else {
        // Let our sheet close before macOS presents its own permission prompt.
        DispatchQueue.main.async { self.requestScreenAuthorization() }
      }
    }
    return false
  }
  func requestScreenAuthorization() {
    guard !requestingScreenPermission else { return }
    requestingScreenPermission = true
    screenPermissionRequested = true
    NSApp.activate(ignoringOtherApps: true)
    status.stringValue = "请在 macOS 授权提示中允许录屏。"
    if CGRequestScreenCaptureAccess() {
      requestingScreenPermission = false
      awaitingScreenPermission = false
      refresh()
      return
    }
    // Use the capture framework to register the actual application requesting access.
    // Do not immediately activate Settings and cover the system permission prompt.
    Task {
      do {
        _ = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
      } catch {
        let e = error as NSError
        if e.domain != SCStreamErrorDomain || e.code != -3801 {
          await MainActor.run {
            self.requestingScreenPermission = false
            self.show(error)
          }
          return
        }
      }
      await MainActor.run {
        self.requestingScreenPermission = false
        if CGPreflightScreenCaptureAccess() {
          self.awaitingScreenPermission = false
          self.refresh()
        } else {
          self.status.stringValue = "在系统设置中开启熊猫录屏；如已开启，请按系统提示重新打开。"
        }
      }
    }
  }
  func applicationDidBecomeActive(_ notification: Notification) {
    guard awaitingScreenPermission, window != nil, !busy, CGPreflightScreenCaptureAccess() else {
      return
    }
    awaitingScreenPermission = false
    startButton.title = "开始录制"
    startButton.image = actionIcon("circle.fill")
    refresh()
  }
  func show(_ error: Error) {
    let nsError = error as NSError
    if nsError.domain == SCStreamErrorDomain && nsError.code == -3801 {
      showPermissionStatus()
      _ = ensureScreenPermission()
      return
    }
    status.stringValue = "失败：\(error.localizedDescription)"
    let alert = NSAlert()
    alert.messageText = "操作未完成"
    alert.informativeText = error.localizedDescription
    alert.addButton(withTitle: "知道了")
    alert.beginSheetModal(for: window)
  }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
  func windowWillClose(_ notification: Notification) {
    if let closed = notification.object as? NSWindow, closed === window, !busy {
      NSApp.terminate(nil)
    }
  }
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard busy else {
      dismissExitAlert()
      return .terminateNow
    }
    window.makeKeyAndOrderFront(nil)
    if exitAlert == nil {
      let alert = NSAlert()
      exitAlert = alert
      updateExitAlert()
      alert.addButton(withTitle: "知道了")
      alert.beginSheetModal(for: window) { [weak self, weak alert] _ in
        if self?.exitAlert === alert { self?.exitAlert = nil }
      }
    } else {
      updateExitAlert()
    }
    return .terminateCancel
  }
}
