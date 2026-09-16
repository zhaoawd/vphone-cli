import Foundation
import Vision

// Manual acceptance only: these labels are specific to the Simplified Chinese rig2 setup.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: a3-screen-state <image>\n".utf8))
    exit(2)
}
let request = VNRecognizeTextRequest()
request.recognitionLevel = .accurate
request.recognitionLanguages = ["zh-Hans", "en-US"]
do {
    try VNImageRequestHandler(url: URL(fileURLWithPath: CommandLine.arguments[1]), options: [:]).perform([request])
} catch {
    FileHandle.standardError.write(Data("image recognition failed: \(error)\n".utf8))
    exit(2)
}
let rows = (request.results ?? []).compactMap { item -> (String, CGRect)? in
    guard let text = item.topCandidates(1).first?.string else { return nil }
    return (text, item.boundingBox)
}
let settings = rows.contains { $0.0 == "设置" && $0.1.minY > 0.8 }
let homeLabels = ["FaceTime通话", "App Store", "地图", "健康", "钱包"]
let homeMatches = homeLabels.filter { label in rows.contains { $0.0 == label } }.count
print(settings ? "SETTINGS" : homeMatches >= 3 ? "HOME" : "UNKNOWN")
