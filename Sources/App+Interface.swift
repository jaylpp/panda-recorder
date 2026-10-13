import AVFoundation
import AVKit
import Cocoa
import CoreImage
import CoreMedia
import ScreenCaptureKit

extension App {
  func applicationDidFinishLaunching(_ n: Notification) {
    NSApp.setActivationPolicy(.regular)
    let menu = NSMenu()
    let root = NSMenuItem()
    menu.addItem(root)
    let sub = NSMenu()
    sub.addItem(
      withTitle: "退出熊猫录屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    root.submenu = sub
    NSApp.mainMenu = menu
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1100, height: 720),
      styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false
    )
    window.title = "熊猫录屏"
    window.center()
    window.minSize = NSSize(width: 960, height: 650)
    window.titlebarAppearsTransparent = true
    window.backgroundColor = NSColor(calibratedWhite: 0.97, alpha: 1)
    window.appearance = NSAppearance(named: .aqua)
    let content = NSView()
    window.contentView = content
    func label(_ text: String, _ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSTextField {
      let v = NSTextField(wrappingLabelWithString: text)
      v.font = .systemFont(ofSize: size, weight: weight)
      return v
    }
    func column(_ views: [NSView], _ spacing: CGFloat) -> NSStackView {
      let v = NSStackView(views: views)
      v.orientation = .vertical
      v.alignment = .leading
      v.spacing = spacing
      v.translatesAutoresizingMaskIntoConstraints = false
      return v
    }
    let brand = label("熊猫录屏", Typography.title, .semibold)
    let icon = NSImageView()
    icon.image = NSImage(
      contentsOf: Bundle.main.url(forResource: "AppIcon", withExtension: "icns")!)
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.widthAnchor.constraint(equalToConstant: 40).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 40).isActive = true
    let identity = NSStackView(views: [icon, brand])
    identity.orientation = .horizontal
    identity.spacing = 10
    let section = label("录制来源", Typography.body, .semibold)
    mode = NSSegmentedControl(
      labels: ["全屏", "窗口", "区域"], trackingMode: .selectOne, target: self,
      action: #selector(changeMode))
    mode.selectedSegment = 0
    mode.segmentStyle = .rounded
    mode.controlSize = .large
    mode.font = .systemFont(ofSize: Typography.body)
    regionButton = button("选择屏幕", #selector(selectRegion))
    regionButton.image = actionIcon("display")
    regionButton.isHidden = false
    popup.target = self
    popup.action = #selector(sourceChanged)
    popup.controlSize = .large
    popup.font = .systemFont(ofSize: Typography.body)
    popup.addItem(withTitle: "请选择录制来源")
    refreshButton = button("", #selector(refresh))
    refreshButton.image = NSImage(
      systemSymbolName: "arrow.clockwise", accessibilityDescription: "刷新来源")
    refreshButton.toolTip = "刷新录制来源"
    refreshButton.setAccessibilityLabel("刷新来源")
    refreshButton.widthAnchor.constraint(equalToConstant: 34).isActive = true
    sourceRow = NSStackView(views: [popup, refreshButton])
    sourceRow.orientation = .horizontal
    sourceRow.spacing = 8
    sourceRow.distribution = .fill
    popup.widthAnchor.constraint(equalTo: sourceRow.widthAnchor, constant: -42).isActive = true
    popup.setContentHuggingPriority(.defaultLow, for: .horizontal)
    startButton = button("开始录制", #selector(start))
    startButton.keyEquivalent = "\r"
    startButton.bezelColor = .systemBlue
    startButton.image = actionIcon("circle.fill")
    stopButton = button("停止录制", #selector(stop))
    stopButton.image = actionIcon("stop.fill")
    stopButton.isEnabled = false
    let rule = NSBox()
    rule.boxType = .separator
    audioToggle.state = .on
    microphoneToggle.toolTip = "使用系统默认麦克风"
    let note = windowNote
    note.font = .systemFont(ofSize: Typography.caption)
    note.textColor = .secondaryLabelColor
    note.isHidden = true
    note.lineBreakMode = .byWordWrapping
    note.maximumNumberOfLines = 2
    let soundTitle = label("声音", Typography.body, .semibold)
    func soundRow(_ title: String, _ toggle: NSSwitch) -> NSStackView {
      toggle.controlSize = .small
      toggle.setAccessibilityLabel(title)
      let text = label(title, Typography.body)
      let gap = NSView()
      let row = NSStackView(views: [text, gap, toggle])
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = 8
      toggle.setContentHuggingPriority(.required, for: .horizontal)
      text.setContentHuggingPriority(.required, for: .horizontal)
      row.heightAnchor.constraint(equalToConstant: 26).isActive = true
      return row
    }
    let systemRow = soundRow("系统声音", audioToggle)
    let micRow = soundRow("麦克风", microphoneToggle)
    let soundGroup = column([soundTitle, systemRow, micRow], 8)
    systemRow.widthAnchor.constraint(equalTo: soundGroup.widthAnchor).isActive = true
    micRow.widthAnchor.constraint(equalTo: soundGroup.widthAnchor).isActive = true
    motionToggle.state = .on
    motionToggle.target = self
    motionToggle.action = #selector(changeMotion)
    let motionRow = soundRow("自动运镜", motionToggle)
    magnificationControl = NSSegmentedControl(
      labels: ["1.5×", "1.75×", "2×"], trackingMode: .selectOne, target: nil, action: nil)
    magnificationControl.font = .systemFont(ofSize: Typography.body)
    magnificationControl.selectedSegment = 1
    magnificationControl.segmentStyle = .rounded
    magnificationControl.setAccessibilityLabel("聚焦倍率")
    magnificationRow = column([label("聚焦倍率", Typography.body), magnificationControl], 8)
    magnificationControl.widthAnchor.constraint(equalTo: magnificationRow.widthAnchor).isActive =
      true
    let attribution = NSTextField(labelWithString: "")
    let credit = NSMutableAttributedString(
      string: "Made by ",
      attributes: [
        .font: NSFont.systemFont(ofSize: Typography.caption),
        .foregroundColor: NSColor.secondaryLabelColor,
      ])
    credit.append(
      NSAttributedString(
        string: "🐼 熊猫 Jay",
        attributes: [
          .font: NSFont.systemFont(ofSize: Typography.caption, weight: .medium),
          .foregroundColor: NSColor.labelColor,
        ]))
    attribution.attributedStringValue = credit
    attribution.setAccessibilityLabel("Made by 🐼 熊猫 Jay")
    let spacer = NSView()
    screenHint.font = .systemFont(ofSize: Typography.caption)
    screenHint.textColor = .secondaryLabelColor
    sourceRow.isHidden = true
    let sidebar = column(
      [
        identity, section, mode, sourceRow, screenHint, regionButton, soundGroup, rule, motionRow,
        magnificationRow, startButton, stopButton, spacer, note, attribution,
      ], 14)
    sidebar.setCustomSpacing(30, after: identity)
    sidebar.setCustomSpacing(22, after: sourceRow)
    sidebar.setCustomSpacing(22, after: regionButton)
    sidebar.setCustomSpacing(22, after: magnificationRow)
    let panel = NSView()
    panel.wantsLayer = true
    panel.layer?.backgroundColor = NSColor.white.cgColor
    panel.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(panel)
    panel.addSubview(sidebar)
    let title = label("视频预览", Typography.title, .semibold)

    folderButton = button("查看文件", #selector(openFolder))
    folderButton.isEnabled = false
    folderButton.isHidden = true
    folderButton.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
    previewMode = NSSegmentedControl(
      labels: ["原片", "运镜效果"], trackingMode: .selectOne, target: self,
      action: #selector(changePreview))
    previewMode.segmentStyle = .rounded
    previewMode.controlSize = .large
    previewMode.font = .systemFont(ofSize: Typography.body)
    previewMode.selectedSegment = -1
    previewMode.isEnabled = false
    previewMode.isHidden = true
    resolution.addItems(withTitles: ["720p", "1080p", "1440p", "4K", "原始尺寸"])
    resolution.selectItem(at: 1)
    resolution.target = self
    resolution.action = #selector(updateExportSize)
    resolution.setAccessibilityLabel("导出分辨率")
    exportButton = button("导出运镜视频…", #selector(exportVideo))
    exportButton.cell = PrimaryActionButtonCell(textCell: exportButton.title)
    exportButton.setButtonType(.momentaryPushIn)
    exportButton.bezelStyle = .rounded
    exportButton.controlSize = .large
    exportButton.font = .systemFont(ofSize: Typography.body, weight: .medium)
    exportButton.target = self
    exportButton.action = #selector(exportVideo)
    exportButton.bezelColor = .systemBlue
    exportButton.isEnabled = false
    let previews = NSStackView(views: [previewMode, NSView(), exportButton])
    previews.orientation = .horizontal
    previews.spacing = 8
    playerView.player = previewPlayer
    playerView.allowsVideoFrameAnalysis = false
    playerView.controlsStyle = .floating
    playerView.videoGravity = .resizeAspect
    playerView.wantsLayer = true
    playerView.layer?.cornerRadius = 16
    playerView.layer?.masksToBounds = true
    emptyPreview.stringValue = "录制完成后，在这里预览"
    emptyPreview.font = .systemFont(ofSize: Typography.body, weight: .regular)
    emptyPreview.textColor = NSColor(calibratedWhite: 0.7, alpha: 1)
    emptyPreview.alignment = .center
    emptyPreview.maximumNumberOfLines = 3
    emptyPreview.translatesAutoresizingMaskIntoConstraints = false
    playerView.addSubview(emptyPreview)
    NSLayoutConstraint.activate([
      emptyPreview.centerXAnchor.constraint(equalTo: playerView.centerXAnchor),
      emptyPreview.centerYAnchor.constraint(equalTo: playerView.centerYAnchor),
    ])
    status.font = .systemFont(ofSize: Typography.caption, weight: .regular)
    status.maximumNumberOfLines = 2
    detail.font = .systemFont(ofSize: Typography.caption)
    detail.textColor = .secondaryLabelColor
    detail.maximumNumberOfLines = 2
    bar.isIndeterminate = false
    bar.minValue = 0
    bar.maxValue = 100
    bar.style = .bar
    bar.isHidden = true
    previewContainer.addSubview(playerView)
    playerView.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      playerView.leadingAnchor.constraint(equalTo: previewContainer.leadingAnchor),
      playerView.trailingAnchor.constraint(equalTo: previewContainer.trailingAnchor),
      playerView.topAnchor.constraint(equalTo: previewContainer.topAnchor),
      playerView.bottomAnchor.constraint(equalTo: previewContainer.bottomAnchor),
    ])
    let resultRow = NSStackView(views: [status, NSView(), folderButton])
    resultRow.orientation = .horizontal
    resultRow.alignment = .centerY
    resultRow.spacing = 12
    status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let main = column([title, previewContainer, previews, bar, resultRow], 14)
    main.setCustomSpacing(24, after: title)
    content.addSubview(main)
    NSLayoutConstraint.activate([
      panel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      panel.topAnchor.constraint(equalTo: content.topAnchor),
      panel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
      panel.widthAnchor.constraint(equalToConstant: 280),
      sidebar.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 22),
      sidebar.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -22),
      sidebar.topAnchor.constraint(equalTo: panel.topAnchor, constant: 28),
      sidebar.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -24),
      main.leadingAnchor.constraint(equalTo: panel.trailingAnchor, constant: 28),
      main.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -28),
      main.topAnchor.constraint(equalTo: content.topAnchor, constant: 28),
      main.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
      previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 300),
    ])
    for v in [
      mode, sourceRow, regionButton, soundGroup, rule, startButton, stopButton, note, motionRow,
      magnificationRow,
    ] as [NSView] { v.widthAnchor.constraint(equalTo: sidebar.widthAnchor).isActive = true }
    for v in [previewContainer, previews, bar, resultRow] as [NSView] {
      v.widthAnchor.constraint(equalTo: main.widthAnchor).isActive = true
    }
    popup.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for b in [startButton, stopButton, regionButton, folderButton] {
      b.imagePosition = .imageLeading
    }
    window.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
    window.delegate = self
    updateScreenHint()
    refresh()
    screenConfiguration = currentScreenConfiguration()
    screenObserver = NotificationCenter.default.addObserver(
      forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
    ) { [weak self] _ in self?.screensChanged() }
    detail.stringValue = "停止后预览 · 选择分辨率后导出"
    if let index = CommandLine.arguments.firstIndex(of: "--preview-session"),
      CommandLine.arguments.count > index + 1
    {
      let dir = URL(fileURLWithPath: CommandLine.arguments[index + 1])
      session = dir
      rawURL = dir.appendingPathComponent("original.mp4")
      resultURL = dir.appendingPathComponent("motion.mp4")
      sessionClicks =
        (try? JSONDecoder().decode(
          [Click].self, from: Data(contentsOf: dir.appendingPathComponent("clicks.json")))) ?? []
      resultURL = nil
      previewMotion = true
      exportButton.isEnabled = true
      folderButton.isEnabled = true
      play(rawURL!)
    }
  }
  func button(_ title: String, _ action: Selector) -> NSButton {
    let b = NSButton(title: title, target: self, action: action)
    if action == #selector(start) || action == #selector(stop) || action == #selector(selectRegion)
    {
      b.cell = LeadingActionButtonCell(textCell: title)
      b.setButtonType(.momentaryPushIn)
      b.target = self
      b.action = action
      b.alignment = .center
    }
    b.bezelStyle = .rounded
    b.controlSize = .large
    b.font = NSFont.systemFont(ofSize: Typography.body, weight: .medium)
    return b
  }
  func actionIcon(_ name: String) -> NSImage? {
    NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(
      NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
  }

  func beginRecordingTimer() {
    recordingTimer?.invalidate()
    updateRecordingTime()
    let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
      self?.updateRecordingTime()
    }
    recordingTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }
  func updateRecordingTime() {
    guard let elapsed = capture?.elapsedRecordingTime() else {
      floatingStop?.title = "等待画面…"
      recordingItem?.button?.title = "◉ 等待画面"
      return
    }
    let seconds = Int(elapsed)
    let text =
      seconds >= 3600
      ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
      : String(format: "%02d:%02d", seconds / 60, seconds % 60)
    floatingStop?.title = "\(text)  停止"
    floatingStop?.toolTip = "正在录制 · 点击停止并预览"
    recordingItem?.button?.title = "● \(text)"
  }
  func showRecordingControls(preparing: Bool = false) {
    let previousFrame = recordingPanel?.frame
    hideRecordingControls()
    let panel = NSPanel(
      contentRect: NSRect(x: 0, y: 0, width: 306, height: 48),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isReleasedWhenClosed = false
    panel.isFloatingPanel = true
    panel.hidesOnDeactivate = false
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isMovableByWindowBackground = true
    let glass = RecordingBarBackground(frame: NSRect(x: 0, y: 0, width: 306, height: 48))
    glass.appearance = NSAppearance(named: .darkAqua)
    panel.contentView = glass
    func control(_ title: String, _ action: Selector, _ x: CGFloat, _ width: CGFloat) -> NSButton {
      let b = RecordingBarButton(title: title, target: self, action: action)
      b.font = .systemFont(ofSize: Typography.body, weight: .medium)
      b.isBordered = false
      b.contentTintColor = .white
      b.frame = NSRect(x: x, y: 7, width: width, height: 34)
      glass.addSubview(b)
      return b
    }
    let primary = control(
      preparing ? "开始录制" : "正在启动…", preparing ? #selector(start) : #selector(stop), 8, 130)
    primary.image = NSImage(
      systemSymbolName: preparing ? "record.circle" : "stop.circle", accessibilityDescription: nil)
    primary.imagePosition = .imageLeading
    primary.isBordered = false
    primary.contentTintColor = preparing ? .white : .systemRed
    if !preparing {
      primary.font = .monospacedDigitSystemFont(ofSize: Typography.body, weight: .medium)
    }
    primary.isEnabled = preparing
    floatingStop = primary
    let again = control(
      preparing ? "重选" : "重录", preparing ? #selector(selectRegion) : #selector(restartRecording),
      144, 76)
    let cancel = control("取消", #selector(cancelRecording), 226, 72)
    again.image = NSImage(
      systemSymbolName: preparing ? "arrow.clockwise" : "arrow.counterclockwise",
      accessibilityDescription: nil)
    cancel.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: nil)
    again.imagePosition = .imageLeading
    cancel.imagePosition = .imageLeading
    again.isEnabled = preparing
    cancel.isEnabled = preparing
    auxiliaryControls = [again, cancel]
    panel.setFrameOrigin(previousFrame?.origin ?? recordingControlsOrigin(size: panel.frame.size))
    panel.orderFrontRegardless()
    recordingPanel = panel
    if !preparing {
      let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      item.button?.title = "◉ 录制中"
      let menu = NSMenu()
      for (title, action) in [
        ("停止并生成视频", #selector(stop)), ("重新录制", #selector(restartRecording)),
        ("取消录制", #selector(cancelRecording)),
      ] {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
        entry.target = self
        menu.addItem(entry)
      }
      item.menu = menu
      recordingItem = item
    }
  }
  func recordingControlsOrigin(size: NSSize) -> NSPoint {
    let index = popup.indexOfSelectedItem
    let target: CGRect? =
      mode.selectedSegment == 2
      ? region
      : (mode.selectedSegment == 1 && available.indices.contains(index)
        ? available[index].frame : nil)
    let displayID =
      mode.selectedSegment != 1 && displays.indices.contains(index)
      ? displays[index].displayID : nil
    // ScreenCaptureKit uses top-left coordinates; AppKit uses bottom-left coordinates.
    let top = NSScreen.screens.first?.frame.maxY ?? 0
    let rect = target.map {
      CGRect(x: $0.minX, y: top - $0.maxY, width: $0.width, height: $0.height)
    }
    let screen =
      NSScreen.screens.first(where: { screen in
        if let id = displayID {
          return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value == id
        }
        return rect.map { screen.frame.contains(CGPoint(x: $0.midX, y: $0.midY)) } ?? false
      }) ?? NSScreen.main ?? NSScreen.screens[0]
    let safe = screen.visibleFrame.insetBy(dx: 12, dy: 12)
    let x = min(max((rect?.midX ?? safe.midX) - size.width / 2, safe.minX), safe.maxX - size.width)
    var y = screen.visibleFrame.minY + 24
    if let r = rect {
      if r.minY - 16 - size.height >= safe.minY {
        y = r.minY - 16 - size.height
      } else if r.maxY + 16 + size.height <= safe.maxY {
        y = r.maxY + 16
      }
    }
    return NSPoint(x: x, y: min(max(y, safe.minY), safe.maxY - size.height))
  }
  func hideRecordingControls() {
    recordingTimer?.invalidate()
    recordingTimer = nil
    recordingPanel?.orderOut(nil)
    recordingPanel = nil
    floatingStop = nil
    if let item = recordingItem { NSStatusBar.system.removeStatusItem(item) }
    recordingItem = nil
  }

  func hideRegionIndicator() {
    regionWindow?.orderOut(nil)
    regionWindow = nil
  }
  func clearRegion() {
    hideRegionIndicator()
    region = nil
    regionButton.title = mode.selectedSegment == 0 ? "选择屏幕" : "拖动选择区域"
    regionButton.image = actionIcon(mode.selectedSegment == 0 ? "display" : "cursorarrow")
  }
  func showRegionIndicator() {
    guard let r = region, displays.indices.contains(popup.indexOfSelectedItem) else { return }
    let display = displays[popup.indexOfSelectedItem]
    guard
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == display.displayID
      })
    else { return }
    hideRegionIndicator()
    let overlay = RegionWindow(
      contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
    overlay.isReleasedWhenClosed = false
    overlay.isOpaque = false
    overlay.backgroundColor = .clear
    overlay.level = .screenSaver
    overlay.ignoresMouseEvents = true
    overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    let view = RegionView(frame: CGRect(origin: .zero, size: screen.frame.size))
    view.passive = true
    view.selection = CGRect(
      x: r.minX - display.frame.minX, y: screen.frame.height - (r.maxY - display.frame.minY),
      width: r.width, height: r.height)
    overlay.contentView = view
    regionWindow = overlay
    overlay.orderFrontRegardless()
  }
  @objc func sourceChanged() { clearRegion() }
  @objc func changeMotion() { magnificationRow.isHidden = motionToggle.state != .on }
  func updateScreenHint() {
    if let id = selectedDisplayID,
      let screen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
          == id
      })
    {
      screenHint.stringValue =
        "已选择：\(screen.localizedName == "Built-in Retina Display" ? "内建屏幕" : screen.localizedName)"
    } else {
      screenHint.stringValue = "在目标屏幕上\(mode.selectedSegment == 2 ? "拖动框选" : "点击选择")"
    }
  }
  func closeSelection() {
    for w in selectionWindows {
      (w.contentView as? RegionView)?.complete = nil
      w.orderOut(nil)
    }
    selectionWindows = []
    choosing = false
  }
  func currentScreenConfiguration() -> [String] {
    NSScreen.screens.map { screen in
      let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
      return
        "\(id?.uint32Value ?? 0):\(NSStringFromRect(screen.frame)):\(screen.backingScaleFactor)"
    }.sorted()
  }
  func screensChanged() {
    // Dock/window changes can notify us without changing capture geometry.
    let configuration = currentScreenConfiguration()
    guard configuration != screenConfiguration else { return }
    screenConfiguration = configuration
    sourceGeneration += 1
    if busy {
      if let id = selectedDisplayID,
        !NSScreen.screens.contains(where: {
          ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            == id
        }), stopButton.isEnabled
      {
        stop()
      }
      return
    }
    closeSelection()
    hideRecordingControls()
    clearRegion()
    selectedDisplayID = nil
    updateScreenHint()
    refresh()
  }
  @objc func changeMode() {
    sourceGeneration += 1
    closeSelection()
    selectedDisplayID = nil
    sourceRow.isHidden = mode.selectedSegment != 1
    screenHint.isHidden = mode.selectedSegment == 1
    updateScreenHint()
    windowNote.isHidden = mode.selectedSegment != 1
    clearRegion()
    regionButton.isHidden = mode.selectedSegment == 1
    popup.removeAllItems()
    refresh()
  }
  @objc func selectRegion() {
    guard !busy, !choosing, mode.selectedSegment != 1 else { return }
    guard ensureScreenPermission() else { return }
    choosing = true
    sourceGeneration += 1
    let generation = sourceGeneration
    hideRecordingControls()
    hideRegionIndicator()
    Task {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          true, onScreenWindowsOnly: true)
        await MainActor.run {
          guard generation == self.sourceGeneration else { return }
          self.displays = content.displays
          self.popup.removeAllItems()
          self.popup.addItems(withTitles: content.displays.map { String($0.displayID) })
          NSApp.activate(ignoringOtherApps: true)
          self.window.orderOut(nil)
          for screen in NSScreen.screens {
            guard
              let id =
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
                .uint32Value, let display = self.displays.first(where: { $0.displayID == id })
            else { continue }
            let overlay = RegionWindow(
              contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            overlay.isReleasedWhenClosed = false
            overlay.isOpaque = false
            overlay.backgroundColor = .clear
            overlay.level = .screenSaver
            overlay.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            let view = RegionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.wholeScreen = self.mode.selectedSegment == 0
            view.screenName = screen.localizedName
            view.complete = { [weak self] rect in
              guard let self = self else { return }
              self.closeSelection()
              guard let r = rect,
                let index = self.displays.firstIndex(where: { $0.displayID == id })
              else {
                self.window.makeKeyAndOrderFront(nil)
                return
              }
              self.selectedDisplayID = id
              self.popup.selectItem(at: index)
              self.region =
                self.mode.selectedSegment == 2
                ? CGRect(
                  x: display.frame.minX + r.minX,
                  y: display.frame.minY + screen.frame.height - r.maxY, width: r.width,
                  height: r.height) : nil
              self.regionButton.title =
                self.region.map { "重新选择 · \(Int($0.width)) × \(Int($0.height))" } ?? "重新选择屏幕"
              self.updateScreenHint()
              self.showRegionIndicator()
              self.showRecordingControls(preparing: true)
            }
            overlay.contentView = view
            self.selectionWindows.append(overlay)
            overlay.makeKeyAndOrderFront(nil)
            overlay.makeFirstResponder(view)
          }
          // Give the screen under the pointer focus and the cursor for its selection mode.
          let pointer = NSEvent.mouseLocation
          if let active = self.selectionWindows.first(where: { $0.frame.contains(pointer) }),
            let view = active.contentView
          {
            active.makeKeyAndOrderFront(nil)
            active.makeFirstResponder(view)
            active.invalidateCursorRects(for: view)
            (view as? RegionView)?.selectionCursor.set()
          }
          if self.selectionWindows.isEmpty {
            self.choosing = false
            self.window.makeKeyAndOrderFront(nil)
            self.show(Failure(message: "没有可录制屏幕，请检查录屏授权。"))
          }
        }
      } catch {
        await MainActor.run {
          guard generation == self.sourceGeneration else { return }
          self.choosing = false
          self.window.makeKeyAndOrderFront(nil)
          self.show(error)
        }
      }
    }
  }
  @objc func refresh() {
    guard !busy, !choosing else { return }
    guard CGPreflightScreenCaptureAccess() else {
      showPermissionStatus()
      return
    }
    startButton.title = "开始录制"
    startButton.image = actionIcon("circle.fill")
    sourceGeneration += 1
    let generation = sourceGeneration
    clearRegion()
    status.stringValue = "正在读取录制来源…"
    Task {
      do {
        let content = try await SCShareableContent.excludingDesktopWindows(
          true, onScreenWindowsOnly: true)
        await MainActor.run {
          guard generation == self.sourceGeneration else { return }
          self.displays = content.displays
          self.available = content.windows.filter {
            $0.windowLayer == 0
              && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
              && $0.frame.width > 180 && $0.frame.height > 120 && !($0.title ?? "").isEmpty
          }
          self.region = nil
          self.popup.removeAllItems()
          if self.mode.selectedSegment != 1 {
            self.popup.addItems(
              withTitles: self.displays.enumerated().map {
                "屏幕 \($0.offset+1) · \($0.element.width) × \($0.element.height)"
              })
          } else {
            self.popup.addItems(
              withTitles: self.available.map {
                "\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "窗口")"
              })
          }
          self.status.stringValue = "选择录制来源，点击开始录制。"
        }
      } catch {
        await MainActor.run {
          guard generation == self.sourceGeneration else { return }
          self.show(error)
        }
      }
    }
  }
}
