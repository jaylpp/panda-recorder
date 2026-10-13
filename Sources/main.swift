import Cocoa
import ScreenCaptureKit
import AVFoundation
import AVKit
import CoreImage
import CoreMedia

// App-owned text uses three sizes; native menus and alerts retain system typography.
enum Typography {
    static let title: CGFloat = 18
    static let body: CGFloat = 13
    static let caption: CGFloat = 12
}

struct Click: Codable { let time: Double; let x: Double; let y: Double }
struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

final class VideoCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    let queue = DispatchQueue(label: "motionrecorder.video")
    var stream: SCStream?
    var writer: AVAssetWriter!
    var input: AVAssetWriterInput!
    var audioInput:AVAssetWriterInput?
    var audioSampleCount=0
    var microphoneInput:AVAssetWriterInput?
    var microphoneSampleCount=0
    var outputURL:URL?
    var firstTime: CMTime?
    var frameCount = 0
    var failure: Error?
    var width = 1280
    var height = 720
    var bounds = CGRect.zero
    var clicks = [Click]()
    var moves = [Click]()
    var seenClicks=0
    var outsideClicks=0
    var firstHostReceipt:Double?
    let lock = NSLock()
    func start(window: SCWindow?, display: SCDisplay?, region:CGRect? = nil, excludedWindowIDs:[Int] = [], captureAudio:Bool=false, captureMicrophone:Bool=false, url: URL) async throws {
        guard window != nil || display != nil else { throw Failure(message:"请选择录制来源") }
        bounds = region ?? window?.frame ?? display!.frame
        let ratio = bounds.width / max(bounds.height,1)
        width = Int(min(1920, bounds.width * 2)) / 2 * 2
        height = Int(Double(width) / ratio) / 2 * 2
        outputURL=url
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 10_000_000]])
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else { throw Failure(message:"无法创建视频编码器") }
        writer.add(input)
        if captureAudio {
            let audio=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:2,AVEncoderBitRateKey:192000])
            audio.expectsMediaDataInRealTime=true
            guard writer.canAdd(audio) else{throw Failure(message:"无法创建音频编码器")}
            writer.add(audio);audioInput=audio
        }
        if captureMicrophone {
            guard #available(macOS 15.0, *) else{throw Failure(message:"麦克风录制需要 macOS 15 或更新版本")}
            let mic=AVAssetWriterInput(mediaType:.audio,outputSettings:[AVFormatIDKey:kAudioFormatMPEG4AAC,AVSampleRateKey:48000,AVNumberOfChannelsKey:1,AVEncoderBitRateKey:96000])
            mic.expectsMediaDataInRealTime=true
            guard writer.canAdd(mic) else{throw Failure(message:"无法创建麦克风编码器")}
            writer.add(mic);microphoneInput=mic
        }
        guard writer.startWriting() else { throw writer.error ?? Failure(message:"编码器启动失败") }
        let filter: SCContentFilter
        if let window=window { filter=SCContentFilter(desktopIndependentWindow:window) }
        else {
            let content=try await SCShareableContent.excludingDesktopWindows(false,onScreenWindowsOnly:true)
            let excluded=content.windows.filter { excludedWindowIDs.contains(Int($0.windowID)) }
            filter=SCContentFilter(display:display!,excludingWindows:excluded)
        }
        let config = SCStreamConfiguration()
        config.width = width; config.height = height
        if let region=region,let display=display {
            config.sourceRect=region.offsetBy(dx:-display.frame.minX,dy:-display.frame.minY)
        }
        config.minimumFrameInterval = CMTime(value:1,timescale:30)
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.showsCursor = true
        config.capturesAudio = captureAudio
        if #available(macOS 15.0, *) {config.captureMicrophone=captureMicrophone}
        config.sampleRate=48000;config.channelCount=2
        config.excludesCurrentProcessAudio=true
        config.queueDepth = 5
        config.ignoreShadowsSingleWindow = true
        stream = SCStream(filter:filter, configuration:config, delegate:self)
        try stream!.addStreamOutput(self,type:.screen,sampleHandlerQueue:queue)
        if captureAudio {try stream!.addStreamOutput(self,type:.audio,sampleHandlerQueue:queue)}
        if #available(macOS 15.0, *),captureMicrophone {try stream!.addStreamOutput(self,type:.microphone,sampleHandlerQueue:queue)}
        try await stream!.startCapture()
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { lock.lock();failure=error;lock.unlock() }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        if #available(macOS 15.0, *),type == .microphone {
            guard sample.isValid,let mic=microphoneInput,let first=firstTime,
                  CMSampleBufferGetPresentationTimeStamp(sample)>=first else{return}
            if mic.isReadyForMoreMediaData {
                if mic.append(sample){microphoneSampleCount+=1}
                else{lock.lock();failure=writer.error;lock.unlock()}
            }
            return
        }
        if type == .audio {
            guard sample.isValid,let audio=audioInput,let first=firstTime,
                  CMSampleBufferGetPresentationTimeStamp(sample)>=first else{return}
            if audio.isReadyForMoreMediaData {
                if audio.append(sample){audioSampleCount+=1}
                else{lock.lock();failure=writer.error;lock.unlock()}
            }
            return
        }
        guard type == .screen, sample.isValid, CMSampleBufferGetImageBuffer(sample) != nil else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample,createIfNecessary:false) as? [[SCStreamFrameInfo:Any]],let value=attachments.first?[.status] as? Int, value != SCFrameStatus.complete.rawValue { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        lock.lock()
        if firstTime == nil { firstTime = pts; firstHostReceipt=CMClockGetTime(CMClockGetHostTimeClock()).seconds; writer.startSession(atSourceTime:pts) }
        lock.unlock()
        if input.isReadyForMoreMediaData {
            if input.append(sample) { frameCount += 1 } else { lock.lock();failure=writer.error;lock.unlock() }
        }
    }
    func elapsedRecordingTime()->Double? {
        lock.lock();defer{lock.unlock()}
        guard let first=firstTime else{return nil}
        return max(0,CMClockGetTime(CMClockGetHostTimeClock()).seconds-first.seconds)
    }
    func click(_ point: CGPoint) {
        lock.lock();defer{lock.unlock()}
        seenClicks+=1
        guard bounds.contains(point) else{outsideClicks+=1;return}
        guard let first=firstTime else{return}
        let t = CMClockGetTime(CMClockGetHostTimeClock()).seconds - first.seconds
        guard t >= 0 else { return }
        clicks.append(Click(time:t,x:(point.x-bounds.minX)/bounds.width,y:(point.y-bounds.minY)/bounds.height))
    }
    func move(_ point:CGPoint) {
        lock.lock();defer{lock.unlock()}
        guard let first=firstTime,bounds.contains(point) else{return}
        let t=CMClockGetTime(CMClockGetHostTimeClock()).seconds-first.seconds
        guard t>=0,t-(moves.last?.time ?? -1)>=1.0/60 else{return}
        moves.append(Click(time:t,x:(point.x-bounds.minX)/bounds.width,y:(point.y-bounds.minY)/bounds.height))
    }
    func stop() async throws -> [Click] {
        try await stream?.stopCapture()
        await withCheckedContinuation { (c:CheckedContinuation<Void,Never>) in queue.async { c.resume() } }
        guard firstTime != nil,frameCount > 0 else { writer.cancelWriting();throw Failure(message:"没有捕获到画面，请检查录屏权限与目标窗口") }
        input.markAsFinished();audioInput?.markAsFinished();microphoneInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? Failure(message:"原始录屏写入失败") }
        if let error=failure { throw error }
        if microphoneInput != nil,audioInput != nil,let url=outputURL {try await mixAudioTracks(at:url)}
        lock.lock();let result=clicks;lock.unlock();return result
    }
}

