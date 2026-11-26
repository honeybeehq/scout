import AppKit
import Observation
import SwiftUI

enum PickerVariant: String, CaseIterable {
    case palette
    case sections
    case recent

    var size: CGSize {
        switch self {
        case .palette: CGSize(width: 520, height: 400)
        case .sections: CGSize(width: 460, height: 540)
        case .recent: CGSize(width: 500, height: 492)
        }
    }

    var label: String {
        switch self {
        case .palette: "A · Palette"
        case .sections: "B · Sections"
        case .recent: "C · Recent and all"
        }
    }
}

struct PickerSection: Identifiable {
    var id: String
    var title: String
    var rows: [PickerEntry]
}

@Observable
final class PickerProtoModel {
    enum Scope: String, CaseIterable {
        case all = "All"
        case champions = "Champions"
        case projects = "Projects"
        case sessions = "Sessions"
    }

    let variant: PickerVariant
    let entries: [PickerEntry]
    var query = "" {
        didSet {
            selection = 0
            stripSelection = 0
            inStrip = showsStrip
        }
    }
    var scope: Scope = .all {
        didSet {
            selection = 0
            inStrip = showsStrip
        }
    }
    var selection = 0
    var stripSelection = 0
    var inStrip = false
    var confirmation: String?
    var focusToken = 0
    var onDismiss: (() -> Void)?

    init(variant: PickerVariant, entries: [PickerEntry]) {
        self.variant = variant
        self.entries = entries
        inStrip = variant == .recent
    }

    var showsStrip: Bool { variant == .recent && query.isEmpty && scope == .all }

    var strip: [PickerEntry] {
        guard showsStrip else { return [] }
        return Array(entries.filter { $0.recent != nil }.sorted { ($0.recent ?? 0) < ($1.recent ?? 0) }.prefix(5))
    }

    private var words: [Substring] { query.lowercased().split(whereSeparator: \.isWhitespace) }

    private func score(_ entry: PickerEntry) -> Int? {
        var total = 0
        let title = entry.title.lowercased()
        for word in words {
            guard entry.search.contains(word) else { return nil }
            if title.hasPrefix(word) {
                total += 0
            } else if title.contains(" \(word)") || title.contains("(\(word)") {
                total += 1
            } else if title.contains(word) {
                total += 2
            } else {
                total += 4
            }
        }
        return total
    }

