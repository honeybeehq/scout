import Foundation

public enum WalkthroughText {
    public static let inlineLimit = 16 * 1024

    public static func render(_ walkthrough: Walkthrough, bundle: URL) -> String {
        let entry = bundle.appendingPathComponent(WalkthroughBundle.entryName).path
        var head = ["[Attached walkthrough: \(entry)]"]
        var attributes = [
            "id=\"\(walkthrough.id)\"",
            "duration=\"\(clock(walkthrough.duration))\"",
            "recorded=\"\(walkthrough.createdAt)\"",
        ]
        if let place = place(of: walkthrough) { attributes.append("where=\"\(attribute(place))\"") }
        head.append("<walkthrough \(attributes.joined(separator: " "))>")

        var asks = ["Asks"]
        if walkthrough.asks.status == .unavailable {
            asks.append("Not summarised; read the transcript.")
        } else if walkthrough.asks.items.isEmpty {
            asks.append("None found; read the transcript.")
        } else {
            for (index, ask) in walkthrough.asks.items.enumerated() {
                let refs = (ask.segments ?? []) + (ask.pointers ?? []) + (ask.drawings ?? [])
                asks.append("\(index + 1). \(oneLine(ask.text))" + (refs.isEmpty ? "" : " (\(refs.joined(separator: ", ")))"))
            }
        }

        let segmentLines: [String]
        if walkthrough.transcript.status == .unavailable {
            segmentLines = ["Not available: Scout had no microphone or transcription for this recording."]
        } else if walkthrough.transcript.segments.isEmpty {
            segmentLines = ["Nothing was said."]
        } else {
            segmentLines = walkthrough.transcript.segments.map { segment in
                let refs = ((segment.pointers ?? []) + (segment.drawings ?? [])).map { " [\($0)]" }.joined()
                return "\(segment.id) \(clock(segment.start))–\(clock(segment.end)) \(oneLine(segment.text))\(refs)"
            }
        }

        var tail: [String] = []
        if !walkthrough.pointers.isEmpty {
            tail.append("")
            tail.append("Pointed at")
            let context = walkthrough.context?.apps ?? []
            tail += walkthrough.pointers.map { pointerLine($0, apps: context) }
        }
        if !walkthrough.drawings.isEmpty {
            tail.append("")
            tail.append("Drawings")
            tail += walkthrough.drawings.map(drawingLine)
        }
        if !walkthrough.frames.isEmpty {
            tail.append("")
            tail.append("Frames (in the bundle folder)")
            tail.append(walkthrough.frames.map { "\($0.id) \(clock($0.t)) \($0.file)" }.joined(separator: " · "))
        }
        tail.append("</walkthrough>")
        if walkthrough.clip != nil {
            tail.append("[Attached video: \(bundle.appendingPathComponent("clip.mp4").path)]")
        }

        func assemble(_ transcript: [String]) -> String {
            (head + asks + [""] + ["Transcript"] + transcript + tail).joined(separator: "\n") + "\n"
        }
        var text = assemble(segmentLines)
        var keep = segmentLines.count
        while text.utf8.count > inlineLimit, keep > 0, walkthrough.transcript.status == .ready, !walkthrough.transcript.segments.isEmpty {
            keep -= 1
            text = assemble(Array(segmentLines.prefix(keep)) + ["… transcript continues in walkthrough.json (\(segmentLines.count - keep) more segments)"])
        }
        return text
    }

    static func pointerLine(_ pointer: Walkthrough.Pointer, apps: [Walkthrough.AppMoment]) -> String {
        var parts: [String] = []
        if let stack = pointer.stack, !stack.isEmpty {
            parts.append(stackPath(stack))
        } else if pointer.source == .none && pointer.label == nil {
            let app = apps.last { $0.t <= pointer.t }?.name ?? apps.first?.name
            parts.append([app, "at \(Int(pointer.at.x.rounded())),\(Int(pointer.at.y.rounded())) (no element)"].compactMap { $0 }.joined(separator: " › "))
        } else {
            let app = pointer.ax?.app ?? apps.last { $0.t <= pointer.t }?.name
            let element = elementName(pointer)
            parts.append([app, element].compactMap { $0 }.joined(separator: " › ") + " (\(pointer.source.rawValue))")
        }
        if let selector = pointer.sdk?.selector, !selector.isEmpty { parts.append("selector `\(selector)`") }
        if let source = pointer.sdk?.source, !source.isEmpty { parts.append("source \(source)") }
        if let url = pointer.url, !url.isEmpty { parts.append("url \(url)") }
        if let bounds = pointer.ax?.bounds { parts.append("bbox \(box(bounds))") }
        if let frame = pointer.frame { parts.append("frame \(frame)") }
        return "\(pointer.id) \(clock(pointer.t)) \(pointer.via.rawValue) · " + parts.map(oneLine).joined(separator: " · ")
    }