// Normalize simultaneous system and microphone tracks into one widely playable audio track.
func mixAudioTracks(at url:URL) async throws {
    let asset=AVURLAsset(url:url),tracks=asset.tracks(withMediaType:.audio)
    guard tracks.count>1 else{return}
    let mix=AVMutableAudioMix()
    mix.inputParameters=tracks.map {track in
        let parameter=AVMutableAudioMixInputParameters(track:track)
        parameter.setVolume(0.5,at:.zero) // Leave headroom when both sources are loud.
        return parameter
    }
    let temporary=url.deletingLastPathComponent().appendingPathComponent("mixed-\(UUID().uuidString).mp4")
    defer{try? FileManager.default.removeItem(at:temporary)}
    guard let exporter=AVAssetExportSession(asset:asset,presetName:AVAssetExportPresetHighestQuality) else{throw Failure(message:"无法创建声音混合器")}
    exporter.audioMix=mix;exporter.outputURL=temporary;exporter.outputFileType = .mp4
    await withCheckedContinuation{(c:CheckedContinuation<Void,Never>) in exporter.exportAsynchronously{c.resume()}}
    guard exporter.status == .completed else{throw exporter.error ?? Failure(message:"混合麦克风与系统声音失败")}
    _ = try FileManager.default.replaceItemAt(url,withItemAt:temporary)
}

// Timing defaults reconstructed from Hh / xi / Os in the inspected application.
// Target selection and frame renderer remain independently implemented.
struct ZoomRange: Codable { var start:Double;var end:Double;var clicks:[Click] }
func zoomRanges(clicks:[Click],duration:Double)->[ZoomRange] {
    var ranges=[ZoomRange]()
    for click in clicks.sorted(by:{$0.time<$1.time}) where click.time < duration-1 {
        let start=max(0.001,floor(click.time*1000)/1000-0.3)
        let end=min(floor(click.time*1000)/1000+2.5,duration-0.8)
        guard end>start else{continue}
        if !ranges.isEmpty && ranges[ranges.count-1].end+2.5>=start {
            ranges[ranges.count-1].end=end;ranges[ranges.count-1].clicks.append(click)
        } else { ranges.append(ZoomRange(start:start,end:end,clicks:[click])) }
    }
    return ranges
}

struct Spring {
    var value:Double
    var velocity:Double=0
    mutating func move(to target:Double,dt:Double) {
        let count=max(1,Int(ceil(dt*240))),step=dt/Double(count)
        for _ in 0..<count { velocity += (170*(target-value)-50*velocity)/3*step; value += velocity*step }
    }
}

// Independent camera choreography: zero velocity/acceleration at transition ends.
func ease(_ x:Double)->Double { let u=max(0,min(1,x));return u*u*u*(u*(u*6-15)+10) }
func camera(at t:Double,ranges:[ZoomRange],magnification:Double=1.75)->(Double,Double,Double) {
    guard let r=ranges.first(where:{$0.start<=t && t<=$0.end}),let first=r.clicks.first else{return (0.5,0.5,1)}
    let fade=min(ease((t-r.start)/0.7),ease((r.end-t)/0.85))
    let z=1+(magnification-1)*fade
    var x=first.x,y=first.y
    // Freeze the composition between clicks; incidental pointer travel does not shake the camera.
    for (i,c) in r.clicks.enumerated() where i>0 {
        let prev=r.clicks[i-1]
        let start=max(prev.time,c.time-0.35)
        let duration=max(0.12,min(0.75,c.time-prev.time))
        let u=ease((t-start)/duration)
        x += (c.x-x)*u;y += (c.y-y)*u
    }
    let half=0.5/magnification
    x=max(half,min(1-half,x));y=max(half,min(1-half,y))
    return (0.5+(x-0.5)*fade,0.5+(y-0.5)*fade,z)
}

// Camera processing changes only video; mux the original audio without retiming it.
func render(raw:URL,output:URL,clicks:[Click],moves:[Click]=[],magnification:Double=1.75,progress:@escaping (Double)->Void) throws {
    let source=AVURLAsset(url:raw)
    guard let audio=source.tracks(withMediaType:.audio).first else {
        try renderVideo(raw:raw,output:output,clicks:clicks,moves:moves,magnification:magnification,progress:progress);return
    }
    let temporary=output.deletingLastPathComponent().appendingPathComponent("camera-\(UUID().uuidString).mp4")
    defer{try? FileManager.default.removeItem(at:temporary)}
    try renderVideo(raw:raw,output:temporary,clicks:clicks,moves:moves,magnification:magnification){progress($0*0.95)}
    let videoAsset=AVURLAsset(url:temporary)
    guard let video=videoAsset.tracks(withMediaType:.video).first else{throw Failure(message:"运镜视频轨缺失")}
    let composition=AVMutableComposition()
    let v=composition.addMutableTrack(withMediaType:.video,preferredTrackID:kCMPersistentTrackID_Invalid)!
    try v.insertTimeRange(CMTimeRange(start:.zero,duration:videoAsset.duration),of:video,at:.zero)
    let a=composition.addMutableTrack(withMediaType:.audio,preferredTrackID:kCMPersistentTrackID_Invalid)!
    let sourceVideoStart=source.tracks(withMediaType:.video).first?.timeRange.start ?? .zero
    let audioStart=CMTimeMaximum(audio.timeRange.start,sourceVideoStart)
    let audioEnd=CMTimeMinimum(CMTimeRangeGetEnd(audio.timeRange),CMTimeAdd(sourceVideoStart,videoAsset.duration))
    if audioEnd>audioStart {
        try a.insertTimeRange(CMTimeRange(start:audioStart,end:audioEnd),of:audio,at:CMTimeSubtract(audioStart,sourceVideoStart))
    }
    guard let exporter=AVAssetExportSession(asset:composition,presetName:AVAssetExportPresetPassthrough) else{throw Failure(message:"无法创建音视频合成器")}
    exporter.outputURL=output;exporter.outputFileType = .mp4
    let done=DispatchSemaphore(value:0)
    exporter.exportAsynchronously{done.signal()};done.wait()
    guard exporter.status == .completed else{throw exporter.error ?? Failure(message:"合成音频失败")}
    progress(1)
}

func renderVideo(raw:URL,output:URL,clicks:[Click],moves:[Click]=[],magnification:Double=1.75,progress:@escaping (Double)->Void) throws {
    let asset=AVURLAsset(url:raw)
    guard let track=asset.tracks(withMediaType:.video).first else { throw Failure(message:"原始视频没有视频轨") }
    let size=track.naturalSize,w=Int(size.width),h=Int(size.height)
    let reader=try AVAssetReader(asset:asset)
    let read=AVAssetReaderTrackOutput(track:track,outputSettings:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA])
    read.alwaysCopiesSampleData=false;reader.add(read)
    let writer=try AVAssetWriter(outputURL:output,fileType:.mp4)
    let input=AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:w,AVVideoHeightKey:h,AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:10_000_000]])
    let adaptor=AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:w,kCVPixelBufferHeightKey as String:h,kCVPixelBufferIOSurfacePropertiesKey as String:[:]])
    writer.add(input)
    guard writer.startWriting(),reader.startReading() else { throw writer.error ?? reader.error ?? Failure(message:"导出初始化失败") }
    writer.startSession(atSourceTime:.zero)
    let context=CIContext(options:[.cacheIntermediates:false])
    var first:CMTime?,frames=0
    let duration=max(asset.duration.seconds,0.01)
    let ranges=zoomRanges(clicks:clicks,duration:duration)
    try JSONEncoder().encode(ranges).write(to:output.deletingLastPathComponent().appendingPathComponent("zoom-ranges.json"))
    while let sample=read.copyNextSampleBuffer() {
        try autoreleasepool {
            guard let buffer=CMSampleBufferGetImageBuffer(sample) else{return}
            let pts=CMSampleBufferGetPresentationTimeStamp(sample)
            if first == nil { first=pts }
            let time=CMTimeSubtract(pts,first!),t=time.seconds
            let (x,y,z)=camera(at:t,ranges:ranges,magnification:magnification)
            let cw=Double(w)/z,ch=Double(h)/z
            let cx=max(cw/2,min(Double(w)-cw/2,x*Double(w)))
            let cy=max(ch/2,min(Double(h)-ch/2,(1-y)*Double(h)))
            let crop=CGRect(x:cx-cw/2,y:cy-ch/2,width:cw,height:ch)
            let image=CIImage(cvPixelBuffer:buffer).cropped(to:crop).transformed(by:CGAffineTransform(translationX:-crop.minX,y:-crop.minY)).transformed(by:CGAffineTransform(scaleX:z,y:z))
            var destination:CVPixelBuffer?
            guard let pool=adaptor.pixelBufferPool,CVPixelBufferPoolCreatePixelBuffer(nil,pool,&destination)==kCVReturnSuccess,let destination=destination else{throw Failure(message:"分配输出帧失败")}
            context.render(image,to:destination,bounds:CGRect(x:0,y:0,width:w,height:h),colorSpace:CGColorSpaceCreateDeviceRGB())
            while !input.isReadyForMoreMediaData {if writer.status == .failed {throw writer.error!};Thread.sleep(forTimeInterval:0.003)}
            guard adaptor.append(destination,withPresentationTime:time) else{throw writer.error ?? Failure(message:"输出帧写入失败")}
            frames+=1;if frames%15==0{progress(min(0.99,t/duration))}
        }
    }
    if reader.status == .failed {throw reader.error ?? Failure(message:"读取视频失败")}
    input.markAsFinished()
    let done=DispatchSemaphore(value:0);writer.finishWriting{done.signal()};done.wait()
    guard writer.status == .completed else {throw writer.error ?? Failure(message:"输出视频未完成")};progress(1)
}