    private func matching(_ rows: [PickerEntry]) -> [PickerEntry] {
        guard !words.isEmpty else { return rows }
        let scored = rows.enumerated().compactMap { index, entry in score(entry).map { (index, $0, entry) } }
        return scored.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }.map(\.2)
    }

    private func inScope(_ entry: PickerEntry) -> Bool {
        switch scope {
        case .all: true
        case .champions: entry.kind == .champion
        case .projects: entry.kind == .orchestrator
        case .sessions: entry.kind == .session || entry.kind == .clipboard
        }
    }

    var sections: [PickerSection] {
        switch variant {
        case .palette:
            let ordered = entries.filter(\.focused) + entries.filter { $0.recent != nil && !$0.focused }.sorted { ($0.recent ?? 0) < ($1.recent ?? 0) } + entries.filter { $0.recent == nil && !$0.focused }
            return [PickerSection(id: "all", title: "", rows: matching(ordered))]
        case .sections:
            let groups: [(String, String, (PickerEntry) -> Bool)] = [
                ("focused", "Focused chat", { $0.focused }),
                ("champions", "Champions", { $0.kind == .champion && !$0.focused }),
                ("projects", "Project orchestrators", { $0.kind == .orchestrator && !$0.focused }),
                ("sessions", "Sessions", { $0.kind == .session && !$0.focused }),
                ("other", "Other", { $0.kind == .clipboard }),
            ]
            return groups.compactMap { id, title, test in
                let rows = matching(entries.filter(test))
                return rows.isEmpty ? nil : PickerSection(id: id, title: title, rows: rows)
            }
        case .recent:
            let recentIDs = Set(strip.map(\.id))
            let rows = entries.filter { inScope($0) && !recentIDs.contains($0.id) }
            return [PickerSection(id: "list", title: showsStrip ? "Everything else" : "", rows: matching(rows))]
        }
    }

    var flat: [PickerEntry] { sections.flatMap(\.rows) }

    var sectionStarts: [Int] {
        var starts: [Int] = []
        var offset = 0
        for section in sections {
            starts.append(offset)
            offset += section.rows.count
        }
        return starts
    }

    var selected: PickerEntry? {
        if inStrip, showsStrip {
            let items = strip
            return items.indices.contains(stripSelection) ? items[stripSelection] : nil
        }
        let rows = flat
        return rows.indices.contains(selection) ? rows[selection] : nil
    }

    var selectedRowID: String? {
        if inStrip, showsStrip { return nil }
        return selected?.id
    }

    func vertical(_ delta: Int) {
        let count = flat.count
        if inStrip, showsStrip {
            if delta > 0, count > 0 {
                inStrip = false
                selection = 0
            }
            return
        }
        if showsStrip, selection == 0, delta < 0 {
            inStrip = true
            return
        }
        guard count > 0 else { return }
        if variant == .recent {
            selection = min(max(selection + delta, 0), count - 1)
        } else {
            selection = (selection + delta + count) % count
        }
    }

    func horizontal(_ delta: Int) -> Bool {
        guard inStrip, showsStrip else { return false }
        stripSelection = min(max(stripSelection + delta, 0), max(strip.count - 1, 0))
        return true
    }

    func tab(_ delta: Int) {
        switch variant {
        case .palette:
            break
        case .sections:
            let starts = sectionStarts
            guard !starts.isEmpty else { return }
            if delta > 0 {
                selection = starts.first { $0 > selection } ?? starts[0]
            } else {
                selection = starts.last { $0 < selection } ?? starts[starts.count - 1]
            }
        case .recent:
            let all = Scope.allCases
            let index = all.firstIndex(of: scope) ?? 0
            scope = all[(index + delta + all.count) % all.count]
        }
    }

    func choose(send: Bool) {
        guard let target = selected else { return }
        switch target.kind {
        case .clipboard:
            confirmation = "Copied. Paste it anywhere with ⌘V."
        case .orchestrator:
            confirmation = "\(send ? "Sent to" : "Pasted into") the orchestrator of \(target.title)"
        default:
            confirmation = "\(send ? "Sent to" : "Pasted into") \(target.shortTitle)"
        }
    }
}

struct PickerVariantView: View {
    @Environment(PickerProtoModel.self) private var model

    var body: some View {
        Group {
            if let line = model.confirmation {
                HStack(spacing: 8) {
                    StatusDot(tone: .positive)
                    Text(line)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Palette.text)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                switch model.variant {
                case .palette: PaletteVariant()
                case .sections: SectionsVariant()
                case .recent: RecentVariant()
                }
            }
        }
        .frame(width: model.variant.size.width, height: model.variant.size.height, alignment: .topLeading)
        .background(Palette.hud, in: .rect(cornerRadius: Radius.panel, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.panel, style: .continuous).strokeBorder(Palette.stroke, lineWidth: 1))
        .clipShape(.rect(cornerRadius: Radius.panel, style: .continuous))
    }
}

private struct SearchRow: View {
    @Environment(PickerProtoModel.self) private var model
    @FocusState private var focused: Bool
    var prompt: String
    var large = true

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: large ? 14 : 12, weight: .semibold))
                .foregroundStyle(Palette.textTertiary)
            TextField(prompt, text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: large ? 15 : 13))
                .foregroundStyle(Palette.text)
                .focused($focused)
            if !model.query.isEmpty {
                Text("\(model.flat.count) \(model.flat.count == 1 ? "match" : "matches")")
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .onChange(of: model.focusToken, initial: true) { focused = true }
    }
}

private struct FooterHints: View {
    var items: [(String, String)]

    var body: some View {
        HStack(spacing: 12) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 5) {
                    KeyHint(item.0)
                    Text(item.1)
                        .font(Typography.caption)
                        .foregroundStyle(Palette.textTertiary)
                }
            }
        }
    }
}

private struct WalkthroughChip: View {
    var body: some View {
        HStack(spacing: 6) {
            StatusDot(tone: .positive, size: 5)
            Text("Walkthrough · \(PickerFixture.walkthroughMeta)")
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .monospacedDigit()
        }
    }
}

