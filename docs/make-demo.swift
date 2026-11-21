// Draws the README demo (docs/demo.gif): a wrong-layout word fixed on Space in a chat and in an email, a selected
// sentence converted with the right ⌥ key, and an end card. Run from the repo root: swift docs/make-demo.swift
import AppKit
import ImageIO

// MARK: - What is typed

// Every wrong/right pair below was printed by the app's own code (Converter.retype for the words fixed on Space,
// Converter.convert for the selection) with the ABC and Ukrainian - PC layouts; none is worked out by hand.
let chatWrong = "руддщ"
let chatRight = "hello"
let chatRest = "Alex, 3 pm works for me"
let mailWrong = "Lj,hbq"
let mailRight = "Добрий"
let mailRest = "день, надсилаю звіт."
// The keys of "Зустріч завтра о 10" pressed on ABC (from Converter.convert); no punctuation, whose keys differ.
let notesWrong = "Pecnhsx pfdnhf j 10"
let notesRight = "Зустріч завтра о 10"

// MARK: - Canvas, colours, fonts

let canvas = NSSize(width: 760, height: 440)
/// Pixels per point: the GIF is 1520 pixels wide, sharp at 760 in a README.
let pixelScale: CGFloat = 2
let tickSeconds = 0.02
let outputPath = "docs/demo.gif"
let iconPath = "docs/icon.png"

func hex(_ value: Int, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: alpha)
}

let desktopColor = hex(0xE8EEF6)
let menuBarColor = hex(0xF7F9FC)
let lineColor = hex(0xD3D9E2)
let windowColor = NSColor.white
let titleBarColor = hex(0xF1F3F6)
let inkColor = hex(0x1B2330)
let mutedColor = hex(0x7A8494)
let blue = hex(0x378ADD)
let paleBlue = hex(0xD7E8FA)
let selectionColor = hex(0xB9D8FF)
let wrongColor = hex(0xFFDF94)
let wrongInk = hex(0x8A5200)
let fixedColor = hex(0xBDEBC9)
let fixedPaleColor = hex(0xE2F6E8)
let badgeColor = hex(0x2A2A2E)
let trafficLights = [hex(0xFF5F57), hex(0xFEBC2E), hex(0x28C840)]

let windowFrame = NSRect(x: 70, y: 50, width: 620, height: 318)
let titleBarHeight: CGFloat = 38
let menuBarHeight: CGFloat = 32
let captionBaseline: CGFloat = 412
let typedFont = NSFont.systemFont(ofSize: 20)
let notesFont = NSFont.systemFont(ofSize: 23)

// MARK: - The timeline

enum Scene { case chat, mail, notes, end }
enum Mark { case plain, wrong, fixed, selected }

struct Run: Equatable {
    var text: String
    var mark: Mark
}

/// What the script sets; the badge, the glow and the blinking cursor follow from the times in it.
struct Step {
    var tick = 0
    var scene = Scene.chat
    var sceneStart = 0
    var runs: [Run] = []
    var hasCaret = true
    var caretReset = 0
    var indicator = ""
    var fixTick: Int?
    var badge = ""
    /// The text left of the cursor when the fix landed: the badge stays under that spot.
    var badgeAnchor = ""
    var keyDown = false
}

/// One picture. Two ticks with the same state are one GIF frame with a longer delay.
struct FrameState: Equatable {
    var scene: Scene
    var runs: [Run]
    var caretOn: Bool
    var indicator: String
    var indicatorGlow: Int
    var fixedLevel: Int
    var badge: String
    var badgeAnchor: String
    var badgeLevel: Int
    var keyDown: Bool
    var endLevel: Int
}

func ticks(_ seconds: Double) -> Int { Int((seconds / tickSeconds).rounded()) }

let blinkTicks = ticks(0.5)
let badgeVisibleTicks = ticks(0.8)
let badgeFadeStepTicks = ticks(0.08)
let glowTicks = ticks(0.5)
let glowPaleTicks = ticks(0.2)
let fixedTicks = ticks(0.2)
let fixedPaleTicks = ticks(0.16)
let endFadeStepTicks = ticks(0.08)
/// A person's typing is uneven: these are added to the delay, key after key.
let typingJitter = [0.0, 0.02, -0.02, 0.04, 0.0, -0.02]