final class RegionWindow:NSWindow {override var canBecomeKey:Bool {true}}
final class RegionView:NSView {
    var passive=false
    var wholeScreen=false
    var screenName=""
    var origin:CGPoint?
    var selection=CGRect.zero
    var complete:((CGRect?)->Void)?
    override var acceptsFirstResponder:Bool {true}
    override func resetCursorRects(){addCursorRect(bounds,cursor:.crosshair)}
    override func draw(_ dirtyRect:NSRect){
        NSColor.clear.setFill();bounds.fill(using:.copy)
        let shade=NSBezierPath(rect:bounds)
        if selection.width>0 {shade.appendRect(selection)}
        shade.windingRule = .evenOdd
        NSColor.black.withAlphaComponent(0.35).setFill();shade.fill()
        if selection.width>0 {

            NSColor.white.setStroke();let line=NSBezierPath(rect:selection.insetBy(dx:-1,dy:-1));line.lineWidth=2;line.stroke()
        }
        if passive {return}
        let text=wholeScreen ? "点击选择这块屏幕 · Esc 取消 — \(screenName)" : "拖动选择录制区域 · 松开确认 · Esc 取消"
        text.draw(at:CGPoint(x:32,y:bounds.height-60),withAttributes:[.font:NSFont.systemFont(ofSize:Typography.body,weight:.medium),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent){origin=convert(event.locationInWindow,from:nil)}
    override func mouseDragged(with event:NSEvent){
        guard let a=origin else{return};let p=convert(event.locationInWindow,from:nil)
        selection=CGRect(x:min(a.x,p.x),y:min(a.y,p.y),width:abs(a.x-p.x),height:abs(a.y-p.y)).intersection(bounds);needsDisplay=true
    }
    override func mouseUp(with event:NSEvent){if wholeScreen {complete?(bounds);return};mouseDragged(with:event);if selection.width>=64 && selection.height>=64 {complete?(selection)} else {origin=nil;selection = .zero;needsDisplay=true}}
    override func keyDown(with event:NSEvent){if event.keyCode == 53 {complete?(nil)}}
}

// Keep each icon and label together regardless of the button's hit-area width.
final class RecordingBarButton: NSButton {
    override func draw(_ dirtyRect:NSRect) {
        let color=(contentTintColor ?? .white).withAlphaComponent(isEnabled ? 1 : 0.45)
        let attrs:[NSAttributedString.Key:Any]=[.font:font ?? NSFont.systemFont(ofSize:13),.foregroundColor:color]
        let text=title as NSString
        let textSize=text.size(withAttributes:attrs)
        let iconSize:CGFloat=16, gap:CGFloat=6
        let total=textSize.width+(image == nil ? 0 : iconSize+gap)
        var x=(bounds.width-total)/2
        if isHighlighted {
            NSColor.white.withAlphaComponent(0.1).setFill()
            NSBezierPath(roundedRect:bounds.insetBy(dx:2,dy:2),xRadius:6,yRadius:6).fill()
        }
        if let icon=image?.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[color])) {
            icon.draw(in:NSRect(x:x,y:(bounds.height-iconSize)/2,width:iconSize,height:iconSize),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
            x += iconSize+gap
        }
        text.draw(in:NSRect(x:x,y:(bounds.height-textSize.height)/2,width:textSize.width,height:textSize.height),withAttributes:attrs)
    }
}

final class RecordingBarBackground: NSView {
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.clear.setFill();bounds.fill(using:.copy)
        NSColor(calibratedWhite:0.12,alpha:0.88).setFill()
        NSBezierPath(roundedRect:bounds,xRadius:12,yRadius:12).fill()
    }
}