private struct PaletteVariant: View {
    @Environment(PickerProtoModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                WalkthroughChip()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            SearchRow(prompt: "Send to a Champion, Project or session")
                .padding(.horizontal, 16)
                .frame(height: 40)
            Rectangle().fill(Palette.hairline).frame(height: 1)
            list
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack {
                FooterHints(items: [("↑↓", "Move"), ("↩", "Paste"), ("⌘↩", "Send now"), ("esc", "Clipboard only")])
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
    }

    @ViewBuilder
    private var list: some View {
        let rows = model.flat
        if rows.isEmpty {
            Text("Nothing matches “\(model.query)”.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == model.selection)
                                .id(entry.id)
                                .contentShape(.rect)
                                .onTapGesture {
                                    model.selection = index
                                    model.choose(send: false)
                                }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                .onChange(of: model.selection) { if let id = model.selectedRowID { proxy.scrollTo(id) } }
            }
        }
    }

    private func row(_ entry: PickerEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            EntryIcon(entry: entry, size: 20, look: .bare)
            HighlightText(text: entry.title, query: model.query, weight: selected ? .medium : .regular, color: Palette.text, dim: model.query.isEmpty ? Palette.text : Palette.textSecondary)
                .lineLimit(1)
            if entry.focused {
                Text("Focused")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
            Spacer(minLength: 8)
            Text([entry.workspace, entry.kindLabel].compactMap { $0 }.joined(separator: " · "))
                .font(Typography.caption)
                .foregroundStyle(Palette.textTertiary)
                .lineLimit(1)
            KeyHint("↩")
                .opacity(selected ? 1 : 0)
        }
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 32)
        .background(selected ? Palette.selection : .clear, in: .rect(cornerRadius: Radius.control, style: .continuous))
        .overlay(alignment: .leading) {
            if selected {
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(Palette.ink)
                    .frame(width: 2, height: 16)
            }
        }
    }
}

