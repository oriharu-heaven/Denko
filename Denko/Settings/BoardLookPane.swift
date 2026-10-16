import SwiftUI

/// 掲示板: how the LED board looks and moves — Denko's main settings.
struct BoardLookPane: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section {
                BoardPreview(settings: settings)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                HStack {
                    Text("試しに流す").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                    Button("ふつう") {
                        AppDelegate.shared.hub.post(.system, title: "テスト表示です", body: "電光掲示板は正常に動いています", force: .normal)
                    }
                    Button("緊急") {
                        AppDelegate.shared.hub.post(.system, title: "緊急表示のテストです", force: .urgent)
                    }
                    Button("今日の情報") { AppDelegate.shared.info.roll() }
                }
                .controlSize(.small)
            }

            Section {
                Picker("流れる速さ", selection: $settings.tickerSpeed) {
                    Text("ゆっくり").tag(20.0)
                    Text("ふつう").tag(30.0)
                    Text("はやい").tag(45.0)
                }
                if settings.showAdvanced {
                    Picker("1 件あたりの表示回数", selection: $settings.tickerRepeat) {
                        ForEach(1...3, id: \.self) { Text("\($0) 回").tag($0) }
                    }
                    Toggle("流す前に見出し（◆ 天気 ◆ など）を出す", isOn: $settings.showHeading)
                }
                Picker("メニューバー全体に流す", selection: Binding(
                    get: { !settings.fullBarUrgent ? 0 : (settings.fullBarAll ? 2 : 1) },
                    set: { settings.fullBarUrgent = $0 > 0; settings.fullBarAll = $0 == 2 })) {
                    Text("すべてのお知らせ").tag(2)
                    Text("緊急だけ").tag(1)
                    Text("流さない").tag(0)
                }
            } header: {
                Text("流し方")
            } footer: {
                Text("メニューバー全体に流れている間も、マウスを近づけると掲示板がよけて、下のメニューを操作できます。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("光の色") {
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
                LabeledContent("盤面の色") {
                    SwatchRow(
                        items: BoardBase.presets.map { ($0.rawValue, Color(nsColor: $0.color(customHex: "")), $0.label) },
                        selected: settings.boardBase.rawValue,
                        customColor: NSColor(hexString: settings.boardBaseCustom) ?? .black,
                        select: { settings.boardBase = BoardBase(rawValue: $0) ?? .black },
                        pickCustom: { color in
                            settings.boardBaseCustom = color.hexString
                            settings.boardBase = .custom
                        })
                }
            } header: {
                Text("色")
            } footer: {
                Text("光の色はパネルや設定の強調にも使います。盤面は文字が読みやすいよう、選んだ色を暗くして使います。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Picker("ドットの形", selection: $settings.dotShape) {
                    ForEach(DotShape.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                if settings.showAdvanced {
                Picker("ドットの大きさ", selection: $settings.dotSize) {
                    Text("小").tag(0.68)
                    Text("中").tag(0.87)
                    Text("大").tag(1.0)
                }
                .pickerStyle(.segmented)
                Picker("消えているドット", selection: $settings.unlitDots) {
                    Text("見せない").tag(0.0)
                    Text("うっすら").tag(0.07)
                    Text("はっきり").tag(0.16)
                }
                .pickerStyle(.segmented)
                }
            } header: {
                Text("ドット")
            }

            Section {
                Picker("緊急の速さ", selection: $settings.urgentSpeed) {
                    Text("ふつうと同じ").tag(1.0)
                    Text("1.5 倍").tag(1.5)
                    Text("2.5 倍").tag(2.5)
                    Text("4 倍").tag(4.0)
                }
                Toggle("「緊急のお知らせ」を点滅させる", isOn: $settings.urgentBlink)
            } header: {
                Text("緊急のお知らせ")
            }

            NoticeLevelsSection(settings: settings)

            Section {
                LabeledContent("いまの状態") {
                    Text(FocusChoice.current == .same ? "いつもどおり流しています"
                         : FocusChoice.current == .urgentOnly ? "集中モード：緊急だけ流しています" : "集中モード：流していません")
                        .foregroundStyle(.secondary)
                }
                Button("集中モードの設定を開く…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension")!)
                }
                Toggle("全画面のアプリ（発表・動画など）の間は緊急だけ流す", isOn: $settings.quietInFullScreen)
            } header: {
                Text("集中モード")
            } footer: {
                Text("会議の間だけ静かにしたいときは、パネル下か右クリックの「お知らせを止める」がいちばん手軽です。集中モードに Denko のフィルタを追加すると、集中モードに合わせて自動で切り替わります。")
                    .font(.caption).foregroundStyle(.secondary)
            }


        }
        .formStyle(.grouped)
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
                Button("おすすめの設定に戻す") { settings.noticeLevels = [:] }
            }
        } header: {
            Text("お知らせの種類ごとの流し方")
        } footer: {
            Text("「緊急」はメニューバー全体で目立たせて、「ふつう」は通常どおり流し、「流さない」は履歴にだけ残します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Still preview of the board with the current look.
private struct BoardPreview: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        let _ = settings.boardStyleKey
        Image(nsImage: render())
            .interpolation(.high)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: 440)
            .accessibilityLabel("掲示板のプレビュー")
    }

    private func render() -> NSImage {
        LEDRenderer.apply(dotSize: settings.dotSize, square: settings.dotShape == .square,
                          unlit: settings.unlitDots, base: settings.boardBaseColor)
        let color = settings.boardNSColor
        // The user's own weather when it's loaded, so the preview reads like their board.
        let text = AppDelegate.shared.info.weather.map {
            "◆ 天気 ◆ \(settings.weatherPlace) \(Int($0.temperature.rounded()))° \(WeatherCode.text($0.code))"
        } ?? "◆ 天気 ◆ \(settings.weatherPlace) 晴れ"
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
            .help("好きな色を選ぶ")
            .accessibilityLabel("好きな色を選ぶ")
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
