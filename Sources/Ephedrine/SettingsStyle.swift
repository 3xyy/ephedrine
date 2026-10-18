import SwiftUI

// The settings window's look, design B (.superpowers/specs/2026-10-18-settings-b-mockup.html):
// a top bar of icon tabs, a warm status banner per pane, then cards of rows.
// No @State anywhere (see SettingsUI): these views take everything they show.

/// The window's colors. Each is a dynamic NSColor, resolved on every draw, so
/// it follows the system appearance. Orange text and glyphs use `clay`, which
/// is darker in light mode so it stays readable on white; fills use `orange`,
/// except buttons with white text, which use the darker `clayFill`.
enum SettingsColors {
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    private static func dynamic(_ light: NSColor, _ dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { a in a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light })
    }
    private static let black = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
    private static let white = NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

    static let window = dynamic(rgb(0xF6F5F2), rgb(0x232325))
    static let bar = dynamic(rgb(0xEEEDE9), rgb(0x1C1C1E))
    static let card = dynamic(rgb(0xFFFFFF), rgb(0x2C2C2E))
    static let edge = dynamic(black.withAlphaComponent(0.1), white.withAlphaComponent(0.1))       // card and field borders
    static let separator = dynamic(black.withAlphaComponent(0.08), white.withAlphaComponent(0.09))
    static let fill = dynamic(black.withAlphaComponent(0.05), white.withAlphaComponent(0.07))     // plain buttons
    static let field = dynamic(rgb(0xF2F1EE), rgb(0x1F1F21))
    static let text = dynamic(rgb(0x1D1D1F), rgb(0xF2F2F4))
    static let secondaryText = dynamic(rgb(0x3C3C43, 0.8), rgb(0xEBEBF5, 0.72))
    static let tertiaryText = dynamic(rgb(0x3C3C43, 0.72), rgb(0xEBEBF5, 0.58))   // row subtitles: 4.7:1 on a white card, 5.0:1 on a dark one
    static let clay = dynamic(rgb(0xC4623F), rgb(0xD97757))                        // orange text and glyphs
    static let claySoft = dynamic(rgb(0xD97757, 0.16), rgb(0xD97757, 0.22))       // the selected tab
    static let clayOnSoft = dynamic(rgb(0x9E472A), rgb(0xE08766))                  // the selected tab's label: 4.5:1 on claySoft
    static let orange = Color(nsColor: claudeOrange)                               // orange fills
    static let clayFill = dynamic(rgb(0xA9512F), rgb(0xB85A38))                    // filled buttons: white text at 5.4:1 / 4.6:1
    static let warn = dynamic(rgb(0xA65200), rgb(0xFF9F0A))
    static let ok = dynamic(rgb(0x1E7E34), rgb(0x30D158))
    static let focusRing = Color(nsColor: .keyboardFocusIndicatorColor)
    static let toggleOff = dynamic(black.withAlphaComponent(0.16), white.withAlphaComponent(0.2))

    // The banner is warm and dark in both appearances; its text is fixed.
    static let banner = dynamic(rgb(0x2A2522), rgb(0x3A2D26))
    static let bannerText = Color(nsColor: rgb(0xF6EFE9))
    static let bannerSecondaryText = Color(nsColor: rgb(0xF6EFE9, 0.72))
    static let bannerTile = Color(nsColor: rgb(0xD97757, 0.28))
    static let bannerGlyph = Color(nsColor: rgb(0xF0A487))
}

/// The switch from the mock: a 32×19 pill, orange when on, with a white knob.
/// Only the pill shows; VoiceOver gets the row's title as its label (rows hide
/// the control's own label, and a hidden label may not be announced).
struct ClayToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        ClayToggleBody(isOn: configuration.$isOn, label: configuration.label)
    }
}

private struct SettingsRowTitleKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The title of the row a control sits in; the switch announces it.
    fileprivate var settingsRowTitle: String? {
        get { self[SettingsRowTitleKey.self] }
        set { self[SettingsRowTitleKey.self] = newValue }
    }
}

private struct ClayToggleBody<Label: View>: View {
    @Binding var isOn: Bool
    let label: Label
    @Environment(\.settingsRowTitle) private var rowTitle

    var body: some View {
        ClaySwitch(isOn: $isOn)
            .accessibilityRepresentation {
                if let rowTitle { Toggle(isOn: $isOn) { Text(rowTitle) }.accessibilityLabel(rowTitle) }
                else { Toggle(isOn: $isOn) { label } }
            }
    }
}

private struct ClaySwitch: View {
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled
    @FocusState private var focused: Bool   // a property wrapper, not a macro: fine under the Command Line Tools