private struct SectionsVariant: View {
    @Environment(PickerProtoModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Send walkthrough")
                    .font(Typography.headline)
                    .foregroundStyle(Palette.text)
                Text(PickerFixture.walkthroughMeta)
                    .font(Typography.caption)
                    .monospacedDigit()
                    .foregroundStyle(Palette.textTertiary)
                Spacer()
                StatusBadge(text: "Ready", tone: .positive)
            }
            .padding(.horizontal, 16)
            .padding(.top, 14)
            Text(PickerFixture.asks[0] + (PickerFixture.asks.count > 1 ? " · +\(PickerFixture.asks.count - 1) more" : ""))
                .font(Typography.callout)
                .foregroundStyle(Palette.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 16)
                .padding(.top, 4)
            SearchRow(prompt: "Find a Champion, Project or session", large: false)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(Palette.fill, in: .rect(cornerRadius: Radius.control, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Palette.hairline))
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)
            list
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack(spacing: 12) {
                FooterHints(items: [("⇥", "Next group"), ("esc", "Clipboard only")])
                Spacer()
                Button("Paste  ↩") { model.choose(send: false) }
                    .buttonStyle(PrimaryButtonStyle(large: false))
            }
            .padding(.horizontal, 14)
            .frame(height: 48)
        }
    }

    @ViewBuilder
    private var list: some View {
        let sections = model.sections
        if sections.isEmpty {
            Text("Nothing matches “\(model.query)”.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let starts = model.sectionStarts
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(Array(sections.enumerated()), id: \.element.id) { sectionIndex, section in
                            Section {
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { rowIndex, entry in
                                    let index = starts[sectionIndex] + rowIndex
                                    row(entry, selected: index == model.selection)
                                        .id(entry.id)
                                        .contentShape(.rect)
                                        .onTapGesture {
                                            model.selection = index
                                            model.choose(send: false)
                                        }
                                }
                            } header: {
                                header(section)
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                .onChange(of: model.selection) { if let id = model.selectedRowID { proxy.scrollTo(id) } }
            }
        }
    }

    private func header(_ section: PickerSection) -> some View {
        HStack(spacing: 6) {
            Text(section.title)
                .font(Typography.label)
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
            Text("\(section.rows.count)")
                .font(Typography.label)
                .monospacedDigit()
                .foregroundStyle(Palette.textQuaternary)
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Palette.hud)
    }

    private func row(_ entry: PickerEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            EntryIcon(entry: entry, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HighlightText(text: entry.title, query: model.query, weight: .semibold, color: selected ? Palette.onInk : Palette.text, dim: selected ? Palette.onInk.opacity(0.75) : Palette.textSecondary)
                    .lineLimit(1)
                if !entry.subtitle.isEmpty {
                    Text(entry.subtitle)
                        .font(Typography.caption)
                        .foregroundStyle(selected ? Palette.onInk.opacity(0.7) : Palette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if selected {
                KeyHint("↩", emphasized: true)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 44)
        .background(selected ? Palette.ink : .clear, in: .rect(cornerRadius: Radius.control, style: .continuous))
    }
}

private struct RecentVariant: View {
    @Environment(PickerProtoModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                WalkthroughChip()
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            SearchRow(prompt: "Send to…")
                .padding(.horizontal, 16)
                .frame(height: 40)
            if model.showsStrip {
                stripView
            }
            scopes
            Rectangle().fill(Palette.hairline).frame(height: 1)
            list
            Rectangle().fill(Palette.hairline).frame(height: 1)
            HStack {
                FooterHints(items: [("←→↑↓", "Move"), ("⇥", "Filter"), ("↩", "Paste"), ("esc", "Clipboard only")])
                Spacer()
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
        }
    }

    private var stripView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Recent")
                .font(Typography.label)
                .tracking(0.9)
                .textCase(.uppercase)
                .foregroundStyle(Palette.textTertiary)
                .padding(.horizontal, 16)
            HStack(spacing: 6) {
                ForEach(Array(model.strip.enumerated()), id: \.element.id) { index, entry in
                    tile(entry, selected: model.inStrip && index == model.stripSelection)
                        .contentShape(.rect)
                        .onTapGesture {
                            model.inStrip = true
                            model.stripSelection = index
                            model.choose(send: false)
                        }
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.top, 4)
        .padding(.bottom, 10)
    }

    private func tile(_ entry: PickerEntry, selected: Bool) -> some View {
        VStack(spacing: 6) {
            EntryIcon(entry: entry, size: 36)
            Text(entry.shortTitle)
                .font(.system(size: 11, weight: selected ? .semibold : .medium))
                .foregroundStyle(selected ? Palette.text : Palette.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 6)
        }
        .frame(width: 88, height: 80)
        .background(selected ? Palette.selection : Palette.fill, in: .rect(cornerRadius: Radius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(selected ? Palette.ink : Palette.hairline, lineWidth: selected ? 1.5 : 1))
    }

    private var scopes: some View {
        HStack(spacing: 2) {
            ForEach(PickerProtoModel.Scope.allCases, id: \.self) { scope in
                let on = scope == model.scope
                Text(scope.rawValue)
                    .font(.system(size: 11.5, weight: on ? .semibold : .medium))
                    .foregroundStyle(on ? Palette.onInk : Palette.textSecondary)
                    .padding(.horizontal, 9)
                    .frame(height: 22)
                    .background(on ? Palette.ink : .clear, in: .rect(cornerRadius: Radius.control, style: .continuous))
                    .contentShape(.rect)
                    .onTapGesture { model.scope = scope }
            }
            Spacer()
            if model.showsStrip {
                Text("Everything else")
                    .font(Typography.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 34)
    }

    @ViewBuilder
    private var list: some View {
        let rows = model.flat
        if rows.isEmpty {
            Text("Nothing matches “\(model.query)”.")
                .font(Typography.callout)
                .foregroundStyle(Palette.textTertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: !(model.inStrip && model.showsStrip) && index == model.selection)
                                .id(entry.id)
                                .contentShape(.rect)
                                .onTapGesture {
                                    model.inStrip = false
                                    model.selection = index
                                    model.choose(send: false)
                                }
                        }
                    }
                    .padding(6)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity)
                .onChange(of: model.selection) { if let id = model.selectedRowID { proxy.scrollTo(id) } }
            }
        }
    }

    private func row(_ entry: PickerEntry, selected: Bool) -> some View {
        HStack(spacing: 10) {
            EntryIcon(entry: entry, size: 22)
            HighlightText(text: entry.title, query: model.query, weight: selected ? .semibold : .regular, color: selected ? Palette.onInk : Palette.text, dim: selected ? Palette.onInk.opacity(0.75) : (model.query.isEmpty ? Palette.text : Palette.textSecondary))
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(entry.subtitle)
                .font(Typography.caption)
                .foregroundStyle(selected ? Palette.onInk.opacity(0.7) : Palette.textTertiary)
                .lineLimit(1)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .background(selected ? Palette.ink : .clear, in: .rect(cornerRadius: Radius.control, style: .continuous))
    }
}
