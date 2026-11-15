import Foundation
import ImageIO
import Vision

@main enum ReadScreenText {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileReadInvalidFileName) }
        let url=URL(fileURLWithPath:CommandLine.arguments[1])
        guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw CocoaError(.fileReadCorruptFile) }
        let request=VNRecognizeTextRequest();request.recognitionLevel = .accurate;request.recognitionLanguages=["en-US"]
        try VNImageRequestHandler(cgImage:image).perform([request])
        let rows:[[String:Any]]=(request.results ?? []).compactMap { observation in
            guard let text=observation.topCandidates(1).first else { return nil }
            let box=observation.boundingBox
            return ["text":text.string,"confidence":text.confidence,"pixel_x":box.midX*Double(image.width),"pixel_y":(1-box.midY)*Double(image.height)]
        }
        let data=try JSONSerialization.data(withJSONObject:["width":image.width,"height":image.height,"text":rows],options:.sortedKeys)
        print(String(decoding:data,as:UTF8.self))
    }
}