    var body: some View {
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? SettingsColors.orange : SettingsColors.toggleOff)
            Circle().fill(Color.white)
                .frame(width: 15, height: 15)
                .shadow(color: .black.opacity(0.3), radius: 1, y: 0.5)
                .padding(2)
        }
        .frame(width: 32, height: 19)
        .opacity(isEnabled ? 1 : 0.45)
        .contentShape(Capsule())
        .onTapGesture { if isEnabled { isOn.toggle() } }
        .animation(.easeOut(duration: 0.15), value: isOn)
        // Full keyboard access: Tab reaches the switch, Space flips it, and a ring shows where it is.
        // `.activate`: focus comes from the keyboard only, so a click leaves no ring behind.
        .focusable(isEnabled, interactions: .activate)
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(.space) {
            guard isEnabled else { return .ignored }
            isOn.toggle()
            return .handled
        }
        .padding(2)
        .overlay(Capsule().strokeBorder(SettingsColors.focusRing, lineWidth: 2).opacity(focused ? 1 : 0))
    }
}

/// Buttons in the window: `.banner` is the banner's orange action, `.primary`
/// an orange button in a card (Save), `.secondary` a plain one.
struct SettingsButtonStyle: ButtonStyle {
    enum Kind { case banner, primary, secondary }
    let kind: Kind
    init(_ kind: Kind = .secondary) { self.kind = kind }
    func makeBody(configuration: Configuration) -> some View {
        SettingsButtonBody(kind: kind, label: configuration.label, pressed: configuration.isPressed)
    }
}

private struct SettingsButtonBody<Label: View>: View {
    let kind: SettingsButtonStyle.Kind
    let label: Label
    let pressed: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let banner = kind == .banner
        label
            .font(.system(size: 12.5, weight: kind == .secondary ? .regular : .semibold))
            .lineLimit(1)
            .foregroundStyle(kind == .secondary ? SettingsColors.text : Color.white)
            .padding(.horizontal, banner ? 14 : kind == .primary ? 12 : 10)
            .frame(height: banner ? 30 : 26)
            .background(RoundedRectangle(cornerRadius: banner ? 8 : 6, style: .continuous)
                .fill(kind == .secondary ? SettingsColors.fill : SettingsColors.clayFill))
            .overlay(RoundedRectangle(cornerRadius: banner ? 8 : 6, style: .continuous)
                .strokeBorder(Color.white.opacity(banner ? 0.35 : 0), lineWidth: 1))   // edge reaches 3:1 on the dark banner
            .overlay(RoundedRectangle(cornerRadius: banner ? 8 : 6, style: .continuous)
                .fill(Color.black.opacity(pressed ? 0.15 : 0)))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.45)
            .fixedSize()
    }
}

/// The warm status card at the top of a pane: the pane's symbol on an orange
/// tile, a headline, a sentence, and the pane's main action when it has one.
struct SettingsBanner: View {
    let symbol: String
    let headline: String
    let sentence: String?
    let action: (title: String, handler: () -> Void)?

    init(symbol: String, headline: String, sentence: String? = nil, action: (title: String, handler: () -> Void)? = nil) {
        self.symbol = symbol; self.headline = headline; self.sentence = sentence; self.action = action
    }

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 24))
                .foregroundStyle(SettingsColors.bannerGlyph)
                .frame(width: 48, height: 48)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsColors.bannerTile))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(SettingsColors.bannerText)
                if let sentence, !sentence.isEmpty {
                    Text(sentence)
                        .font(.system(size: 12.5))
                        .lineSpacing(2)
                        .foregroundStyle(SettingsColors.bannerSecondaryText)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let action {
                Button(action.title, action: action.handler).buttonStyle(SettingsButtonStyle(.banner))
            }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(SettingsColors.banner))
    }
}

/// A small status on the right of a card's header: a dot and a word.
struct SettingsBadge {
    enum Tone { case ok, warn, dim }
    let text: String
    let tone: Tone
    init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }
    fileprivate var color: Color {
        switch tone {
        case .ok: return SettingsColors.ok
        case .warn: return SettingsColors.warn
        case .dim: return SettingsColors.tertiaryText
        }
    }
}

/// A white (dark: graphite) card with a header (orange symbol, title) over its rows.
struct SettingsCard<Content: View>: View {
    let symbol: String
    let title: String
    let badge: SettingsBadge?
    let content: Content

    init(symbol: String, title: String, badge: SettingsBadge? = nil, @ViewBuilder content: () -> Content) {
        self.symbol = symbol; self.title = title; self.badge = badge; self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(SettingsColors.clay)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(SettingsColors.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let badge {
                    HStack(spacing: 5) {
                        Circle().fill(badge.color).frame(width: 6, height: 6)
                        Text(badge.text).font(.system(size: 11.5))
                    }
                    .foregroundStyle(badge.color)
                    .accessibilityElement(children: .combine)
                }
            }
            .padding(.top, 6)
            .padding(.bottom, 8)
            content
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(SettingsColors.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(SettingsColors.edge, lineWidth: 0.5))
    }
}