final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window:NSWindow!
    var sourceRow=NSStackView()
    let screenHint=NSTextField(labelWithString:"")
    var popup=NSPopUpButton()
    var mode=NSSegmentedControl()
    var displays=[SCDisplay]()
    var status=NSTextField(labelWithString:"选择一个窗口，录下真实操作。")
    var detail=NSTextField(labelWithString:"仅录视频与窗口内点击 · 不录音 · 全程本地处理")
    var startButton=NSButton(),stopButton=NSButton(),refreshButton=NSButton(),folderButton=NSButton()
    var bar=NSProgressIndicator()
    var playerView=AVPlayerView()
    var previewPlayer=AVPlayer()
    var previewContainer=NSView()
    var pendingPreview:AVPlayerView?
    var displayObservation:NSKeyValueObservation?
    var previewURL:URL?
    var previewResume=false
    var previewPosition=CMTime.zero
    var previewObservation:NSKeyValueObservation?
    var previewGeneration=0

    var motionToggle=NSSwitch()
    var magnificationControl=NSSegmentedControl()
    var magnificationRow=NSStackView()
    var windowNote=NSTextField(labelWithString:"窗口录制时，请保持位置和大小不变。")
    var sessionMotion=true
    var sessionMagnification=1.75
    var previewMode=NSSegmentedControl()
    var microphoneToggle=NSSwitch()
    var audioToggle=NSSwitch()
    var available=[SCWindow]()
    var capture:VideoCapture?
    var monitor:Any?,localMonitor:Any?
    var session:URL?
    var rawURL:URL?,resultURL:URL?
    var busy=false
    var exitAlert:NSAlert?
    func dismissExitAlert(){
        guard let alert=exitAlert else{return}
        exitAlert=nil
        if alert.window.sheetParent != nil {window.endSheet(alert.window)}
        alert.window.orderOut(nil)
    }
    func updateExitAlert(){
        guard let alert=exitAlert else{return}
        alert.messageText=stopButton.isEnabled ? "正在录制" : "正在保存视频"
        alert.informativeText=stopButton.isEnabled ? "请先停止或取消录制，再退出应用。" : "视频保存完成后，此提示会自动关闭。"
    }
    var selectedDisplayID:CGDirectDisplayID?
    var selectionWindows=[RegionWindow]()
    var sourceGeneration=0
    var choosing=false
    var screenPermissionRequested=false
    var requestingScreenPermission=false
    var permissionAlert:NSAlert?
    var awaitingScreenPermission=false
    var screenObserver:NSObjectProtocol?
    var region:CGRect?
    var regionWindow:RegionWindow?
    var regionButton=NSButton()
    var recordingPanel:NSPanel?
    var floatingStop:NSButton?
    var recordingItem:NSStatusItem?
    var recordingTimer:Timer?
    func beginRecordingTimer(){
        recordingTimer?.invalidate()
        updateRecordingTime()
        let timer=Timer(timeInterval:0.2,repeats:true){[weak self] _ in self?.updateRecordingTime()}
        recordingTimer=timer;RunLoop.main.add(timer,forMode:.common)
    }
    func updateRecordingTime(){
        guard let elapsed=capture?.elapsedRecordingTime() else {
            floatingStop?.title="等待画面…";recordingItem?.button?.title="◉ 等待画面";return
        }
        let seconds=Int(elapsed)
        let text=seconds>=3600 ? String(format:"%d:%02d:%02d",seconds/3600,(seconds/60)%60,seconds%60) : String(format:"%02d:%02d",seconds/60,seconds%60)
        floatingStop?.title="\(text)  停止"
        floatingStop?.toolTip="正在录制 · 点击停止并生成视频"
        recordingItem?.button?.title="● \(text)"
    }
    var auxiliaryControls=[NSButton]()
    func showRecordingControls(preparing:Bool=false){
        let previousFrame=recordingPanel?.frame
        hideRecordingControls()
        let panel=NSPanel(contentRect:NSRect(x:0,y:0,width:306,height:48),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isReleasedWhenClosed=false;panel.isFloatingPanel=true;panel.hidesOnDeactivate=false
        panel.level=NSWindow.Level(rawValue:NSWindow.Level.screenSaver.rawValue+1)
        panel.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        panel.isOpaque=false;panel.backgroundColor = .clear;panel.hasShadow=false;panel.isMovableByWindowBackground=true
        let glass=RecordingBarBackground(frame:NSRect(x:0,y:0,width:306,height:48))
        glass.appearance=NSAppearance(named:.darkAqua);panel.contentView=glass
        func control(_ title:String,_ action:Selector,_ x:CGFloat,_ width:CGFloat)->NSButton {
            let b=RecordingBarButton(title:title,target:self,action:action);b.font = .systemFont(ofSize:Typography.body,weight:.medium);b.isBordered=false;b.contentTintColor = .white
            b.frame=NSRect(x:x,y:7,width:width,height:34);glass.addSubview(b);return b
        }
        let primary=control(preparing ? "开始录制" : "正在启动…",preparing ? #selector(start) : #selector(stop),8,130)
        primary.image=NSImage(systemSymbolName:preparing ? "record.circle" : "stop.circle",accessibilityDescription:nil)
        primary.imagePosition = .imageLeading
        primary.isBordered=false
        primary.contentTintColor = preparing ? .white : .systemRed
        if !preparing {primary.font = .monospacedDigitSystemFont(ofSize:Typography.body,weight:.medium)}
        primary.isEnabled=preparing;floatingStop=primary
        let again=control(preparing ? "重选" : "重录",preparing ? #selector(selectRegion) : #selector(restartRecording),144,76)
        let cancel=control("取消",#selector(cancelRecording),226,72)
        again.image=NSImage(systemSymbolName:preparing ? "arrow.clockwise" : "arrow.counterclockwise",accessibilityDescription:nil)
        cancel.image=NSImage(systemSymbolName:"xmark",accessibilityDescription:nil)
        again.imagePosition = .imageLeading;cancel.imagePosition = .imageLeading
        again.isEnabled=preparing;cancel.isEnabled=preparing;auxiliaryControls=[again,cancel]
        panel.setFrameOrigin(previousFrame?.origin ?? recordingControlsOrigin(size:panel.frame.size))
        panel.orderFrontRegardless();recordingPanel=panel
        if !preparing {
            let item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
            item.button?.title="◉ 录制中";let menu=NSMenu()
            for (title,action) in [("停止并生成视频",#selector(stop)),("重新录制",#selector(restartRecording)),("取消录制",#selector(cancelRecording))] {
                let entry=NSMenuItem(title:title,action:action,keyEquivalent:"");entry.target=self;menu.addItem(entry)
            }
            item.menu=menu;recordingItem=item
        }
    }
    func recordingControlsOrigin(size:NSSize)->NSPoint {
        let index=popup.indexOfSelectedItem
        let target: CGRect? = mode.selectedSegment == 2 ? region :
            (mode.selectedSegment == 1 && available.indices.contains(index) ? available[index].frame : nil)
        let displayID = mode.selectedSegment != 1 && displays.indices.contains(index) ? displays[index].displayID : nil
        // ScreenCaptureKit uses top-left coordinates; AppKit uses bottom-left coordinates.
        let top=NSScreen.screens.first?.frame.maxY ?? 0
        let rect=target.map{CGRect(x:$0.minX,y:top-$0.maxY,width:$0.width,height:$0.height)}
        let screen=NSScreen.screens.first(where:{screen in
            if let id=displayID {return (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id}
            return rect.map{screen.frame.contains(CGPoint(x:$0.midX,y:$0.midY))} ?? false
        }) ?? NSScreen.main ?? NSScreen.screens[0]
        let safe=screen.visibleFrame.insetBy(dx:12,dy:12)
        let x=min(max((rect?.midX ?? safe.midX)-size.width/2,safe.minX),safe.maxX-size.width)
        var y=screen.visibleFrame.minY+24
        if let r=rect {
            if r.minY-16-size.height >= safe.minY {y=r.minY-16-size.height}
            else if r.maxY+16+size.height <= safe.maxY {y=r.maxY+16}
        }
        return NSPoint(x:x,y:min(max(y,safe.minY),safe.maxY-size.height))
    }
    @objc func restartRecording(){discardRecording(restart:true)}
    @objc func cancelRecording(){
        if busy {discardRecording(restart:false)}
        else {closeSelection();hideRecordingControls();clearRegion();selectedDisplayID=nil;updateScreenHint();window.makeKeyAndOrderFront(nil)}
    }
    func discardRecording(restart:Bool){
        guard stopButton.isEnabled,let recorder=capture,let dir=session else{return}
        stopButton.isEnabled=false;hideRecordingControls()
        if let m=monitor{NSEvent.removeMonitor(m);monitor=nil}
        if let m=localMonitor{NSEvent.removeMonitor(m);localMonitor=nil}
        Task {
            _ = try? await recorder.stop()
            await MainActor.run {
                do {try FileManager.default.trashItem(at:dir,resultingItemURL:nil)}
                catch {self.resetButtons();self.show(error);return}
                self.dismissExitAlert();self.capture=nil;self.busy=false;self.rawURL=nil;self.resultURL=nil;self.session=nil
                if restart {self.start()}
                else {self.resetButtons();self.status.stringValue="已取消录制，本次素材已移到废纸篓。"}
            }
        }
    }
    func hideRecordingControls(){recordingTimer?.invalidate();recordingTimer=nil;recordingPanel?.orderOut(nil);recordingPanel=nil;floatingStop=nil;if let item=recordingItem{NSStatusBar.system.removeStatusItem(item)};recordingItem=nil}

    var emptyPreview=NSTextField(labelWithString:"录好之后，在这里看成片\n点击附近自动放大 · 平滑移镜 · 本地导出")
    func applicationDidFinishLaunching(_ n:Notification) {
        NSApp.setActivationPolicy(.regular)
        let menu=NSMenu();let root=NSMenuItem();menu.addItem(root);let sub=NSMenu();sub.addItem(withTitle:"退出熊猫录屏",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q");root.submenu=sub;NSApp.mainMenu=menu
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:1100,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="熊猫录屏";window.center();window.minSize=NSSize(width:960,height:650)
        window.titlebarAppearsTransparent=true
        window.backgroundColor=NSColor(calibratedWhite:0.97,alpha:1)
        window.appearance=NSAppearance(named:.aqua)
        let content=NSView();window.contentView=content
        func label(_ text:String,_ size:CGFloat,_ weight:NSFont.Weight = .regular)->NSTextField {
            let v=NSTextField(wrappingLabelWithString:text);v.font = .systemFont(ofSize:size,weight:weight);return v
        }
        func column(_ views:[NSView],_ spacing:CGFloat)->NSStackView {
            let v=NSStackView(views:views);v.orientation = .vertical;v.alignment = .leading;v.spacing=spacing;v.translatesAutoresizingMaskIntoConstraints=false;return v
        }
        let brand=label("熊猫录屏",Typography.title,.semibold)
        let icon=NSImageView();icon.image=NSImage(contentsOf:Bundle.main.url(forResource:"AppIcon",withExtension:"icns")!);icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant:40).isActive=true;icon.heightAnchor.constraint(equalToConstant:40).isActive=true
        let identity=NSStackView(views:[icon,brand]);identity.orientation = .horizontal;identity.spacing=10
        let section=label("录制来源",Typography.body,.semibold)
        mode=NSSegmentedControl(labels:["全屏","窗口","区域"],trackingMode:.selectOne,target:self,action:#selector(changeMode));mode.selectedSegment=0
        mode.segmentStyle = .rounded;mode.controlSize = .large;mode.font = .systemFont(ofSize:Typography.body)
        regionButton=button("选择屏幕",#selector(selectRegion));regionButton.isHidden=false
        popup.target=self;popup.action=#selector(sourceChanged)
        popup.controlSize = .large;popup.font = .systemFont(ofSize:Typography.body)
        popup.addItem(withTitle:"请选择录制来源")
        refreshButton=button("",#selector(refresh));refreshButton.image=NSImage(systemSymbolName:"arrow.clockwise",accessibilityDescription:"刷新来源")
        refreshButton.toolTip="刷新录制来源";refreshButton.setAccessibilityLabel("刷新来源")
        refreshButton.widthAnchor.constraint(equalToConstant:34).isActive=true
        sourceRow=NSStackView(views:[popup,refreshButton]);sourceRow.orientation = .horizontal;sourceRow.spacing=8;sourceRow.distribution = .fill
        popup.widthAnchor.constraint(equalTo:sourceRow.widthAnchor,constant:-42).isActive=true
        popup.setContentHuggingPriority(.defaultLow,for:.horizontal)
        startButton=button("开始录制",#selector(start));startButton.keyEquivalent="\r"
        startButton.bezelColor = .systemBlue
        startButton.image=NSImage(systemSymbolName:"record.circle",accessibilityDescription:nil)
        stopButton=button("停止录制",#selector(stop));stopButton.isEnabled=false
        let rule=NSBox();rule.boxType = .separator
        microphoneToggle.toolTip="使用系统默认麦克风"
        let note=windowNote;note.font = .systemFont(ofSize:Typography.caption);note.textColor = .secondaryLabelColor;note.isHidden=true
        note.lineBreakMode = .byWordWrapping;note.maximumNumberOfLines=2
        let soundTitle=label("声音",Typography.body,.semibold)
        func soundRow(_ title:String,_ toggle:NSSwitch)->NSStackView {
            toggle.controlSize = .small;toggle.setAccessibilityLabel(title)
            let text=label(title,Typography.body),gap=NSView()
            let row=NSStackView(views:[text,gap,toggle]);row.orientation = .horizontal;row.alignment = .centerY;row.spacing=8
            toggle.setContentHuggingPriority(.required,for:.horizontal)
            text.setContentHuggingPriority(.required,for:.horizontal)
            row.heightAnchor.constraint(equalToConstant:26).isActive=true
            return row
        }
        let systemRow=soundRow("系统声音",audioToggle),micRow=soundRow("麦克风",microphoneToggle)
        let soundGroup=column([soundTitle,systemRow,micRow],8)
        systemRow.widthAnchor.constraint(equalTo:soundGroup.widthAnchor).isActive=true
        micRow.widthAnchor.constraint(equalTo:soundGroup.widthAnchor).isActive=true
        motionToggle.state = .on;motionToggle.target=self;motionToggle.action=#selector(changeMotion)
        let motionRow=soundRow("自动运镜",motionToggle)
        magnificationControl=NSSegmentedControl(labels:["1.5×","1.75×","2×"],trackingMode:.selectOne,target:nil,action:nil)
        magnificationControl.font = .systemFont(ofSize:Typography.body);magnificationControl.selectedSegment=1;magnificationControl.segmentStyle = .rounded
        magnificationControl.setAccessibilityLabel("聚焦倍率")
        magnificationRow=column([label("聚焦倍率",Typography.body),magnificationControl],8)
        magnificationControl.widthAnchor.constraint(equalTo:magnificationRow.widthAnchor).isActive=true
        let attribution=NSTextField(labelWithString:"")
        let credit=NSMutableAttributedString(string:"Made by ",attributes:[.font:NSFont.systemFont(ofSize:Typography.caption),.foregroundColor:NSColor.secondaryLabelColor])
        credit.append(NSAttributedString(string:"🐼 熊猫 Jay",attributes:[.font:NSFont.systemFont(ofSize:Typography.caption,weight:.medium),.foregroundColor:NSColor.labelColor]))
        attribution.attributedStringValue=credit
        attribution.setAccessibilityLabel("Made by 🐼 熊猫 Jay")
        let spacer=NSView()
        screenHint.font = .systemFont(ofSize:Typography.caption);screenHint.textColor = .secondaryLabelColor
        sourceRow.isHidden=true
        let sidebar=column([identity,section,mode,sourceRow,screenHint,regionButton,soundGroup,rule,motionRow,magnificationRow,startButton,stopButton,spacer,note,attribution],14)
        sidebar.setCustomSpacing(30,after:identity);sidebar.setCustomSpacing(22,after:sourceRow);sidebar.setCustomSpacing(22,after:regionButton);sidebar.setCustomSpacing(22,after:magnificationRow)
        let panel=NSView();panel.wantsLayer=true;panel.layer?.backgroundColor=NSColor.white.cgColor;panel.translatesAutoresizingMaskIntoConstraints=false
        content.addSubview(panel);panel.addSubview(sidebar)
        let title=label("视频预览",Typography.title,.semibold)

        folderButton=button("打开文件夹",#selector(openFolder));folderButton.isEnabled=false;folderButton.image=NSImage(systemSymbolName:"folder",accessibilityDescription:nil)
        previewMode=NSSegmentedControl(labels:["原片","运镜"],trackingMode:.selectOne,target:self,action:#selector(changePreview))
        previewMode.segmentStyle = .rounded;previewMode.controlSize = .large;previewMode.font = .systemFont(ofSize:Typography.body)
        previewMode.selectedSegment = -1;previewMode.isEnabled=false;previewMode.isHidden=true
        let previews=NSStackView(views:[previewMode,NSView(),folderButton]);previews.orientation = .horizontal;previews.spacing=8
        playerView.player=previewPlayer
        playerView.allowsVideoFrameAnalysis=false;playerView.controlsStyle = .floating;playerView.videoGravity = .resizeAspect
        playerView.wantsLayer=true;playerView.layer?.cornerRadius=16;playerView.layer?.masksToBounds=true
        emptyPreview.stringValue="录制完成后，在这里预览"
        emptyPreview.font = .systemFont(ofSize:Typography.body,weight:.regular);emptyPreview.textColor=NSColor(calibratedWhite:0.7,alpha:1)
        emptyPreview.alignment = .center;emptyPreview.maximumNumberOfLines=3;emptyPreview.translatesAutoresizingMaskIntoConstraints=false
        playerView.addSubview(emptyPreview)
        NSLayoutConstraint.activate([emptyPreview.centerXAnchor.constraint(equalTo:playerView.centerXAnchor),emptyPreview.centerYAnchor.constraint(equalTo:playerView.centerYAnchor)])
        status.font = .systemFont(ofSize:Typography.caption,weight:.regular);status.maximumNumberOfLines=2
        detail.font = .systemFont(ofSize:Typography.caption);detail.textColor = .secondaryLabelColor;detail.maximumNumberOfLines=2
        bar.isIndeterminate=false;bar.minValue=0;bar.maxValue=100;bar.style = .bar;bar.isHidden=true
        previewContainer.addSubview(playerView)
        playerView.translatesAutoresizingMaskIntoConstraints=false
        NSLayoutConstraint.activate([playerView.leadingAnchor.constraint(equalTo:previewContainer.leadingAnchor),playerView.trailingAnchor.constraint(equalTo:previewContainer.trailingAnchor),playerView.topAnchor.constraint(equalTo:previewContainer.topAnchor),playerView.bottomAnchor.constraint(equalTo:previewContainer.bottomAnchor)])
        let main=column([title,previewContainer,previews,bar,status],14);main.setCustomSpacing(24,after:title)
        content.addSubview(main)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo:content.leadingAnchor),panel.topAnchor.constraint(equalTo:content.topAnchor),panel.bottomAnchor.constraint(equalTo:content.bottomAnchor),panel.widthAnchor.constraint(equalToConstant:280),
            sidebar.leadingAnchor.constraint(equalTo:panel.leadingAnchor,constant:22),sidebar.trailingAnchor.constraint(equalTo:panel.trailingAnchor,constant:-22),sidebar.topAnchor.constraint(equalTo:panel.topAnchor,constant:28),sidebar.bottomAnchor.constraint(equalTo:panel.bottomAnchor,constant:-24),
            main.leadingAnchor.constraint(equalTo:panel.trailingAnchor,constant:28),main.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-28),main.topAnchor.constraint(equalTo:content.topAnchor,constant:28),main.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-24),
            previewContainer.heightAnchor.constraint(greaterThanOrEqualToConstant:300)])
        for v in [mode,sourceRow,regionButton,soundGroup,rule,startButton,stopButton,note,motionRow,magnificationRow] as [NSView] {v.widthAnchor.constraint(equalTo:sidebar.widthAnchor).isActive=true}
        for v in [previewContainer,previews,bar,status] as [NSView] {v.widthAnchor.constraint(equalTo:main.widthAnchor).isActive=true}
        popup.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        for b in [startButton,folderButton] {b.imagePosition = .imageLeading}
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
        window.delegate=self;updateScreenHint();refresh()
        screenObserver=NotificationCenter.default.addObserver(forName:NSApplication.didChangeScreenParametersNotification,object:nil,queue:.main){[weak self] _ in self?.screensChanged()}
        detail.stringValue="停止后自动生成运镜视频 · 原片和成片均保存在本机"
        if let index=CommandLine.arguments.firstIndex(of:"--preview-session"),CommandLine.arguments.count>index+1 {
            let dir=URL(fileURLWithPath:CommandLine.arguments[index+1])
            session=dir;rawURL=dir.appendingPathComponent("original.mp4");resultURL=dir.appendingPathComponent("motion.mp4")
            folderButton.isEnabled=true;play(resultURL!)
        }
    }
    func button(_ title:String,_ action:Selector)->NSButton {let b=NSButton(title:title,target:self,action:action);b.bezelStyle = .rounded;b.controlSize = .large;b.font=NSFont.systemFont(ofSize:Typography.body,weight:.medium);return b}
    func hideRegionIndicator(){regionWindow?.orderOut(nil);regionWindow=nil}
    func clearRegion(){hideRegionIndicator();region=nil;regionButton.title=mode.selectedSegment == 0 ? "选择屏幕" : "拖动选择区域"}
    func showRegionIndicator(){
        guard let r=region,displays.indices.contains(popup.indexOfSelectedItem) else{return}
        let display=displays[popup.indexOfSelectedItem]
        guard let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == display.displayID}) else{return}
        hideRegionIndicator()
        let overlay=RegionWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
        overlay.isReleasedWhenClosed=false;overlay.isOpaque=false;overlay.backgroundColor = .clear
        overlay.level = .screenSaver;overlay.ignoresMouseEvents=true
        overlay.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
        let view=RegionView(frame:CGRect(origin:.zero,size:screen.frame.size));view.passive=true
        view.selection=CGRect(x:r.minX-display.frame.minX,y:screen.frame.height-(r.maxY-display.frame.minY),width:r.width,height:r.height)
        overlay.contentView=view;regionWindow=overlay;overlay.orderFrontRegardless()
    }
    @objc func sourceChanged(){clearRegion() }
    @objc func changeMotion(){magnificationRow.isHidden=motionToggle.state != .on}
    func updateScreenHint(){
        if let id=selectedDisplayID,let screen=NSScreen.screens.first(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id}) {
            screenHint.stringValue="已选择：\(screen.localizedName == "Built-in Retina Display" ? "内建屏幕" : screen.localizedName)"
        } else {screenHint.stringValue="在目标屏幕上\(mode.selectedSegment == 2 ? "拖动框选" : "点击选择")"}
    }
    func closeSelection(){for w in selectionWindows {(w.contentView as? RegionView)?.complete=nil;w.orderOut(nil)};selectionWindows=[];choosing=false}
    func screensChanged(){
        sourceGeneration += 1
        if busy {
            if let id=selectedDisplayID,!NSScreen.screens.contains(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id}),stopButton.isEnabled {stop()}
            return
        }
        closeSelection();hideRecordingControls();clearRegion();selectedDisplayID=nil;updateScreenHint();window.makeKeyAndOrderFront(nil);refresh()
    }
    @objc func changeMode(){sourceGeneration += 1;closeSelection();selectedDisplayID=nil;sourceRow.isHidden=mode.selectedSegment != 1;screenHint.isHidden=mode.selectedSegment == 1;updateScreenHint();windowNote.isHidden=mode.selectedSegment != 1;clearRegion();regionButton.isHidden=mode.selectedSegment == 1;popup.removeAllItems();refresh()}
    @objc func selectRegion(){
        guard !busy,!choosing else{return}
        guard ensureScreenPermission() else{return}
        choosing=true;sourceGeneration += 1;let generation=sourceGeneration
        hideRecordingControls();hideRegionIndicator()
        Task {do {
            let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            await MainActor.run {
                guard generation == self.sourceGeneration else{return}
                self.displays=content.displays;self.popup.removeAllItems();self.popup.addItems(withTitles:content.displays.map{String($0.displayID)})
                self.window.orderOut(nil)
                for screen in NSScreen.screens {
                    guard let id=(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,let display=self.displays.first(where:{$0.displayID == id}) else{continue}
                    let overlay=RegionWindow(contentRect:screen.frame,styleMask:.borderless,backing:.buffered,defer:false)
                    overlay.isReleasedWhenClosed=false;overlay.isOpaque=false;overlay.backgroundColor = .clear;overlay.level = .screenSaver
                    overlay.collectionBehavior=[.canJoinAllSpaces,.fullScreenAuxiliary]
                    let view=RegionView(frame:CGRect(origin:.zero,size:screen.frame.size));view.wholeScreen=self.mode.selectedSegment == 0;view.screenName=screen.localizedName
                    view.complete={ [weak self] rect in
                        guard let self=self else{return};self.closeSelection()
                        guard let r=rect,let index=self.displays.firstIndex(where:{$0.displayID == id}) else{self.window.makeKeyAndOrderFront(nil);return}
                        self.selectedDisplayID=id;self.popup.selectItem(at:index)
                        self.region=self.mode.selectedSegment == 2 ? CGRect(x:display.frame.minX+r.minX,y:display.frame.minY+screen.frame.height-r.maxY,width:r.width,height:r.height) : nil
                        self.regionButton.title=self.region.map{"重新选择 · \(Int($0.width)) × \(Int($0.height))"} ?? "重新选择屏幕"
                        self.updateScreenHint();self.showRegionIndicator();self.showRecordingControls(preparing:true)
                    }
                    overlay.contentView=view;self.selectionWindows.append(overlay);overlay.makeKeyAndOrderFront(nil);overlay.makeFirstResponder(view)
                }
                if self.selectionWindows.isEmpty {self.choosing=false;self.window.makeKeyAndOrderFront(nil);self.show(Failure(message:"没有可录制屏幕，请检查录屏授权。"))}
            }
        } catch {await MainActor.run{guard generation == self.sourceGeneration else{return};self.choosing=false;self.window.makeKeyAndOrderFront(nil);self.show(error)}}}
    }
    @objc func refresh(){
        guard !busy,!choosing else{return}
        guard CGPreflightScreenCaptureAccess() else{showPermissionStatus();return}
        startButton.title="开始录制"
        sourceGeneration += 1;let generation=sourceGeneration;clearRegion();status.stringValue="正在读取录制来源…"
        Task {do{let content=try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
            await MainActor.run{guard generation == self.sourceGeneration else{return};self.displays=content.displays;self.available=content.windows.filter{$0.windowLayer == 0 && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width>180 && $0.frame.height>120 && !($0.title ?? "").isEmpty};self.region=nil;self.popup.removeAllItems();if self.mode.selectedSegment != 1 {self.popup.addItems(withTitles:self.displays.enumerated().map{"屏幕 \($0.offset+1) · \($0.element.width) × \($0.element.height)"})} else {self.popup.addItems(withTitles:self.available.map{"\($0.owningApplication?.applicationName ?? "App") — \($0.title ?? "窗口")"})};self.status.stringValue="选择录制来源，点击开始录制。"}
        }catch{await MainActor.run{guard generation == self.sourceGeneration else{return};self.show(error)}}}
    }
    @objc func start(){
        guard !busy else{return}
        guard ensureScreenPermission() else{return}
        if microphoneToggle.state == .on {
            guard #available(macOS 15.0, *) else{show(Failure(message:"麦克风录制需要 macOS 15 或更新版本"));return}
            switch AVCaptureDevice.authorizationStatus(for:.audio) {
            case .notDetermined:
                AVCaptureDevice.requestAccess(for:.audio){granted in DispatchQueue.main.async{
                    if granted {self.start()} else {self.show(Failure(message:"麦克风未授权，请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"))}
                }}
                return
            case .authorized:break
            default:show(Failure(message:"麦克风未授权，请在系统设置 → 隐私与安全性 → 麦克风中允许本应用。"));return
            }
        }

        if mode.selectedSegment != 1 {
            guard let id=selectedDisplayID else{selectRegion();return}
            guard NSScreen.screens.contains(where:{($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id}),let index=displays.firstIndex(where:{$0.displayID == id}) else{selectedDisplayID=nil;clearRegion();selectRegion();return}
            popup.selectItem(at:index)
        }
        let index=popup.indexOfSelectedItem
        guard !busy,index>=0 else{return}
        let whole=mode.selectedSegment != 1
        if mode.selectedSegment == 2 && region == nil {selectRegion();return}
        guard whole ? index<displays.count : index<available.count else{return}
        let selected:SCWindow?=whole ? nil : available[index]
        let display:SCDisplay?=whole ? displays[index] : nil
        let selectedRegion=mode.selectedSegment == 2 ? region : nil
        let sourceName=selectedRegion != nil ? "自选区域" : whole ? "屏幕 \(index+1)" : (selected?.title ?? "窗口")
        if selectedRegion != nil {showRegionIndicator()}
        window.orderOut(nil);playerView.player?.pause();showRecordingControls()
        let excludedIDs=[regionWindow?.windowNumber,recordingPanel?.windowNumber].compactMap{$0}
        regionButton.isEnabled=false
        let captureAudio=audioToggle.state == .on;audioToggle.isEnabled=false
        let captureMicrophone=microphoneToggle.state == .on;microphoneToggle.isEnabled=false
        mode.isEnabled=false
        sessionMotion=motionToggle.state == .on;sessionMagnification=[1.5,1.75,2.0][max(0,magnificationControl.selectedSegment)]
        motionToggle.isEnabled=false;magnificationControl.isEnabled=false
        busy=true;startButton.isEnabled=false;refreshButton.isEnabled=false;popup.isEnabled=false;folderButton.isEnabled=false;bar.doubleValue=0
        do{
            let base=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/REA-MotionRecorder",isDirectory:true)
            let dir=base.appendingPathComponent(UUID().uuidString,isDirectory:true);try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true);session=dir;rawURL=dir.appendingPathComponent("original.mp4");resultURL=dir.appendingPathComponent("motion.mp4")
            let recorder=VideoCapture();capture=recorder
            status.stringValue="正在开始录制…"
            Task{do{try await recorder.start(window:selected,display:display,region:selectedRegion,excludedWindowIDs:excludedIDs,captureAudio:captureAudio,captureMicrophone:captureMicrophone,url:self.rawURL!);await MainActor.run{
                self.monitor=NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.mouseMoved,.leftMouseDragged,.rightMouseDragged]){e in if let p=e.cgEvent?.location{if e.type == .leftMouseDown || e.type == .rightMouseDown {recorder.click(p)} else {recorder.move(p)}}}
                self.localMonitor=NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.rightMouseDown,.mouseMoved,.leftMouseDragged,.rightMouseDragged]){e in if let p=e.cgEvent?.location{if e.type == .leftMouseDown || e.type == .rightMouseDown {recorder.click(p)} else {recorder.move(p)}};return e}
                self.beginRecordingTimer();self.auxiliaryControls.forEach{$0.isEnabled=true};self.floatingStop?.isEnabled=true;self.stopButton.isEnabled=true;self.status.stringValue="● 正在录制 \(sourceName)，完成后点停止。";self.detail.stringValue="录制中 · 点击悬浮停止按钮或菜单栏停止，自动生成 MP4。"
            }}catch{await MainActor.run{self.resetButtons();self.show(error)}}}
        }catch{resetButtons();show(error)}
    }
    func revealMainWindow(){
        if window.isMiniaturized {window.deminiaturize(nil)}
        NSApp.activate(ignoringOtherApps:true)
        window.makeKeyAndOrderFront(nil)
    }
    @objc func stop(){
        guard stopButton.isEnabled,let recorder=capture,let dir=session,let raw=rawURL,let result=resultURL else{return}
        hideRegionIndicator();hideRecordingControls()
        stopButton.isEnabled=false
        if let monitor=monitor{NSEvent.removeMonitor(monitor);self.monitor=nil};if let localMonitor=localMonitor{NSEvent.removeMonitor(localMonitor);self.localMonitor=nil}
        updateExitAlert()
        status.stringValue="正在结束录制…"
        Task{do{let clicks=try await recorder.stop();await MainActor.run{self.revealMainWindow()};let data=try JSONEncoder().encode(clicks);try data.write(to:dir.appendingPathComponent("clicks.json"));let moves=recorder.moves;try JSONEncoder().encode(moves).write(to:dir.appendingPathComponent("moves.json"));let meta:[String:Any] = ["autoMotion":self.sessionMotion,"magnification":self.sessionMagnification,"microphoneSampleCount":recorder.microphoneSampleCount,"microphoneEnabled":recorder.microphoneInput != nil,"audioSampleCount":recorder.audioSampleCount,"systemAudioEnabled":recorder.audioInput != nil,"seenClicks":recorder.seenClicks,"outsideClicks":recorder.outsideClicks,"firstPTS":recorder.firstTime?.seconds ?? -1,"firstHostReceipt":recorder.firstHostReceipt ?? -1,"frameCount":recorder.frameCount,"bounds":[recorder.bounds.minX,recorder.bounds.minY,recorder.bounds.width,recorder.bounds.height],"mouseEventSource":"NSEvent.cgEvent.location"];try JSONSerialization.data(withJSONObject:meta,options:.prettyPrinted).write(to:dir.appendingPathComponent("capture-metadata.json"));if !self.sessionMotion {
                await MainActor.run{self.resultURL=nil;self.status.stringValue="已保存";self.resetButtons();self.folderButton.isEnabled=true;self.play(raw)}
                return
            }
            await MainActor.run{self.status.stringValue="正在生成运镜…";self.bar.isHidden=false}
            DispatchQueue.global(qos:.userInitiated).async{do{try render(raw:raw,output:result,clicks:clicks,moves:moves,magnification:self.sessionMagnification){p in DispatchQueue.main.async{self.bar.doubleValue=p*100}};DispatchQueue.main.async{self.status.stringValue="已保存";self.resetButtons();self.folderButton.isEnabled=true;self.play(result)}}catch{DispatchQueue.main.async{self.resetButtons();self.folderButton.isEnabled=true;self.show(error)}}}
        }catch{await MainActor.run{self.resetButtons();self.show(error)}}}
    }
    func resetButtons(){motionToggle.isEnabled=true;magnificationControl.isEnabled=true;bar.isHidden=true;microphoneToggle.isEnabled=true;audioToggle.isEnabled=true;dismissExitAlert();hideRegionIndicator();hideRecordingControls();revealMainWindow();regionButton.isEnabled=true;busy=false;mode.isEnabled=true;detail.stringValue="停止后自动生成运镜视频 · 原片和成片均保存在本机";startButton.isEnabled=true;refreshButton.isEnabled=true;popup.isEnabled=true;stopButton.isEnabled=false;capture=nil}
    func showPermissionStatus(){
        awaitingScreenPermission=true
        startButton.title="授权录屏"
        status.stringValue="首次使用，请先允许熊猫录屏访问屏幕。"
    }
    func ensureScreenPermission()->Bool {
        if CGPreflightScreenCaptureAccess(){startButton.title="开始录制";return true}
        showPermissionStatus()
        guard permissionAlert == nil,!requestingScreenPermission else{return false}
        let alert=NSAlert();permissionAlert=alert
        alert.messageText="允许录制屏幕"
        alert.informativeText=screenPermissionRequested
            ? "在系统设置的「录屏与系统录音」中开启熊猫录屏，再按系统提示重新打开应用。"
            : "接下来会显示 macOS 的录屏授权提示。请通过系统提示打开设置，并开启熊猫录屏。"
        alert.addButton(withTitle:screenPermissionRequested ? "打开系统设置" : "前往授权");alert.addButton(withTitle:"暂不")
        alert.beginSheetModal(for:window){[weak self] response in
            guard let self=self else{return};self.permissionAlert=nil
            guard response == .alertFirstButtonReturn else{return}
            if self.screenPermissionRequested {
                NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
            } else {
                // Let our sheet close before macOS presents its own permission prompt.
                DispatchQueue.main.async {self.requestScreenAuthorization()}
            }
        }
        return false
    }
    func requestScreenAuthorization(){
        guard !requestingScreenPermission else{return}
        requestingScreenPermission=true;screenPermissionRequested=true
        NSApp.activate(ignoringOtherApps:true)
        status.stringValue="请在 macOS 授权提示中允许录屏。"
        if CGRequestScreenCaptureAccess() {
            requestingScreenPermission=false;awaitingScreenPermission=false;refresh();return
        }
        // Use the capture framework to register the actual application requesting access.
        // Do not immediately activate Settings and cover the system permission prompt.
        Task {
            do {_ = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)}
            catch {
                let e=error as NSError
                if e.domain != SCStreamErrorDomain || e.code != -3801 {
                    await MainActor.run{self.requestingScreenPermission=false;self.show(error)};return
                }
            }
            await MainActor.run {
                self.requestingScreenPermission=false
                if CGPreflightScreenCaptureAccess(){self.awaitingScreenPermission=false;self.refresh()}
                else {self.status.stringValue="在系统设置中开启熊猫录屏；如已开启，请按系统提示重新打开。"}
            }
        }
    }
    func applicationDidBecomeActive(_ notification:Notification){
        guard awaitingScreenPermission,window != nil,!busy,CGPreflightScreenCaptureAccess() else{return}
        awaitingScreenPermission=false;startButton.title="开始录制";refresh()
    }
    func show(_ error:Error){
        let nsError=error as NSError
        if nsError.domain == SCStreamErrorDomain && nsError.code == -3801 {
            showPermissionStatus();_ = ensureScreenPermission();return
        }
        status.stringValue="失败：\(error.localizedDescription)"
        let alert=NSAlert();alert.messageText="操作未完成";alert.informativeText=error.localizedDescription
        alert.addButton(withTitle:"知道了");alert.beginSheetModal(for:window)
    }
    func play(_ url:URL){
        guard FileManager.default.fileExists(atPath:url.path) else{return}
        if previewURL == url,pendingPreview == nil{return}
        let wasSwitching=pendingPreview != nil
        previewGeneration+=1
        let generation=previewGeneration
        previewObservation?.invalidate();displayObservation?.invalidate()
        pendingPreview?.player?.pause();pendingPreview?.player?.replaceCurrentItem(with:nil)
        pendingPreview?.removeFromSuperview();pendingPreview=nil
        let comparing=previewURL?.deletingLastPathComponent() == url.deletingLastPathComponent()
        let position=comparing ? (wasSwitching ? previewPosition : previewPlayer.currentTime()) : .zero
        let resume = comparing ? (wasSwitching ? previewResume : previewPlayer.rate > 0) : true
        previewPosition=position;previewResume=resume
        previewPlayer.pause()
        let item=AVPlayerItem(url:url),next=AVPlayer(playerItem:nil),view=AVPlayerView()
        next.isMuted=previewPlayer.isMuted;next.volume=previewPlayer.volume
        view.player=next;view.controlsStyle = .floating;view.videoGravity = .resizeAspect
        view.allowsVideoFrameAnalysis=false;view.wantsLayer=true;view.layer?.cornerRadius=16;view.layer?.masksToBounds=true
        view.translatesAutoresizingMaskIntoConstraints=false
        // Keep the current view above the staging view until the new frame is ready.
        previewContainer.addSubview(view,positioned:.below,relativeTo:playerView)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:previewContainer.leadingAnchor),view.trailingAnchor.constraint(equalTo:previewContainer.trailingAnchor),view.topAnchor.constraint(equalTo:previewContainer.topAnchor),view.bottomAnchor.constraint(equalTo:previewContainer.bottomAnchor)])
        pendingPreview=view;previewMode.isEnabled=true
        previewMode.isHidden = !(resultURL.map{FileManager.default.fileExists(atPath:$0.path)} ?? false)
        previewObservation=item.observe(\.status,options:[.new]){[weak self] item,_ in
            DispatchQueue.main.async {
                guard let self=self,self.previewGeneration == generation else{return}
                if item.status == .failed {
                    view.removeFromSuperview();self.pendingPreview=nil
                    self.previewMode.selectedSegment=self.previewURL == self.resultURL ? 1 : 0
                    self.status.stringValue="预览加载失败，请重试。"
                    if resume {self.previewPlayer.play()};return
                }
                guard item.status == .readyToPlay else{return}
                let last=CMTimeMaximum(.zero,CMTimeSubtract(item.duration,CMTime(value:1,timescale:30)))
                let target=position.isNumeric ? CMTimeMinimum(position,last) : .zero
                next.seek(to:target,toleranceBefore:.zero,toleranceAfter:.zero){[weak self] finished in
                    DispatchQueue.main.async {
                        guard let self=self,finished,self.previewGeneration == generation else{return}
                        self.displayObservation=view.observe(\.isReadyForDisplay,options:[.initial,.new]){[weak self] view,_ in
                            DispatchQueue.main.async {
                                guard let self=self,self.previewGeneration == generation,self.pendingPreview === view,view.isReadyForDisplay else{return}
                                self.displayObservation?.invalidate();self.previewObservation?.invalidate()
                                self.playerView.removeFromSuperview();self.previewPlayer.replaceCurrentItem(with:nil)
                                self.playerView=view;self.previewPlayer=next;self.previewURL=url;self.pendingPreview=nil
                                self.previewMode.selectedSegment=url == self.resultURL ? 1 : 0
                                if resume {next.play()}
                            }
                        }
                    }
                }
            }
        }
        next.replaceCurrentItem(with:item)
    }
    @objc func changePreview(){if previewMode.selectedSegment == 0 {previewRaw()} else {previewResult()}}
    @objc func previewRaw(){if let url=rawURL{play(url)}}
    @objc func previewResult(){if let url=resultURL{play(url)}}
    @objc func openFolder(){if let session=session{NSWorkspace.shared.open(session)}}
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool{false}
    func windowWillClose(_ notification:Notification){if let closed=notification.object as? NSWindow,closed === window,!busy {NSApp.terminate(nil)}}
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        guard busy else{dismissExitAlert();return .terminateNow}
        window.makeKeyAndOrderFront(nil)
        if exitAlert == nil {
            let alert=NSAlert();exitAlert=alert
            updateExitAlert();alert.addButton(withTitle:"知道了")
            alert.beginSheetModal(for:window){[weak self,weak alert] _ in
                if self?.exitAlert === alert {self?.exitAlert=nil}
            }
        } else {updateExitAlert()}
        return .terminateCancel
    }
}
if CommandLine.arguments.count == 5 && CommandLine.arguments[1] == "--render" {
    do {
        let raw=URL(fileURLWithPath:CommandLine.arguments[2])
        let clicks=try JSONDecoder().decode([Click].self,from:Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3])))
        let moveURL=raw.deletingLastPathComponent().appendingPathComponent("moves.json")
        let moves=(try? JSONDecoder().decode([Click].self,from:Data(contentsOf:moveURL))) ?? []
        try render(raw:raw,output:URL(fileURLWithPath:CommandLine.arguments[4]),clicks:clicks,moves:moves){_ in}
        print("Render complete")
    } catch { fputs("Render failed: \(error.localizedDescription)\n",stderr);exit(1) }
} else {
    let delegate=App();let application=NSApplication.shared;application.delegate=delegate;application.run()
}
