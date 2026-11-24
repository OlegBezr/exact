import AppKit
import ExactPackage
import ImageIO
import UniformTypeIdentifiers

@main
struct ReadTests {
    static func main() {
        let session = UUID().uuidString
        let context = ExactPackageContext(agent: true, session: session, hostSession: session,
                                          changed: { _ in }, log: { _ in }, now: { 0 }, file: { _ in nil })
        let module = ClipboardModule(context: context)
        let board = NSPasteboard(name: .init("exact.agent.clipboard." + session))
        defer { board.releaseGlobally() }

        func call(_ name: String) -> [String: Any] {
            var answer: [String: Any] = [:]
            module.later(name, [:], preferred: nil) { answer = $0 }
            return answer
        }
        func check(_ items: [NSPasteboardItem], _ strings: [String]) {
            board.clearContents()
            if !items.isEmpty { precondition(board.writeObjects(items)) }
            let answer = call("read")["exact:answer"] as? [[String: String]]
            precondition(answer == strings.map { ["text/plain": $0] })
            precondition(call("readText")["exact:answer"] as? String == (strings.first ?? ""))
        }
        func item(_ text: String, _ type: NSPasteboard.PasteboardType) -> NSPasteboardItem {
            let item = NSPasteboardItem()
            precondition(item.setString(text, forType: type))
            return item
        }
        let plain = NSPasteboard.PasteboardType(UTType.plainText.identifier)
        check([], [])
        check([item("first", plain), item("second", .string)], ["first", "second"])
        check([item("", plain), item("next", .string)], ["", "next"])
        let both = item("generic", plain)
        precondition(both.setString("standard", forType: .string))
        check([both], ["standard"])
        for (type, encoding) in [(UTType.utf16PlainText, String.Encoding.utf16LittleEndian),
                                 (.utf16ExternalPlainText, .utf16BigEndian), (.utf16ExternalPlainText, .utf16)] {
            let item = NSPasteboardItem()
            precondition(item.setData("héllo".data(using: encoding)!, forType: .init(type.identifier)))
            check([item], ["héllo"])
        }
        let legacyType = "com.apple.traditional-mac-plain-text"
        let legacy = NSPasteboardItem()
        precondition(legacy.setData("café".data(using: .macOSRoman)!, forType: .init(legacyType)))
        check([legacy], ["café"])
        precondition((try? ClipboardModule.decodeText(Data([0xff, 0x80]), type: UTType.utf8PlainText.identifier)) == nil)
        precondition((try? ClipboardModule.decodeText(Data([0xff]), type: UTType.utf16PlainText.identifier)) == nil)
        let pixels = CGContext(data: nil, width: 8, height: 4, bitsPerComponent: 8, bytesPerRow: 32,
                               space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let jpeg = NSMutableData()
        let dest = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, pixels.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
        precondition(CGImageDestinationFinalize(dest))
        guard case .success(let image) = ClipboardModule.sanitizedRaster(jpeg as Data, type: .jpeg) else {
            fatalError("could not convert oriented JPEG")
        }
        precondition(image.width == 4 && image.height == 8)
        let full = String(repeating: "é", count: 524288)
        check([item(full, .string)], [full])
        board.clearContents()
        precondition(board.writeObjects([item(full, .string), item("x", plain)]))
        precondition(call("read")["error"] as? String == "DataError")
        precondition(call("readText")["exact:answer"] as? String == full)
    }
}