var steps: [Step] = []
var current = Step()
var now = 0

func commit() {
    current.tick = now
    steps.append(current)
}

func wait(_ seconds: Double) { now += ticks(seconds) }

func startScene(_ scene: Scene, indicator: String, runs: [Run] = []) {
    current = Step()
    current.scene = scene
    current.sceneStart = now
    current.caretReset = now
    current.indicator = indicator
    current.runs = runs
    commit()
}

func type(_ text: String, secondsPerKey: Double) {
    for (index, character) in text.enumerated() {
        if current.runs.last?.mark == .plain {
            current.runs[current.runs.count - 1].text.append(character)
        } else {
            current.runs.append(Run(text: String(character), mark: .plain))
        }
        current.caretReset = now
        commit()
        wait(secondsPerKey + typingJitter[index % typingJitter.count])
    }
}

/// Space after a word typed on the wrong layout: the word is marked, then retyped, and the layout switches.
func fixOnSpace(wrong: String, right: String, badge: String, indicator: String) {
    current.runs = [Run(text: wrong, mark: .wrong)]
    current.caretReset = now
    commit()
    wait(0.3)
    current.runs = [Run(text: right, mark: .fixed), Run(text: " ", mark: .plain)]
    current.indicator = indicator
    current.fixTick = now
    current.badge = badge
    current.badgeAnchor = right + " "
    current.caretReset = now
    commit()
    wait(0.44)
}

func typeAndFix(scene: Scene, from: String, to: String, wrong: String, right: String, rest: String, badge: String) {
    startScene(scene, indicator: from)
    wait(0.6)
    type(wrong, secondsPerKey: 0.14)
    wait(0.24)
    fixOnSpace(wrong: wrong, right: right, badge: badge, indicator: to)
    type(rest, secondsPerKey: 0.07)
    wait(1.2)
}

func selectAndTap() {
    startScene(.notes, indicator: "ABC", runs: [Run(text: notesWrong, mark: .plain)])
    wait(0.8)
    current.hasCaret = false
    let sweepSteps = 6
    for step in 1...sweepSteps {
        let count = notesWrong.count * step / sweepSteps
        current.runs = [Run(text: String(notesWrong.prefix(count)), mark: .selected),
                        Run(text: String(notesWrong.dropFirst(count)), mark: .plain)]
        commit()
        wait(0.06)
    }
    wait(0.5)
    current.keyDown = true
    commit()
    wait(0.34)
    current.keyDown = false
    current.runs = [Run(text: notesRight, mark: .selected)]
    current.indicator = "УК"
    current.fixTick = now
    current.badge = "УК"
    current.badgeAnchor = ""
    commit()
    wait(2.2)
}

typeAndFix(scene: .chat, from: "УК", to: "ABC", wrong: chatWrong, right: chatRight, rest: chatRest, badge: "A")
typeAndFix(scene: .mail, from: "ABC", to: "УК", wrong: mailWrong, right: mailRight, rest: mailRest, badge: "УК")
selectAndTap()
startScene(.end, indicator: "")
wait(3.2)
let totalTicks = now

func state(of step: Step, at tick: Int) -> FrameState {
    let sinceFix = step.fixTick.map { tick - $0 }
    var badgeLevel = 0
    var glow = 0
    var fixedLevel = 0
    if let sinceFix {
        let fadeStep = (sinceFix - badgeVisibleTicks) / badgeFadeStepTicks
        badgeLevel = sinceFix < badgeVisibleTicks ? 3 : max(0, 2 - fadeStep)
        glow = sinceFix < glowTicks ? 2 : (sinceFix < glowTicks + glowPaleTicks ? 1 : 0)
        fixedLevel = sinceFix < fixedTicks ? 2 : (sinceFix < fixedTicks + fixedPaleTicks ? 1 : 0)
    }
    let caretOn = step.hasCaret && ((tick - step.caretReset) / blinkTicks) % 2 == 0
    let endLevel = step.scene == .end ? min(3, (tick - step.sceneStart) / endFadeStepTicks) : 0
    return FrameState(scene: step.scene, runs: step.runs, caretOn: caretOn, indicator: step.indicator,
                      indicatorGlow: glow, fixedLevel: fixedLevel, badge: badgeLevel > 0 ? step.badge : "",
                      badgeAnchor: badgeLevel > 0 ? step.badgeAnchor : "", badgeLevel: badgeLevel,
                      keyDown: step.keyDown, endLevel: endLevel)
}

