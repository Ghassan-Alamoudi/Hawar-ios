import ReplayKit
import Vision
import CoreMedia
import QuartzCore
import os
import CoreImage

/// Runs while screen broadcasting: reads the English subtitle, translates it, sends Arabic to the TV.
final class SampleHandler: RPBroadcastSampleHandler {

    // Where the subtitle sits on the phone screen (landscape, full-screen video).
    // Vision coordinates: origin bottom-left, values 0...1.
    private let regionOfInterest = CGRect(x: 0.04, y: 0.0, width: 0.92, height: 0.30)
    // Game subtitles: centred, white text, fixed size, about 10% above the bottom of the video.
    // Positions below are relative to the 16:9 game video (black bars are ignored).
    private let centerTolerance: CGFloat = 0.06       // line centre within 50% ± 6% of width
    private let minLineHeight: CGFloat = 0.018        // text height / video height
    private let maxLineHeight: CGFloat = 0.05
    private let minVideoY: CGFloat = 0.05             // line centre, from the bottom of the video
    private let maxVideoY: CGFloat = 0.20
    private let ciContext = CIContext(options: [.cacheIntermediates: false])

    private let interval: CFTimeInterval = 0.25
    private let clearAfter: CFTimeInterval = 1.2

    private let work = DispatchQueue(label: "hawar.ocr")
    private let gate = DispatchSemaphore(value: 1)
    private var lastFrame: CFTimeInterval = 0
    private var lastText = ""
    private var lastSeen: CFTimeInterval = 0
    private var cleared = true
    private var currentID = 0
    private var lastDebug: CFTimeInterval = 0
    private var frames = 0

