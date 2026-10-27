import SwiftUI

/// 掲示板: how the LED board looks and moves — Denko's main settings.
struct BoardLookPane: View {
    @ObservedObject var settings: AppSettings

    @State private var showLevels = false

    var body: some View {
        Form {
            Section {
                BoardPreview(settings: settings)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                LabeledContent(String(localized: "テスト")) {
                    HStack {
                        Button(String(localized: "ふつう")) {
                            AppDelegate.shared.hub.post(.system, title: String(localized: "テスト表示です"), force: .normal)
                        }
                        Button(String(localized: "緊急")) {
                            AppDelegate.shared.hub.post(.system, title: String(localized: "緊急表示のテストです"), force: .urgent)
                        }
                    }
                }
            }

            Section(String(localized: "流し方")) {
                Picker(String(localized: "速さ"), selection: $settings.tickerSpeed) {
                    Text(String(localized: "ゆっくり")).tag(30.0)
                    Text(String(localized: "ふつう")).tag(45.0)
                    Text(String(localized: "はやい")).tag(60.0)
                }
                .pickerStyle(.segmented)
                Picker(String(localized: "メニューバー全体"), selection: Binding(
                    get: { !settings.fullBarUrgent ? 0 : (settings.fullBarAll ? 2 : 1) },
                    set: { settings.fullBarUrgent = $0 > 0; settings.fullBarAll = $0 == 2 })) {
                    Text(String(localized: "すべて")).tag(2)
                    Text(String(localized: "緊急だけ")).tag(1)
                    Text(String(localized: "使わない")).tag(0)
                }
                .pickerStyle(.segmented)
                Picker(String(localized: "今日の情報"), selection: $settings.infoRollMinutes) {
                    Text(String(localized: "流さない")).tag(0)
                    Text(String(localized: "15分ごと")).tag(15)
                    Text(String(localized: "1時間ごと")).tag(60)
                }
                .pickerStyle(.segmented)
            }

            Section(String(localized: "見た目")) {
                LabeledContent(String(localized: "光の色")) {
                    SwatchRow(
                        items: AccentPreset.allCases.filter { $0 != .custom }.map { ($0.rawValue, Color(nsColor: $0.ledColor), $0.label) },
                        selected: settings.accent == .custom ? "custom" : settings.accent.rawValue,
                        customColor: NSColor(hexString: settings.boardCustomColor) ?? .orange,
                        select: { settings.accent = AccentPreset(rawValue: $0) ?? .station },
                        pickCustom: { color in
                            settings.boardCustomColor = color.hexString
                            settings.accent = .custom
                        })
                }
                Picker(String(localized: "ドットの形"), selection: $settings.dotShape) {
                    ForEach(DotShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section(String(localized: "お知らせ")) {
                LabeledContent(String(localized: "種類ごとの流し方")) {
                    Button(String(localized: "変更…")) { showLevels = true }
                }
                Picker(String(localized: "集中モード中"), selection: $settings.focusBehavior) {
                    ForEach(FocusBehavior.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if !FocusWatcher.isAuthorized && settings.focusBehavior != .same {
                    LabeledContent(String(localized: "集中モードとの連動")) {
                        Button(String(localized: "許可…")) { FocusWatcher.requestAuthorization { _ in } }
                    }
                }
                Toggle(String(localized: "全画面のアプリの間は緊急だけ"), isOn: $settings.quietInFullScreen)
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showLevels) {
            VStack(spacing: 0) {
                Form { NoticeLevelsSection(settings: settings) }.formStyle(.grouped)
                HStack {
                    Spacer()
                    Button(String(localized: "完了")) { showLevels = false }.keyboardShortcut(.defaultAction)
                }
                .padding(12)
            }
            .frame(width: 480, height: 520)
        }
    }
}

/// 緊急 / ふつう / 流さない for each kind of notice, grouped.
private struct NoticeLevelsSection: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Section {
            ForEach(NoticeKind.groups, id: \.self) { group in
                DisclosureGroup(group) {
                    ForEach(NoticeKind.allCases.filter { $0.group == group && $0 != .other && $0 != .awakeEnded }) { kind in
                        Picker(kind.label, selection: Binding(
                            get: { settings.level(for: kind) },
                            set: { settings.noticeLevels[kind.rawValue] = $0.rawValue })) {
                            ForEach(NoticeLevel.allCases) { Text($0.label).tag($0) }
                        }
                    }
                }
            }
            if !settings.noticeLevels.isEmpty {
                Button(String(localized: "おすすめの設定に戻す")) { settings.noticeLevels = [:] }
            }
        } header: {
            Text(String(localized: "お知らせの種類ごとの流し方"))
        }
    }
}

/// Still preview of the board with the current look.
struct BoardPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let _ = settings.boardStyleKey
        Image(nsImage: render())
            .interpolation(.high)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 440)
            .accessibilityLabel(String(localized: "掲示板のプレビュー"))
    }

    private func render() -> NSImage {
        LEDRenderer.apply(dotSize: settings.dotSize, square: settings.dotShape == .square,
                          unlit: settings.unlitDots, base: settings.boardBaseColor)
        let color = settings.boardNSColor
        // The user's own weather when it's loaded, so the preview reads like their board.
        let text = AppDelegate.shared.info.weather.map {
            String(localized: "◆ 天気 ◆ \(settings.weatherPlace) \(Int($0.temperature.rounded()))° \(WeatherCode.text($0.code))")
        } ?? String(localized: "◆ 天気 ◆ \(settings.weatherPlace) 晴れ")
        let width = CGFloat(LEDRenderer.mask(for: text).columns + 12) * LEDRenderer.pitch
        let board = LEDRenderer.board(width: width, accent: color)
        let strip = LEDRenderer.staticStrip(for: text, accent: color, boardWidth: width)
        let size = NSSize(width: width, height: LEDRenderer.boardHeight)
        return NSImage(size: size, flipped: false) { rect in
            board.draw(in: rect)
            if let strip, let ctx = NSGraphicsContext.current?.cgContext { ctx.draw(strip, in: rect) }
            return true
        }
    }
}

/// Toolbar icon for 掲示板: a small dot-matrix board showing a "D".
enum BoardIcon {
    static func image(size: CGFloat = 20) -> NSImage {
        // 7 × 5 dot pattern ("D"), drawn inside a rounded board outline.
        let pattern = [
            "1111000",
            "1000100",
            "1000100",
            "1000100",
            "1111000",
        ]
        let img = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
            let board = rect.insetBy(dx: size * 0.04, dy: size * 0.2)
            let outline = NSBezierPath(roundedRect: board, xRadius: size * 0.16, yRadius: size * 0.16)
            outline.lineWidth = size * 0.07
            NSColor.black.setStroke()
            outline.stroke()
            let cols = 7, rows = 5
            let inner = board.insetBy(dx: size * 0.15, dy: size * 0.13)
            let pitch = min(inner.width / CGFloat(cols), inner.height / CGFloat(rows))
            let ox = inner.midX - pitch * CGFloat(cols) / 2, oy = inner.midY - pitch * CGFloat(rows) / 2
            NSColor.black.setFill()
            for (r, line) in pattern.enumerated() {
                for (c, ch) in line.enumerated() {
                    let d = pitch * (ch == "1" ? 0.82 : 0.32)
                    let x = ox + CGFloat(c) * pitch + (pitch - d) / 2
                    let y = oy + CGFloat(r) * pitch + (pitch - d) / 2
                    NSBezierPath(ovalIn: NSRect(x: x, y: y, width: d, height: d)).fill()
                }
            }
            return true
        }
        img.isTemplate = true
        return img
    }
}