var frames: [(state: FrameState, ticks: Int)] = []
var stepIndex = 0
for tick in 0..<totalTicks {
    while stepIndex + 1 < steps.count && steps[stepIndex + 1].tick <= tick { stepIndex += 1 }
    let frameState = state(of: steps[stepIndex], at: tick)
    if let last = frames.last, last.state == frameState {
        frames[frames.count - 1].ticks += 1
    } else {
        frames.append((frameState, 1))
    }
}

// MARK: - Drawing

func fill(_ rect: NSRect, _ color: NSColor, radius: CGFloat = 0) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
}

func stroke(_ rect: NSRect, _ color: NSColor, radius: CGFloat, width: CGFloat) {
    color.setStroke()
    let path = NSBezierPath(roundedRect: rect.insetBy(dx: width / 2, dy: width / 2), xRadius: radius, yRadius: radius)
    path.lineWidth = width
    path.stroke()
}

func line(y: CGFloat, from x1: CGFloat, to x2: CGFloat) {
    fill(NSRect(x: x1, y: y, width: x2 - x1, height: 1), lineColor)
}

func width(of text: String, _ font: NSFont) -> CGFloat {
    NSAttributedString(string: text, attributes: [.font: font]).size().width
}

enum Align { case left, center, right }

/// Text on a baseline (the context is flipped: y grows downwards).
func draw(_ text: String, x: CGFloat, baseline: CGFloat, font: NSFont, color: NSColor, align: Align = .left) {
    let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
    let textWidth = string.size().width
    let left = align == .left ? x : (align == .center ? x - textWidth / 2 : x - textWidth)
    string.draw(at: NSPoint(x: left, y: baseline - font.ascender))
}

func drawMenuBar(app: String, state: FrameState) {
    fill(NSRect(x: 0, y: 0, width: canvas.width, height: menuBarHeight), menuBarColor)
    line(y: menuBarHeight, from: 0, to: canvas.width)
    let baseline: CGFloat = 21
    draw(app, x: 18, baseline: baseline, font: .systemFont(ofSize: 14, weight: .bold), color: inkColor)
    let menus = "File     Edit     View"
    draw(menus, x: 18 + width(of: app, .systemFont(ofSize: 14, weight: .bold)) + 22, baseline: baseline,
         font: .systemFont(ofSize: 14), color: inkColor)
    draw("9:41", x: canvas.width - 18, baseline: baseline, font: .systemFont(ofSize: 14, weight: .medium),
         color: inkColor, align: .right)

    // The layout indicator, as macOS shows it: a small box with the layout's letters.
    let font = NSFont.systemFont(ofSize: 12.5, weight: .bold)
    let boxWidth = width(of: state.indicator, font) + 14
    let box = NSRect(x: canvas.width - 68 - boxWidth, y: 6, width: boxWidth, height: 20)
    if state.indicatorGlow == 2 {
        fill(box.insetBy(dx: -4, dy: -4), paleBlue, radius: 8)
        fill(box, blue, radius: 5)
    } else {
        if state.indicatorGlow == 1 { fill(box, paleBlue, radius: 5) }
        stroke(box, inkColor, radius: 5, width: 1.5)
    }
    draw(state.indicator, x: box.midX, baseline: 20.5, font: font,
         color: state.indicatorGlow == 2 ? .white : inkColor, align: .center)
}

