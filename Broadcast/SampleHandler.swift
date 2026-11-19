import ReplayKit
import Vision
import CoreMedia
import QuartzCore
import os

/// Runs while screen broadcasting: reads the English subtitle, translates it, sends Arabic to the TV.
final class SampleHandler: RPBroadcastSampleHandler {

    // Where the subtitle sits on the phone screen (landscape, full-screen video).
    // Vision coordinates: origin bottom-left, values 0...1.
    private let regionOfInterest = CGRect(x: 0.04, y: 0.0, width: 0.92, height: 0.30)
    // Game subtitles are centred, sit near the bottom, and have a fixed text size.
    private let centerTolerance: CGFloat = 0.06       // line centre must be within 50% ± 6% of width
    private let minLineHeight: CGFloat = 0.015        // text height, as a share of screen height
    private let maxLineHeight: CGFloat = 0.06
    private let minY: CGFloat = 0.03                  // from the bottom of the screen
    private let maxY: CGFloat = 0.28

    private let interval: CFTimeInterval = 0.25
    private let clearAfter: CFTimeInterval = 1.2

    private let work = DispatchQueue(label: "sard.ocr")
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
        TVSender.send("✅ سرد متصل")
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
        let lines = (request.results ?? []).compactMap { obs -> (CGFloat, String)? in
            guard let cand = obs.topCandidates(1).first, cand.confidence > 0.4 else { return nil }
            let box = obs.boundingBox                       // relative to the region of interest
            let midX = roi.minX + box.midX * roi.width
            let midY = roi.minY + box.midY * roi.height
            let height = box.height * roi.height
            guard abs(midX - 0.5) <= centerTolerance,               // centred like a subtitle
                  height >= minLineHeight, height <= maxLineHeight, // subtitle-sized text
                  midY >= minY, midY <= maxY else { return nil }    // near the bottom
            let str = cand.string
            let letters = str.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
            guard letters >= 2, Double(letters) / Double(max(str.count, 1)) > 0.5 else { return nil } // mostly words
            return (midY, str)
        }
        .sorted { $0.0 > $1.0 }                              // top line first
        .map { $0.1 }

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