/// A row of color dots, with a rainbow dot at the end that opens the system color panel.
struct SwatchRow: View {
    let items: [(id: String, color: Color, label: String)]
    let selected: String
    let customColor: NSColor
    let select: (String) -> Void
    let pickCustom: (NSColor) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(items, id: \.id) { item in
                Button { select(item.id) } label: {
                    Circle().fill(item.color).frame(width: 18, height: 18)
                        .overlay(Circle().stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
                        .overlay {
                            if selected == item.id { Circle().strokeBorder(.primary, lineWidth: 2).padding(-4) }
                        }
                }
                .buttonStyle(.plain)
                .help(item.label)
                .accessibilityLabel(item.label)
            }
            Button {
                ColorPanelBridge.shared.open(initial: customColor, onChange: pickCustom)
            } label: {
                Circle()
                    .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red], center: .center))
                    .frame(width: 18, height: 18)
                    .overlay {
                        if selected == "custom" {
                            Circle().fill(Color(nsColor: customColor)).padding(4)
                            Circle().strokeBorder(.primary, lineWidth: 2).padding(-4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(String(localized: "好きな色を選ぶ"))
            .accessibilityLabel(String(localized: "好きな色を選ぶ"))
        }
    }
}

/// Opens the shared NSColorPanel and reports picks through a closure.
@MainActor
final class ColorPanelBridge: NSObject {
    static let shared = ColorPanelBridge()
    private var onChange: ((NSColor) -> Void)?

    func open(initial: NSColor, onChange: @escaping (NSColor) -> Void) {
        self.onChange = onChange
        let panel = NSColorPanel.shared
        panel.showsAlpha = false
        panel.setTarget(self)
        panel.setAction(#selector(changed(_:)))
        panel.color = initial
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func changed(_ sender: NSColorPanel) { onChange?(sender.color) }
}