func drawWindow(title: String) {
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
    shadow.shadowBlurRadius = 14
    shadow.shadowOffset = NSSize(width: 0, height: -5)
    shadow.set()
    fill(windowFrame, windowColor, radius: 12)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: windowFrame, xRadius: 12, yRadius: 12).addClip()
    fill(NSRect(x: windowFrame.minX, y: windowFrame.minY, width: windowFrame.width, height: titleBarHeight), titleBarColor)
    NSGraphicsContext.restoreGraphicsState()
    line(y: windowFrame.minY + titleBarHeight, from: windowFrame.minX, to: windowFrame.maxX)
    for (index, color) in trafficLights.enumerated() {
        fill(NSRect(x: windowFrame.minX + 16 + CGFloat(index) * 20, y: windowFrame.minY + 13, width: 12, height: 12),
             color, radius: 6)
    }
    draw(title, x: windowFrame.midX, baseline: windowFrame.minY + 24, font: .systemFont(ofSize: 14, weight: .semibold),
         color: inkColor, align: .center)
}

func drawCaption(_ text: String) {
    draw(text, x: canvas.width / 2, baseline: captionBaseline, font: .systemFont(ofSize: 20, weight: .semibold),
         color: inkColor, align: .center)
}

/// The typed text with its marks and cursor, and the badge under the spot where the fix landed.
func drawField(state: FrameState, x: CGFloat, baseline: CGFloat, font: NSFont) {
    let top = baseline - font.ascender - 2
    let height = font.ascender - font.descender + 4
    var cursor = x
    for run in state.runs {
        let runWidth = width(of: run.text, font)
        var color = inkColor
        switch run.mark {
        case .plain: break
        case .wrong:
            fill(NSRect(x: cursor - 3, y: top, width: runWidth + 6, height: height), wrongColor, radius: 5)
            color = wrongInk
        case .fixed:
            if state.fixedLevel > 0 {
                fill(NSRect(x: cursor - 3, y: top, width: runWidth + 6, height: height),
                     state.fixedLevel == 2 ? fixedColor : fixedPaleColor, radius: 5)
            }
        case .selected:
            fill(NSRect(x: cursor, y: top, width: runWidth, height: height), selectionColor)
        }
        draw(run.text, x: cursor, baseline: baseline, font: font, color: color)
        cursor += runWidth
    }
    if state.caretOn {
        fill(NSRect(x: cursor + 1, y: top + 1, width: 2, height: height - 2), blue)
    }
    guard state.badgeLevel > 0 else { return }
    // The app's flash, drawn as it looks: like macOS's own layout indicator, the new layout's symbol (a dark
    // rounded square with its letters, "A" or "УК") in a small light bubble under the cursor.
    let badgeFont = NSFont.systemFont(ofSize: 11.5, weight: .bold)
    let alpha = [0, 0.3, 0.65, 1][state.badgeLevel]
    let symbolSize = NSSize(width: max(18, ceil(width(of: state.badge, badgeFont)) + 8), height: 18)
    let padding: CGFloat = 5
    let size = NSSize(width: symbolSize.width + 2 * padding, height: symbolSize.height + 2 * padding)
    let origin = NSPoint(x: x + width(of: state.badgeAnchor, font) - 2, y: top + height + 4)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 6
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22 * alpha)
    shadow.set()
    fill(NSRect(origin: origin, size: size), NSColor(white: 0.985, alpha: alpha), radius: 8)
    NSGraphicsContext.restoreGraphicsState()
    let symbol = NSRect(origin: NSPoint(x: origin.x + padding, y: origin.y + padding), size: symbolSize)
    fill(symbol, badgeColor.withAlphaComponent(alpha), radius: 4)
    draw(state.badge, x: symbol.midX, baseline: symbol.minY + 13.2, font: badgeFont,
         color: NSColor(white: 0.985, alpha: alpha), align: .center)
}

func drawAvatar(_ letter: String, color: NSColor, centerX: CGFloat, centerY: CGFloat) {
    fill(NSRect(x: centerX - 17, y: centerY - 17, width: 34, height: 34), color, radius: 17)
    draw(letter, x: centerX, baseline: centerY + 5.5, font: .systemFont(ofSize: 15, weight: .semibold), color: .white,
         align: .center)
}