    private static func elementName(_ pointer: Walkthrough.Pointer) -> String {
        let kind = pointer.sdk?.component ?? pointer.ax?.role ?? "element"
        guard let title = pointer.ax?.title, !title.isEmpty else { return pointer.label ?? kind }
        return "\(kind) \"\(truncated(title, to: 80))\""
    }

    static func stackPath(_ stack: [JSONValue]) -> String {
        stack.compactMap { level -> String? in
            guard case .object(let fields) = level, case .string(let kind)? = fields["level"] else { return nil }
            func text(_ key: String) -> String? {
                if case .string(let value)? = fields[key], !value.isEmpty { return value }
                return nil
            }
            switch kind {
            case "window": return text("title") ?? "Apiary"
            case "pane": return [text("viewType").map { $0.prefix(1).uppercased() + $0.dropFirst() + " pane" }, text("title").map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
            case "entity": return [text("kind"), text("title").map { "\"\($0)\"" } ?? text("id")].compactMap { $0 }.joined(separator: " ")
            case "element": return [text("role"), text("label").map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
            case "dom": return [text("tag") ?? text("role"), text("name").map { "\"\($0)\"" }].compactMap { $0 }.joined(separator: " ")
            default: return nil
            }
        }
        .filter { !$0.isEmpty }
        .joined(separator: " › ")
    }

    static func drawingLine(_ drawing: Walkthrough.Drawing) -> String {
        let span = drawing.end > drawing.t && clock(drawing.end) != clock(drawing.t) ? "\(clock(drawing.t))–\(clock(drawing.end))" : clock(drawing.t)
        var detail = (drawing.shape ?? .free).rawValue
        if let near = drawing.near { detail += " near \(near)" }
        detail += " (bbox \(box(drawing.bbox)))"
        if let frame = drawing.frame { detail += " · frame \(frame)" }
        return "\(drawing.id) \(span) \(detail)"
    }

    static func place(of walkthrough: Walkthrough) -> String? {
        guard let apps = walkthrough.context?.apps, !apps.isEmpty else { return nil }
        let names = apps.compactMap(\.name).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        let main = apps.last { $0.url != nil } ?? apps.first!
        var place = main.name ?? names.first ?? ""
        if let location = main.url.flatMap(shortLocation) ?? main.windowTitle { place += " · \(location)" }
        if names.count > 1 { place += " (+\(names.count - 1) more)" }
        return truncated(place, to: 120)
    }

    public static func shortLocation(_ url: String) -> String? {
        guard let components = URLComponents(string: url), let host = components.host else { return url.isEmpty ? nil : url }
        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path == "/" ? "" : components.path
        return host + port + path
    }

    public static func clock(_ milliseconds: Int) -> String {
        let seconds = milliseconds / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    static func box(_ box: Walkthrough.Box) -> String {
        "\(Int(box.x.rounded())),\(Int(box.y.rounded())) \(Int(box.w.rounded()))×\(Int(box.h.rounded()))"
    }

    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }

    static func attribute(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: ">", with: "›")
    }

    public static func truncated(_ text: String, to limit: Int) -> String {
        let flat = oneLine(text).precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        guard flat.unicodeScalars.count > limit else { return flat }
        var cut = ""
        var scalars = 0
        for character in flat {
            let size = character.unicodeScalars.count
            if scalars + size > limit - 1 { break }
            cut.append(character)
            scalars += size
        }
        let word = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? cut
        return word.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:")) + "…"
    }
}