/// The hairline between rows (and between a card's header and its first row).
struct SettingsHairline: View {
    var body: some View { SettingsColors.separator.frame(height: 0.5).accessibilityHidden(true) }
}

/// One line of a card: a title, an optional subtitle, and a control on the
/// right at its own size (give a text field a width). A wider control (most
/// pickers) shares the title's line and the subtitle runs under both; one too
/// wide even for that goes under the text.
struct SettingsRow<Control: View>: View {
    let title: String
    let subtitle: String?
    let warning: Bool   // the subtitle in the warning color
    let control: Control

    init(_ title: String, subtitle: String? = nil, warning: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title; self.subtitle = subtitle; self.warning = warning; self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHairline()
            SettingsRowLayout(hasSubtitle: hasSubtitle) {
                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsColors.text)
                if let subtitle, hasSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(warning ? SettingsColors.warn : SettingsColors.tertiaryText)
                }
                styledControl
            }
            .padding(.vertical, 8)
            .frame(minHeight: hasSubtitle ? 44 : 36)
        }
    }

    private var hasSubtitle: Bool { !(subtitle ?? "").isEmpty }

    /// Labels are hidden, so give each toggle and picker its own label text:
    /// VoiceOver still reads it.
    private var styledControl: some View {
        control
            .environment(\.settingsRowTitle, title)
            .labelsHidden()
            .fixedSize()
    }
}

/// SettingsRow's layout. Side by side while the text keeps `minTextWidth`;
/// else the control on the title's line with the subtitle under both; else
/// the control under the text. Each part is measured once per pass (nested
/// ViewThatFits alternatives made a layout pass take minutes).
private struct SettingsRowLayout: Layout {
    let hasSubtitle: Bool
    private let minTextWidth: CGFloat = 260
    private let gap: CGFloat = 12

    private struct Plan {
        var size = CGSize.zero
        var title = CGRect.zero, subtitle = CGRect.zero, control = CGRect.zero
    }

    /// Subviews in order: title, the subtitle when there is one, the control when there is one.
    private func plan(width proposed: CGFloat?, _ s: Subviews) -> Plan {
        guard let title = s.first else { return Plan() }
        let subtitle = hasSubtitle && s.count > 1 ? s[1] : nil
        let control = s.count > (hasSubtitle ? 2 : 1) ? s[s.count - 1] : nil
        let c = control?.sizeThatFits(.unspecified) ?? .zero
        let cGap = control == nil ? 0 : gap
        let titleIdeal = title.sizeThatFits(.unspecified).width
        var w = titleIdeal + cGap + c.width
        if let p = proposed, p.isFinite { w = max(p, 0) }
        func height(_ v: LayoutSubview?, _ width: CGFloat) -> CGFloat {
            v.map { $0.sizeThatFits(ProposedViewSize(width: max(width, 0), height: nil)).height } ?? 0
        }
        let subGap: CGFloat = subtitle == nil ? 0 : 2
        var out = Plan()
        if control == nil || w - c.width - cGap >= minTextWidth {
            let textW = w - c.width - cGap
            let th = height(title, textW), sh = height(subtitle, textW)
            let textH = th + subGap + sh, h = max(textH, c.height)
            out.title = CGRect(x: 0, y: (h - textH) / 2, width: textW, height: th)
            out.subtitle = CGRect(x: 0, y: out.title.maxY + subGap, width: textW, height: sh)
            out.control = CGRect(x: w - c.width, y: (h - c.height) / 2, width: c.width, height: c.height)
            out.size = CGSize(width: w, height: h)
        } else if titleIdeal + cGap + c.width <= w {
            let titleW = w - c.width - cGap
            let th = height(title, titleW), line = max(th, c.height), sh = height(subtitle, w)
            out.title = CGRect(x: 0, y: (line - th) / 2, width: titleW, height: th)
            out.control = CGRect(x: w - c.width, y: (line - c.height) / 2, width: c.width, height: c.height)
            out.subtitle = CGRect(x: 0, y: line + subGap, width: w, height: sh)
            out.size = CGSize(width: w, height: line + subGap + sh)
        } else {
            let th = height(title, w), sh = height(subtitle, w)
            out.title = CGRect(x: 0, y: 0, width: w, height: th)
            out.subtitle = CGRect(x: 0, y: th + subGap, width: w, height: sh)
            out.control = CGRect(x: 0, y: out.subtitle.maxY + 6, width: c.width, height: c.height)
            out.size = CGSize(width: w, height: out.control.maxY)
        }
        return out
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        plan(width: proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let p = plan(width: bounds.width, subviews)
        func put(_ v: LayoutSubview, _ r: CGRect) {
            v.place(at: CGPoint(x: bounds.minX + r.minX, y: bounds.minY + r.minY), proposal: ProposedViewSize(r.size))
        }
        guard let title = subviews.first else { return }
        put(title, p.title)
        if hasSubtitle, subviews.count > 1 { put(subviews[1], p.subtitle) }
        if subviews.count > (hasSubtitle ? 2 : 1) { put(subviews[subviews.count - 1], p.control) }
    }
}

extension SettingsRow where Control == EmptyView {
    /// A row that only says something (a status line).
    init(_ title: String, subtitle: String? = nil, warning: Bool = false) {
        self.init(title, subtitle: subtitle, warning: warning) { EmptyView() }
    }
}

/// A short explanation inside a card, after its rows.
struct SettingsNote: View {
    let text: String
    let warning: Bool
    init(_ text: String, warning: Bool = false) { self.text = text; self.warning = warning }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHairline()
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(warning ? SettingsColors.warn : SettingsColors.tertiaryText)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
    }
}