func drawMessage(name: String, time: String, text: String, avatar: NSColor, top: CGFloat) {
    let left = windowFrame.minX + 66
    drawAvatar(String(name.prefix(1)), color: avatar, centerX: windowFrame.minX + 38, centerY: top + 22)
    let nameFont = NSFont.systemFont(ofSize: 14, weight: .bold)
    draw(name, x: left, baseline: top + 16, font: nameFont, color: inkColor)
    draw(time, x: left + width(of: name, nameFont) + 8, baseline: top + 16, font: .systemFont(ofSize: 12), color: mutedColor)
    draw(text, x: left, baseline: top + 39, font: .systemFont(ofSize: 17), color: inkColor)
}

func drawChat(_ state: FrameState) {
    drawMenuBar(app: "Chat", state: state)
    drawWindow(title: "# team")
    let top = windowFrame.minY + titleBarHeight
    drawMessage(name: "You", time: "10:02", text: "Дякую, Олено!", avatar: hex(0x7A6FD6), top: top + 18)
    drawMessage(name: "Alex", time: "10:05", text: "Can we meet at 3 pm?", avatar: hex(0xE08A3C), top: top + 82)
    let composer = NSRect(x: windowFrame.minX + 20, y: windowFrame.maxY - 82, width: windowFrame.width - 40, height: 48)
    stroke(composer, blue, radius: 10, width: 1.5)
    fill(NSRect(x: composer.maxX - 40, y: composer.midY - 15, width: 30, height: 30), blue, radius: 15)
    draw("↑", x: composer.maxX - 25, baseline: composer.midY + 6, font: .systemFont(ofSize: 17, weight: .bold),
         color: .white, align: .center)
    drawField(state: state, x: composer.minX + 16, baseline: composer.midY + 7, font: typedFont)
    drawCaption("Forgot to switch layouts? Just keep typing.")
}

func drawMail(_ state: FrameState) {
    drawMenuBar(app: "Mail", state: state)
    drawWindow(title: "New Message")
    let left = windowFrame.minX + 24
    let valueLeft = left + 72
    let top = windowFrame.minY + titleBarHeight
    let labelFont = NSFont.systemFont(ofSize: 15)
    draw("To:", x: left, baseline: top + 28, font: labelFont, color: mutedColor)
    draw("olena@example.com", x: valueLeft, baseline: top + 28, font: labelFont, color: inkColor)
    line(y: top + 42, from: left, to: windowFrame.maxX - 24)
    draw("Subject:", x: left, baseline: top + 68, font: labelFont, color: mutedColor)
    draw("Звіт за тиждень", x: valueLeft, baseline: top + 68, font: labelFont, color: inkColor)
    line(y: top + 82, from: left, to: windowFrame.maxX - 24)
    drawField(state: state, x: left, baseline: top + 124, font: typedFont)
    let send = NSRect(x: left, y: windowFrame.maxY - 54, width: 84, height: 32)
    fill(send, blue, radius: 8)
    draw("Send", x: send.midX, baseline: send.midY + 5.5, font: .systemFont(ofSize: 15, weight: .semibold),
         color: .white, align: .center)
    drawCaption("Works both ways.")
}

func drawOptionKey(pressed: Bool) {
    let size = NSSize(width: 104, height: 66)
    let travel: CGFloat = pressed ? 4 : 0
    let cap = NSRect(x: windowFrame.midX - size.width / 2, y: windowFrame.minY + 176 + travel, width: size.width,
                     height: size.height)
    // The side of the key, which the cap sinks into when pressed.
    fill(NSRect(x: cap.minX, y: windowFrame.minY + 176 + 6, width: size.width, height: size.height),
         pressed ? blue : hex(0xB9C0CB), radius: 11)
    fill(cap, pressed ? paleBlue : hex(0xFAFBFC), radius: 11)
    stroke(cap, pressed ? blue : hex(0xB9C0CB), radius: 11, width: 1.5)
    draw("⌥", x: cap.maxX - 14, baseline: cap.minY + 28, font: .systemFont(ofSize: 22, weight: .medium),
         color: inkColor, align: .right)
    draw("option", x: cap.maxX - 14, baseline: cap.maxY - 12, font: .systemFont(ofSize: 13, weight: .medium),
         color: inkColor, align: .right)
    draw("right ⌥ key", x: windowFrame.midX, baseline: windowFrame.minY + 272, font: .systemFont(ofSize: 13),
         color: mutedColor, align: .center)
}