    override init() {
        super.init()
        TVSender.debug("extension loaded: \(Bundle.main.bundleIdentifier ?? "?")")
    }

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        _ = Glossary.shared
        RealtimeSocket.shared.connect()
        Task { _ = await Translator.shared.translate("Warm up the translator please") }   // load Apple model early
        TVSender.send("✅ حوار متصل (نسخة \(Config.build))")
        TVSender.debug("broadcast started, mem free MB: \(os_proc_available_memory() / 1_048_576)")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { TVSender.send("") }
    }

    override func broadcastFinished() {
        TVSender.send("")
        Task { await Translator.shared.save() }
        RealtimeSocket.shared.disconnect()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
        frames += 1
        let now = CACurrentMediaTime()
        guard now - lastFrame >= interval else { return }
        guard gate.wait(timeout: .now()) == .success else { return }
        guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { gate.signal(); return }
        lastFrame = now

        var orientation = CGImagePropertyOrientation.up
        if let n = CMGetAttachment(sampleBuffer, key: RPVideoSampleOrientationKey as CFString,
                                   attachmentModeOut: nil) as? NSNumber,
           let o = CGImagePropertyOrientation(rawValue: n.uint32Value) {
            orientation = o
        }
        work.async { [weak self] in
            guard let self else { return }
            self.recognize(pixel, orientation: orientation, at: now)
            self.gate.signal()
        }
    }

    private func recognize(_ pixel: CVPixelBuffer, orientation: CGImagePropertyOrientation, at now: CFTimeInterval) {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["en-US"]
        request.regionOfInterest = regionOfInterest

        let t0 = CACurrentMediaTime()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: orientation, options: [:])
        do { try handler.perform([request]) } catch { TVSender.debug("Vision error: \(error.localizedDescription)") }

        let ocrMs = Int((CACurrentMediaTime() - t0) * 1000)
        let roi = regionOfInterest
        let image = CIImage(cvPixelBuffer: pixel).oriented(orientation)
        let W = image.extent.width, H = image.extent.height
        let videoH = min(H, W * 9 / 16)                     // 16:9 video inside the screen
        let videoBottom = (H - videoH) / 2 / H              // black bar height (normalised)
        let videoScale = videoH / H

        var diag: [String] = []
        let lines = (request.results ?? []).compactMap { obs -> (CGFloat, String)? in
            guard let cand = obs.topCandidates(1).first, cand.confidence > 0.4 else { return nil }
            let b = obs.boundingBox                         // relative to the region of interest
            let full = CGRect(x: roi.minX + b.minX * roi.width, y: roi.minY + b.minY * roi.height,
                              width: b.width * roi.width, height: b.height * roi.height)
            let videoY = (full.midY - videoBottom) / videoScale
            let lineH = full.height / videoScale
            let str = cand.string
            let letters = str.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            let m = whiteMetrics(image, full)
            var why = ""
            if abs(full.midX - 0.5) > centerTolerance { why = "notCentered" }
            else if lineH < minLineHeight || lineH > maxLineHeight { why = "size" }
            else if videoY < minVideoY || videoY > maxVideoY { why = "row" }
            else if letters < 2 || Double(letters) / Double(max(str.count, 1)) <= 0.6 { why = "notWords" }
            else if !(m.ratio >= 0.03 && m.ratio <= 0.50 && m.bg < 170) { why = "notWhite" }
            diag.append(String(format: "%@ [x%.2f y%.2f h%.3f w%.2f bg%d] %@",
                               why.isEmpty ? "OK" : why, full.midX, videoY, lineH, m.ratio, m.bg,
                               String(str.prefix(28))))
            return why.isEmpty ? (full.midY, str) : nil
        }
        .sorted { $0.0 > $1.0 }                              // top line first
        .map { $0.1 }

        if !diag.isEmpty, now - lastDebug > 1.0 {
            lastDebug = now
            TVSender.debug(diag.prefix(5).joined(separator: "\n"))
        }

        let text = lines.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count

        if letters < 2 {
            if !cleared && now - lastSeen > clearAfter {
                cleared = true
                lastText = ""
                TVSender.send("")
            }
            return
        }

        lastSeen = now
        if similarity(Glossary.normalize(text), Glossary.normalize(lastText)) > 0.8 { return }

        lastText = text
        cleared = false
        currentID += 1
        let id = currentID
        Task {
            let t1 = CACurrentMediaTime()
            let tr = await Translator.shared.translate(text)
            let trMs = Int((CACurrentMediaTime() - t1) * 1000)
            if tr == nil { TVSender.debug("translate failed: \(text)") }
            let ar = tr ?? text
            self.work.async {
                if id == self.currentID {
                    TVSender.send(ar, en: text)
                    TVSender.debug("ocr \(ocrMs)ms, translate \(trMs)ms | \(text)")
                }
            }
        }
    }

    /// Subtitles are white letters on a darker picture. Signs, plates and phone screens are usually
    /// dark letters on a light background, so they have far more bright pixels (or none at all).
    private func whiteMetrics(_ image: CIImage, _ box: CGRect) -> (ratio: Double, bg: Int) {
        let e = image.extent
        let r = CGRect(x: e.minX + box.minX * e.width, y: e.minY + box.minY * e.height,
                       width: box.width * e.width, height: box.height * e.height)
        guard r.width > 4, r.height > 4 else { return (0, 255) }
        let tw = 96, th = 16
        let small = image.cropped(to: r)
            .transformed(by: CGAffineTransform(translationX: -r.minX, y: -r.minY))
            .transformed(by: CGAffineTransform(scaleX: CGFloat(tw) / r.width, y: CGFloat(th) / r.height))
        var px = [UInt8](repeating: 0, count: tw * th * 4)
        ciContext.render(small, toBitmap: &px, rowBytes: tw * 4,
                         bounds: CGRect(x: 0, y: 0, width: tw, height: th),
                         format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        var bright = 0, darkSum = 0, darkCount = 0
        for i in stride(from: 0, to: px.count, by: 4) {
            let rr = Int(px[i]), gg = Int(px[i + 1]), bb = Int(px[i + 2])
            let lum = (rr * 299 + gg * 587 + bb * 114) / 1000
            let sat = max(rr, gg, bb) - min(rr, gg, bb)
            if lum > 195 && sat < 45 { bright += 1 } else { darkSum += lum; darkCount += 1 }
        }
        let total = tw * th
        let ratio = Double(bright) / Double(total)
        let bgLum = darkCount > 0 ? darkSum / darkCount : 255
        return (ratio, bgLum)
    }

    /// 0...1 similarity using Levenshtein distance (OCR can flicker by a letter or two).
    private func similarity(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let x = Array(a), y = Array(b)
        var prev = Array(0...y.count)
        for i in 1...x.count {
            var cur = [i] + Array(repeating: 0, count: y.count)
            for j in 1...y.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return 1 - Double(prev[y.count]) / Double(max(x.count, y.count))
    }
}