/// A labelled text or secure field inside a card, the label above it, the
/// field the card's full width (give it `.settingsField()`).
struct SettingsFieldRow<Field: View>: View {
    let label: String
    let field: Field
    init(_ label: String, @ViewBuilder field: () -> Field) { self.label = label; self.field = field() }

    var body: some View {
        VStack(spacing: 0) {
            SettingsHairline()
            VStack(alignment: .leading, spacing: 4) {
                Text(label).font(.system(size: 11.5)).foregroundStyle(SettingsColors.secondaryText)
                field.frame(maxWidth: .infinity)
            }
            .padding(.vertical, 8)
        }
    }
}

/// The line under fields: a status on the left, the buttons on the right.
struct SettingsActionBar<Buttons: View>: View {
    let note: String?
    let warning: Bool
    let buttons: Buttons
    init(note: String? = nil, warning: Bool = false, @ViewBuilder buttons: () -> Buttons) {
        self.note = note; self.warning = warning; self.buttons = buttons()
    }

    var body: some View {
        HStack(spacing: 8) {
            if let note {
                Text(note).font(.system(size: 11.5))
                    .foregroundStyle(warning ? SettingsColors.warn : SettingsColors.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            buttons
        }
        .padding(.bottom, 8)
    }
}

/// Two columns of cards, each stacked from the top. A pane with one card puts
/// it straight in the page instead, so it spans the width.
struct SettingsColumns<Left: View, Right: View>: View {
    let left: Left
    let right: Right

    init(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) {
        self.left = left(); self.right = right()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) { left }.fixedSize(horizontal: false, vertical: true).frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
            VStack(spacing: 14) { right }.fixedSize(horizontal: false, vertical: true).frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
        }
    }
}

extension View {
    /// A text or secure field in the mock's look: 26 pt tall, corner radius 6.
    func settingsField() -> some View {
        self
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(SettingsColors.field))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(SettingsColors.edge, lineWidth: 0.5))
    }
}

/// The top of the window, under the traffic lights: the pane's title, then
/// one equal icon tab per pane. A pane in `attention` gets an orange dot.
/// ⌘1 to ⌘7 pick the tabs.
struct SettingsTabBar: View {
    @ObservedObject var ui: SettingsUI
    let attention: Set<SettingsPane>
    var titleHeight: CGFloat = 28   // the title bar's, so the title lines up with the traffic lights

    var body: some View {
        let current = ui.pane ?? .now
        VStack(spacing: 0) {
            Text(current.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SettingsColors.secondaryText)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: titleHeight)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 4) {
                ForEach(Array(SettingsPane.allCases.enumerated()), id: \.element) { i, p in
                    tab(p, index: i, selected: p == current)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 2)
            .padding(.bottom, 8)
        }
        .background(SettingsColors.bar)
        .overlay(alignment: .bottom) { SettingsHairline() }
    }

    private func tab(_ p: SettingsPane, index: Int, selected: Bool) -> some View {
        let flagged = attention.contains(p)
        return Button { ui.pane = p } label: {
            VStack(spacing: 3) {
                Image(systemName: p.symbol)
                    .font(.system(size: 20))
                    .frame(height: 24)
                    .overlay(alignment: .topTrailing) {
                        if flagged {
                            Circle().fill(SettingsColors.warn).frame(width: 7, height: 7).offset(x: 6, y: -1)
                        }
                    }
                Text(p.title)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(selected ? SettingsColors.clayOnSoft : SettingsColors.secondaryText)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? SettingsColors.claySoft : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
        .accessibilityLabel(p.title + (flagged ? ", needs attention" : ""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