func drawNotes(_ state: FrameState) {
    drawMenuBar(app: "Notes", state: state)
    drawWindow(title: "Notes")
    let top = windowFrame.minY + titleBarHeight
    draw("Today, 9:41", x: windowFrame.midX, baseline: top + 28, font: .systemFont(ofSize: 12), color: mutedColor,
         align: .center)
    drawOptionKey(pressed: state.keyDown)
    drawField(state: state, x: windowFrame.minX + 34, baseline: top + 72, font: notesFont)
    drawCaption("Already typed it? Select it and tap right ⌥.")
}

func drawEndCard(_ state: FrameState, icon: NSImage?) {
    let alpha = [0.0, 0.35, 0.7, 1.0][state.endLevel]
    let iconSize: CGFloat = 116
    let iconFrame = NSRect(x: (canvas.width - iconSize) / 2, y: 78, width: iconSize, height: iconSize)
    icon?.draw(in: iconFrame, from: .zero, operation: .sourceOver, fraction: alpha, respectFlipped: true, hints: nil)
    let center = canvas.width / 2
    draw("Layout Fixer", x: center, baseline: 252, font: .systemFont(ofSize: 40, weight: .bold),
         color: inkColor.withAlphaComponent(alpha), align: .center)
    draw("Typed on the wrong keyboard layout? Fixed as you type.", x: center, baseline: 294,
         font: .systemFont(ofSize: 19), color: inkColor.withAlphaComponent(alpha), align: .center)
    draw("Free · open source · macOS", x: center, baseline: 330, font: .systemFont(ofSize: 15, weight: .medium),
         color: mutedColor.withAlphaComponent(alpha), align: .center)
}

func render(_ state: FrameState, icon: NSImage?) -> CGImage {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * pixelScale),
                               pixelsHigh: Int(canvas.height * pixelScale), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0,
                               bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    // Top-left origin, in points.
    cg.translateBy(x: 0, y: canvas.height * pixelScale)
    cg.scaleBy(x: pixelScale, y: -pixelScale)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    fill(NSRect(origin: .zero, size: canvas), desktopColor)
    switch state.scene {
    case .chat: drawChat(state)
    case .mail: drawMail(state)
    case .notes: drawNotes(state)
    case .end: drawEndCard(state, icon: icon)
    }
    NSGraphicsContext.current = nil
    return rep.cgImage!
}

// MARK: - The GIF

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let icon = NSImage(contentsOf: root.appendingPathComponent(iconPath))
if icon == nil { print("warning: \(iconPath) not found, the end card has no icon (run from the repo root)") }
let output = root.appendingPathComponent(outputPath)
guard let destination = CGImageDestinationCreateWithURL(output as CFURL, "com.compuserve.gif" as CFString,
                                                        frames.count, nil)
else { fatalError("can't create \(outputPath): run from the repo root") }
let loopForever = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
CGImageDestinationSetProperties(destination, loopForever as CFDictionary)
for frame in frames {
    let seconds = Double(frame.ticks) * tickSeconds
    let delay = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: seconds,
                                                 kCGImagePropertyGIFUnclampedDelayTime: seconds]]
    autoreleasepool {
        CGImageDestinationAddImage(destination, render(frame.state, icon: icon), delay as CFDictionary)
    }
}
guard CGImageDestinationFinalize(destination) else { fatalError("can't write \(outputPath)") }
let sceneStarts = steps.filter { $0.tick == $0.sceneStart }
    .map { String(format: "%.2f", Double($0.tick) * tickSeconds) }
print("scenes start at \(sceneStarts.joined(separator: ", ")) s")
let bytes = (try? FileManager.default.attributesOfItem(atPath: output.path)[.size] as? Int) ?? 0
print(String(format: "wrote %@: %d frames, %.2f s, %d×%d px, %.2f MB", outputPath, frames.count,
             Double(totalTicks) * tickSeconds, Int(canvas.width * pixelScale), Int(canvas.height * pixelScale),
             Double(bytes) / 1_000_000))
