import ReplayKit
import Vision
import CoreMedia
import QuartzCore

/// Runs while screen broadcasting: reads the English subtitle, translates it, sends Arabic to the TV.
final class SampleHandler: RPBroadcastSampleHandler {

    // Where the subtitle sits on the phone screen (landscape, full-screen video).
    // Vision coordinates: origin bottom-left, values 0...1.
    private let regionOfInterest = CGRect(x: 0.10, y: 0.0, width: 0.80, height: 0.25)
    private let centerMin: CGFloat = 0.30   // subtitle centre must be between 30% and 70% of width
    private let centerMax: CGFloat = 0.70   // (keeps out the phone-call widget on the right)

    private let interval: CFTimeInterval = 0.4
    private let clearAfter: CFTimeInterval = 1.2

    private let work = DispatchQueue(label: "sard.ocr")
    private let gate = DispatchSemaphore(value: 1)
    private var lastFrame: CFTimeInterval = 0
    private var lastText = ""
    private var lastSeen: CFTimeInterval = 0
    private var cleared = true
    private var currentID = 0

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        _ = Glossary.shared
        TVSender.send("✅ سرد متصل")
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { TVSender.send("") }
    }

    override func broadcastFinished() {
        TVSender.send("")
        Task { await Translator.shared.save() }
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer, with type: RPSampleBufferType) {
        guard type == .video else { return }
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

        let handler = VNImageRequestHandler(cvPixelBuffer: pixel, orientation: orientation, options: [:])
        try? handler.perform([request])

        let roi = regionOfInterest
        let lines = (request.results ?? []).compactMap { obs -> (CGFloat, String)? in
            guard let cand = obs.topCandidates(1).first, cand.confidence > 0.4 else { return nil }
            let box = obs.boundingBox                       // relative to the region of interest
            let midX = roi.minX + box.midX * roi.width
            let midY = roi.minY + box.midY * roi.height
            guard midX >= centerMin, midX <= centerMax else { return nil }
            return (midY, cand.string)
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
            let ar = await Translator.shared.translate(text) ?? text
            self.work.async {
                if id == self.currentID { TVSender.send(ar, en: text) }
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
