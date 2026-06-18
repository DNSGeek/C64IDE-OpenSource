import Cocoa

// ═══════════════════════════════════════════════════════════
// MARK: - Image Converter Window Controller
// ═══════════════════════════════════════════════════════════

class ImageConverterWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 750, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Image Converter"
        window.center()
        window.minSize = NSSize(width: 700, height: 500)
        window.titlebarAppearsTransparent = true
        window.backgroundColor = AppTheme.current.panelBackground
        self.init(window: window)
        window.contentViewController = ImageConverterViewController()
    }

    @objc func closeTab(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - C64 Palette (RGB values)
// ═══════════════════════════════════════════════════════════

/// C64 palette RGB tuples — sourced from C64Reference.colorPalette
let c64PaletteRGB: [(r: Int, g: Int, b: Int)] = C64Reference.colorPalette.map { $0.rgb }

// ═══════════════════════════════════════════════════════════
// MARK: - Image Converter View Controller
// ═══════════════════════════════════════════════════════════

class ImageConverterViewController: NSViewController {

    private var sourceImageView: NSImageView!
    private var resultImageView: NSImageView!
    private var sourceImage: NSImage?
    private var resultBitmap: C64Bitmap?

    private var modeSelector: NSPopUpButton!
    private var ditherSelector: NSPopUpButton!
    private var brightnessSlider: NSSlider!
    private var contrastSlider: NSSlider!
    private var statusLabel: NSTextField!

    private var bgColor: NSColor { AppTheme.current.panelBackground }
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []

    private var conversionWorkItem: DispatchWorkItem?

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 750, height: 560))
        view.wantsLayer = true
        view.layer?.backgroundColor = bgColor.cgColor
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeDidChange(_:)),
            name: .appThemeDidChange, object: nil)
    }

    @objc private func themeDidChange(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.view.window != nil else { return }
            self.applyThemeColors()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        applyThemeColors()
    }

    private func applyThemeColors() {
        view.window?.appearance      = AppTheme.current.nsAppearance
        view.window?.backgroundColor = AppTheme.current.panelBackground
        view.layer?.backgroundColor  = AppTheme.current.panelBackground.cgColor
        sectionLabels.forEach { $0.textColor = AppTheme.current.syntaxKeyword }
        dimLabels.forEach     { $0.textColor = AppTheme.current.statusLabel }
        statusLabel?.textColor       = AppTheme.current.statusLabel
        sourceImageView?.layer?.backgroundColor = AppTheme.current.panelDetailBackground.cgColor
        resultImageView?.layer?.backgroundColor = AppTheme.current.panelDetailBackground.cgColor
    }

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 15

        // ── Controls bar ─────────────────────────────────
        y -= 22
        let loadBtn = NSButton(title: "Load Image…", target: self, action: #selector(loadImage(_:)))
        loadBtn.frame = NSRect(x: 12, y: y, width: 100, height: 24)
        loadBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(loadBtn)

        let modeLabel = makeLabel("Mode:", bold: false, color: AppTheme.current.statusLabel)
        modeLabel.frame = NSRect(x: 120, y: y + 3, width: 40, height: 16)
        view.addSubview(modeLabel)

        modeSelector = NSPopUpButton(frame: NSRect(x: 163, y: y, width: 120, height: 24))
        modeSelector.addItems(withTitles: ["Hi-Res (320×200)", "Multi-Color (160×200)"])
        modeSelector.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        modeSelector.target = self
        modeSelector.action = #selector(settingsChanged(_:))
        view.addSubview(modeSelector)

        let ditherLabel = makeLabel("Dither:", bold: false, color: AppTheme.current.statusLabel)
        ditherLabel.frame = NSRect(x: 290, y: y + 3, width: 45, height: 16)
        view.addSubview(ditherLabel)

        ditherSelector = NSPopUpButton(frame: NSRect(x: 340, y: y, width: 130, height: 24))
        ditherSelector.addItems(withTitles: ["None", "Floyd-Steinberg", "Ordered (Bayer)"])
        ditherSelector.selectItem(at: 1)
        ditherSelector.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        ditherSelector.target = self
        ditherSelector.action = #selector(settingsChanged(_:))
        view.addSubview(ditherSelector)

        let convertBtn = NSButton(title: "Convert", target: self, action: #selector(convertImage(_:)))
        convertBtn.frame = NSRect(x: 480, y: y, width: 70, height: 24)
        convertBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .bold)
        view.addSubview(convertBtn)

        let exportBtn = NSButton(title: "Export…", target: self, action: #selector(exportResult(_:)))
        exportBtn.frame = NSRect(x: 555, y: y, width: 65, height: 24)
        exportBtn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(exportBtn)

        let d64Btn = NSButton(title: "→ D64", target: self, action: #selector(saveToD64(_:)))
        d64Btn.frame = NSRect(x: 625, y: y, width: 55, height: 24)
        d64Btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        view.addSubview(d64Btn)

        // ── Brightness/Contrast ──────────────────────────
        y -= 28
        let briLabel = makeLabel("Brightness:", bold: false, color: AppTheme.current.statusLabel)
        briLabel.frame = NSRect(x: 12, y: y + 2, width: 80, height: 16)
        view.addSubview(briLabel)

        brightnessSlider = NSSlider(value: 0, minValue: -50, maxValue: 50, target: self, action: #selector(settingsChanged(_:)))
        brightnessSlider.frame = NSRect(x: 95, y: y, width: 120, height: 20)
        view.addSubview(brightnessSlider)

        let conLabel = makeLabel("Contrast:", bold: false, color: AppTheme.current.statusLabel)
        conLabel.frame = NSRect(x: 230, y: y + 2, width: 65, height: 16)
        view.addSubview(conLabel)

        contrastSlider = NSSlider(value: 0, minValue: -50, maxValue: 50, target: self, action: #selector(settingsChanged(_:)))
        contrastSlider.frame = NSRect(x: 300, y: y, width: 120, height: 20)
        view.addSubview(contrastSlider)

        let resetBtn = NSButton(title: "Reset", target: self, action: #selector(resetSliders(_:)))
        resetBtn.frame = NSRect(x: 430, y: y, width: 50, height: 20)
        resetBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
        view.addSubview(resetBtn)

        // ── Image views ──────────────────────────────────
        y -= 10
        let halfW = (w - 36) / 2
        let imgH = y - 35

        let srcLabel = makeLabel("SOURCE", bold: true, color: AppTheme.current.syntaxKeyword)
        srcLabel.frame = NSRect(x: 12, y: y - 2, width: 80, height: 16)
        view.addSubview(srcLabel)

        let resLabel = makeLabel("C64 RESULT", bold: true, color: AppTheme.current.syntaxKeyword)
        resLabel.frame = NSRect(x: halfW + 24, y: y - 2, width: 100, height: 16)
        view.addSubview(resLabel)

        y -= 18

        sourceImageView = NSImageView(frame: NSRect(x: 12, y: 28, width: halfW, height: imgH))
        sourceImageView.imageScaling = .scaleProportionallyUpOrDown
        sourceImageView.wantsLayer = true
        sourceImageView.layer?.backgroundColor = AppTheme.current.panelDetailBackground.cgColor
        sourceImageView.layer?.cornerRadius = 4
        sourceImageView.autoresizingMask = [.width, .height]
        view.addSubview(sourceImageView)

        resultImageView = NSImageView(frame: NSRect(x: halfW + 24, y: 28, width: halfW, height: imgH))
        resultImageView.imageScaling = .scaleProportionallyUpOrDown
        resultImageView.wantsLayer = true
        resultImageView.layer?.backgroundColor = AppTheme.current.panelDetailBackground.cgColor
        resultImageView.layer?.cornerRadius = 4
        resultImageView.autoresizingMask = [.width, .height]
        view.addSubview(resultImageView)

        // ── Status ───────────────────────────────────────
        statusLabel = makeLabel("Load an image to convert to C64 format.", bold: false, color: AppTheme.current.statusLabel)
        statusLabel.frame = NSRect(x: 12, y: 6, width: w - 24, height: 16)
        view.addSubview(statusLabel)
    }

    private func makeLabel(_ text: String, bold: Bool, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = color
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    // MARK: - Load Image

    @objc private func loadImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .png, .jpeg, .tiff, .bmp, .gif,
            .webP, .heic, .heif, .svg, .pdf, .rawImage,
            .init(filenameExtension: "ico") ?? .image,
            .init(filenameExtension: "tga") ?? .image,
            .init(filenameExtension: "pnm") ?? .image,
            .init(filenameExtension: "pcx") ?? .image,
        ]
        panel.title = "Load Image"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            guard let image = NSImage(contentsOf: url) else {
                self?.statusLabel.stringValue = "Failed to load image."
                return
            }
            self?.sourceImage = image
            self?.sourceImageView.image = image

            if let cgImg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self?.statusLabel.stringValue = "Loaded: \(url.lastPathComponent) (\(cgImg.width)×\(cgImg.height) px)"
            } else {
                self?.statusLabel.stringValue = "Loaded: \(url.lastPathComponent)"
            }
        }
    }

    // MARK: - Convert

    @objc private func settingsChanged(_ sender: Any?) {
        guard sourceImage != nil else { return }
        conversionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runConversion() }
        conversionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @objc private func resetSliders(_ sender: Any?) {
        brightnessSlider.doubleValue = 0
        contrastSlider.doubleValue = 0
        if sourceImage != nil { convertImage(sender) }
    }

    @objc private func convertImage(_ sender: Any?) {
        guard sourceImage != nil else {
            statusLabel.stringValue = "Load an image first."
            return
        }
        // Cancel any pending debounced work and convert immediately.
        conversionWorkItem?.cancel()
        conversionWorkItem = nil
        runConversion()
    }

    // Shared conversion entry point called by both convertImage and the
    // debounced settingsChanged path.  Always called on the main thread;
    // pixel extraction and heavy lifting happen on a background thread.
    private func runConversion() {
        guard let source = sourceImage else { return }

        let isMultiColor = modeSelector.indexOfSelectedItem == 1
        let ditherMode   = ditherSelector.indexOfSelectedItem
        let brightness   = brightnessSlider.doubleValue
        let contrast     = contrastSlider.doubleValue

        statusLabel.stringValue = "Converting..."

        guard let cgImage = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            statusLabel.stringValue = "Failed to read image data."
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let bitmap = self.performConversion(
                cgImage:    cgImage,
                multiColor: isMultiColor,
                dither:     ditherMode,
                brightness: brightness,
                contrast:   contrast
            )

            DispatchQueue.main.async {
                self.resultBitmap = bitmap
                self.resultImageView.image = self.bitmapToNSImage(bitmap)
                let mode = isMultiColor ? "multi-color" : "hi-res"
                self.statusLabel.stringValue = "Converted to C64 \(mode) format."
            }
        }
    }

    // MARK: - Conversion Engine

    private func performConversion(cgImage: CGImage, multiColor: Bool, dither: Int, brightness: Double, contrast: Double) -> C64Bitmap {
        let targetW = multiColor ? 160 : 320
        let targetH = 200

        let pixels = getScaledPixels(from: cgImage, width: targetW, height: targetH, brightness: brightness, contrast: contrast)

        let bitmap = C64Bitmap()
        bitmap.isMultiColor = multiColor

        let cellPixelW = multiColor ? 4 : 8
        let cellCols   = targetW / cellPixelW
        let cellRows   = targetH / 8

        // ── Multi-color global background pre-pass ────────────────────────────
        var globalBg = 0
        if multiColor {
            var bestBgError = Double.infinity

            for candidate in 0..<16 {
                var totalError = 0.0

                for cellRow in 0..<cellRows {
                    for cellCol in 0..<cellCols {
                        // Collect cell pixels
                        var cellPixels: [(r: Double, g: Double, b: Double)] = []
                        for py in 0..<8 {
                            for px in 0..<cellPixelW {
                                let x = cellCol * cellPixelW + px
                                let y = cellRow * 8 + py
                                if x < targetW && y < targetH {
                                    cellPixels.append(pixels[y][x])
                                }
                            }
                        }
                        // Best 3 per-cell colours excluding the candidate background
                        let cellColors = findBestColors(cellPixels, count: 3, excluding: candidate)
                        let palette    = [candidate] + cellColors

                        // Sum error for each pixel against this 4-entry palette
                        for pixel in cellPixels {
                            var minDist = Double.infinity
                            for c in palette {
                                let d = colorDistance(pixel, c64Color: c)
                                if d < minDist { minDist = d }
                            }
                            totalError += minDist
                        }
                    }
                }

                if totalError < bestBgError {
                    bestBgError = totalError
                    globalBg    = candidate
                }
            }
            bitmap.backgroundColor = UInt8(globalBg)
        }

        var fsError = Array(
            repeating: Array(repeating: (r: 0.0, g: 0.0, b: 0.0), count: targetW + 1),
            count: 2
        )

        for cellRow in 0..<cellRows {
            for cellCol in 0..<cellCols {

                // Collect pixels for this cell
                var cellPixels: [(r: Double, g: Double, b: Double)] = []
                for py in 0..<8 {
                    for px in 0..<cellPixelW {
                        let x = cellCol * cellPixelW + px
                        let y = cellRow * 8 + py
                        if x < targetW && y < targetH {
                            cellPixels.append(pixels[y][x])
                        }
                    }
                }

                if multiColor {
                    let cellColors = findBestColors(cellPixels, count: 3, excluding: globalBg)
                    if cellColors.count > 0 { bitmap.cellForeground[cellRow][cellCol] = UInt8(cellColors[0]) }
                    if cellColors.count > 1 { bitmap.cellBackground[cellRow][cellCol] = UInt8(cellColors[1]) }
                    if cellColors.count > 2 { bitmap.cellColorRAM[cellRow][cellCol]   = UInt8(cellColors[2]) }

                    // palette[0] = background ($D021), slots 1–3 = cell registers
                    let padding = Array(repeating: globalBg, count: max(0, 3 - cellColors.count))
                    let palette = [globalBg] + cellColors + padding

                    for py in 0..<8 {
                        let absY = cellRow * 8 + py

                        for px in 0..<cellPixelW {
                            let x = cellCol * cellPixelW + px
                            let y = absY
                            guard x < targetW, y < targetH else { continue }

                            var rgb = pixels[y][x]

                            if dither == 1 {
                                // Floyd-Steinberg: apply accumulated error
                                rgb.r = max(0, min(255, rgb.r + fsError[0][x].r))
                                rgb.g = max(0, min(255, rgb.g + fsError[0][x].g))
                                rgb.b = max(0, min(255, rgb.b + fsError[0][x].b))
                            } else if dither == 2 {
                                // Bayer 4×4 ordered dithering (scale ×16)
                                let bayerMatrix: [[Double]] = [
                                    [-0.5,    0.0,    -0.375,  0.125 ],
                                    [ 0.25,  -0.25,   0.375, -0.125 ],
                                    [-0.3125, 0.1875, -0.4375, 0.0625],
                                    [ 0.4375,-0.0625,  0.3125,-0.1875],
                                ]
                                let threshold = bayerMatrix[y % 4][x % 4] * 16
                                rgb.r = max(0, min(255, rgb.r + threshold))
                                rgb.g = max(0, min(255, rgb.g + threshold))
                                rgb.b = max(0, min(255, rgb.b + threshold))
                            }

                            let chosenIdx = closestPaletteIndex(rgb, from: palette)
                            bitmap.pixels[y][x] = UInt8(chosenIdx)

                            if dither == 1 {
                                // Distribute Floyd-Steinberg error
                                let chosenC   = palette[chosenIdx]
                                let chosenRGB = c64PaletteRGB[chosenC]
                                let errR = rgb.r - Double(chosenRGB.r)
                                let errG = rgb.g - Double(chosenRGB.g)
                                let errB = rgb.b - Double(chosenRGB.b)

                                if x + 1 < targetW {
                                    fsError[0][x + 1].r += errR * 7 / 16
                                    fsError[0][x + 1].g += errG * 7 / 16
                                    fsError[0][x + 1].b += errB * 7 / 16
                                }
                                if y + 1 < targetH {
                                    if x > 0 {
                                        fsError[1][x - 1].r += errR * 3 / 16
                                        fsError[1][x - 1].g += errG * 3 / 16
                                        fsError[1][x - 1].b += errB * 3 / 16
                                    }
                                    fsError[1][x].r += errR * 5 / 16
                                    fsError[1][x].g += errG * 5 / 16
                                    fsError[1][x].b += errB * 5 / 16
                                    if x + 1 < targetW {
                                        fsError[1][x + 1].r += errR * 1 / 16
                                        fsError[1][x + 1].g += errG * 1 / 16
                                        fsError[1][x + 1].b += errB * 1 / 16
                                    }
                                }
                            }
                        }

                        // Advance FS rolling buffer at end of each image scanline.
                        if dither == 1 {
                            fsError[0] = fsError[1]
                            fsError[1] = Array(repeating: (r: 0.0, g: 0.0, b: 0.0), count: targetW + 1)
                        }
                    }

                } else {
                    // Hi-res: 2 colors per cell, dithering supported
                    let bestColors = findBestColors(cellPixels, count: 2)
                    let bg = bestColors.count > 0 ? bestColors[0] : 0
                    let fg = bestColors.count > 1 ? bestColors[1] : 1

                    bitmap.cellBackground[cellRow][cellCol] = UInt8(bg)
                    bitmap.cellForeground[cellRow][cellCol] = UInt8(fg)

                    for py in 0..<8 {
                        let absY = cellRow * 8 + py

                        for px in 0..<cellPixelW {
                            let x = cellCol * cellPixelW + px
                            let y = absY
                            guard x < targetW, y < targetH else { continue }

                            var rgb = pixels[y][x]

                            if dither == 1 {
                                // Floyd-Steinberg: apply accumulated error
                                rgb.r = max(0, min(255, rgb.r + fsError[0][x].r))
                                rgb.g = max(0, min(255, rgb.g + fsError[0][x].g))
                                rgb.b = max(0, min(255, rgb.b + fsError[0][x].b))
                            } else if dither == 2 {
                                let bayerMatrix: [[Double]] = [
                                    [-0.5,    0.0,    -0.375,  0.125 ],
                                    [ 0.25,  -0.25,   0.375, -0.125 ],
                                    [-0.3125, 0.1875, -0.4375, 0.0625],
                                    [ 0.4375,-0.0625,  0.3125,-0.1875],
                                ]
                                let threshold = bayerMatrix[y % 4][x % 4] * 16
                                rgb.r = max(0, min(255, rgb.r + threshold))
                                rgb.g = max(0, min(255, rgb.g + threshold))
                                rgb.b = max(0, min(255, rgb.b + threshold))
                            }

                            let bgDist = colorDistance(rgb, c64Color: bg)
                            let fgDist = colorDistance(rgb, c64Color: fg)
                            let chosen = bgDist < fgDist ? bg : fg
                            bitmap.pixels[y][x] = chosen == bg ? 0 : 1

                            if dither == 1 {
                                let chosenRGB = c64PaletteRGB[chosen]
                                let errR = rgb.r - Double(chosenRGB.r)
                                let errG = rgb.g - Double(chosenRGB.g)
                                let errB = rgb.b - Double(chosenRGB.b)

                                if x + 1 < targetW {
                                    fsError[0][x + 1].r += errR * 7 / 16
                                    fsError[0][x + 1].g += errG * 7 / 16
                                    fsError[0][x + 1].b += errB * 7 / 16
                                }
                                if y + 1 < targetH {
                                    if x > 0 {
                                        fsError[1][x - 1].r += errR * 3 / 16
                                        fsError[1][x - 1].g += errG * 3 / 16
                                        fsError[1][x - 1].b += errB * 3 / 16
                                    }
                                    fsError[1][x].r += errR * 5 / 16
                                    fsError[1][x].g += errG * 5 / 16
                                    fsError[1][x].b += errB * 5 / 16
                                    if x + 1 < targetW {
                                        fsError[1][x + 1].r += errR * 1 / 16
                                        fsError[1][x + 1].g += errG * 1 / 16
                                        fsError[1][x + 1].b += errB * 1 / 16
                                    }
                                }
                            }
                        }

                        // Advance FS rolling buffer at the end of each image scanline.
                        if dither == 1 {
                            fsError[0] = fsError[1]
                            fsError[1] = Array(repeating: (r: 0.0, g: 0.0, b: 0.0), count: targetW + 1)
                        }
                    }
                }
            }
        }

        return bitmap
    }

    // MARK: - Pixel Extraction

    // Renders `image` (a CGImage) into a CGContext at `width`×`height` pixels,
    // then reads back raw RGBA bytes and applies brightness/contrast.
    private func getScaledPixels(from cgImage: CGImage, width: Int, height: Int, brightness: Double, contrast: Double) -> [[(r: Double, g: Double, b: Double)]] {

        let bytesPerPixel = 4
        let bytesPerRow   = width * bytesPerPixel
        var rawBytes      = [UInt8](repeating: 0, count: height * bytesPerRow)

        guard let ctx = CGContext(
            data:             &rawBytes,
            width:            width,
            height:           height,
            bitsPerComponent: 8,
            bytesPerRow:      bytesPerRow,
            space:            CGColorSpaceCreateDeviceRGB(),
            bitmapInfo:       CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            // Return a black pixel grid rather than crashing if context creation fails.
            return Array(repeating: Array(repeating: (0.0, 0.0, 0.0), count: width), count: height)
        }

        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let contrastFactor = (259.0 * (contrast + 255.0)) / (255.0 * (259.0 - contrast))

        var pixels = Array(repeating: Array(repeating: (r: 0.0, g: 0.0, b: 0.0), count: width), count: height)

        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * width + x) * bytesPerPixel
                var r = Double(rawBytes[offset])
                var g = Double(rawBytes[offset + 1])
                var b = Double(rawBytes[offset + 2])
                let a = Double(rawBytes[offset + 3])

                // Un-premultiply alpha so brightness/contrast operate on
                // the true colour values rather than pre-blended ones.
                if a > 0 {
                    let invA = 255.0 / a
                    r *= invA; g *= invA; b *= invA
                }

                // Apply brightness
                r += brightness; g += brightness; b += brightness

                // Apply contrast (standard formula: C = (259*(K+255))/(255*(259-K)))
                r = contrastFactor * (r - 128) + 128
                g = contrastFactor * (g - 128) + 128
                b = contrastFactor * (b - 128) + 128

                pixels[y][x] = (max(0, min(255, r)), max(0, min(255, g)), max(0, min(255, b)))
            }
        }

        return pixels
    }

    // MARK: - Color Matching

    /// Euclidean distance weighted by human perceptual sensitivity (ITU-R BT.601)
    private func colorDistance(_ pixel: (r: Double, g: Double, b: Double), c64Color: Int) -> Double {
        let c  = c64PaletteRGB[c64Color]
        let dr = pixel.r - Double(c.r)
        let dg = pixel.g - Double(c.g)
        let db = pixel.b - Double(c.b)
        // Weighted distance (human eye is most sensitive to green)
        return dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114
    }

    private func closestPaletteIndex(_ pixel: (r: Double, g: Double, b: Double), from palette: [Int]) -> Int {
        var bestIdx  = 0
        var bestDist = Double.infinity
        for (i, colorIdx) in palette.enumerated() {
            let dist = colorDistance(pixel, c64Color: colorIdx)
            if dist < bestDist { bestDist = dist; bestIdx = i }
        }
        return bestIdx
    }

    // Find the best N C64 palette entries to represent a set of pixels.
    private func findBestColors(_ pixels: [(r: Double, g: Double, b: Double)], count: Int, excluding: Int? = nil) -> [Int] {
        guard !pixels.isEmpty else { return Array(0..<min(count, 16)) }

        let candidates = (0..<16).filter { $0 != excluding }
        guard !candidates.isEmpty else { return [] }

        var covered:   [Int]                                = excluding.map { [$0] } ?? []
        var chosen:    [Int]                                = []
        var remaining: [(r: Double, g: Double, b: Double)] = pixels

        while chosen.count < count {
            guard !remaining.isEmpty else { break }

            let nextC: Int

            if chosen.isEmpty {
                let n   = Double(remaining.count)
                let avgR = remaining.reduce(0.0) { $0 + $1.r } / n
                let avgG = remaining.reduce(0.0) { $0 + $1.g } / n
                let avgB = remaining.reduce(0.0) { $0 + $1.b } / n
                let centroid = (r: avgR, g: avgG, b: avgB)

                var bestC    = candidates.first!
                var bestDist = Double.infinity
                for c in candidates where !chosen.contains(c) {
                    let d = colorDistance(centroid, c64Color: c)
                    if d < bestDist { bestDist = d; bestC = c }
                }
                nextC = bestC
            } else {
                var votes = [Int: Int]()
                for pixel in remaining {
                    var bestC    = candidates.first!
                    var bestDist = Double.infinity
                    for c in candidates where !chosen.contains(c) {
                        let d = colorDistance(pixel, c64Color: c)
                        if d < bestDist { bestDist = d; bestC = c }
                    }
                    votes[bestC, default: 0] += 1
                }
                guard let winner = votes.max(by: { $0.value < $1.value })?.key else { break }
                nextC = winner
            }

            chosen.append(nextC)
            covered.append(nextC)

            // Remove pixels now well-served by the full covered set.
            remaining = remaining.filter { pixel in
                var nearestDist = Double.infinity
                var nearestC    = nextC
                for c in covered {
                    let d = colorDistance(pixel, c64Color: c)
                    if d < nearestDist { nearestDist = d; nearestC = c }
                }
                return nearestC != nextC
            }
        }

        return chosen
    }

    // MARK: - Bitmap → NSImage

    private func bitmapToNSImage(_ bitmap: C64Bitmap) -> NSImage {
        let w = 320
        let h = 200

        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: w,
            pixelsHigh: h,
            bitsPerSample: 8,
            samplesPerPixel: 3,
            hasAlpha: false,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: w * 3,
            bitsPerPixel: 24
        )!

        for y in 0..<h {
            for x in 0..<w {
                let colorIdx = Int(bitmap.displayColor(x: x, y: y))
                let c        = c64PaletteRGB[min(colorIdx, 15)]
                let offset   = (y * w + x) * 3
                rep.bitmapData![offset]     = UInt8(c.r)
                rep.bitmapData![offset + 1] = UInt8(c.g)
                rep.bitmapData![offset + 2] = UInt8(c.b)
            }
        }

        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Export

    @objc private func exportResult(_ sender: Any?) {
        guard let bitmap = resultBitmap else {
            statusLabel.stringValue = "Convert an image first."
            return
        }

        let panel    = NSSavePanel()
        let accessory = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        if bitmap.isMultiColor {
            accessory.addItems(withTitles: ["Koala Painter (.kla)", "Assembly (.asm)", "BASIC DATA (.bas)", "PRG (.prg)"])
        } else {
            accessory.addItems(withTitles: ["Art Studio (.art)", "Assembly (.asm)", "BASIC DATA (.bas)", "PRG (.prg)"])
        }
        panel.accessoryView          = accessory
        panel.nameFieldStringValue   = bitmap.isMultiColor ? "converted.kla" : "converted.art"

        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            switch accessory.indexOfSelectedItem {
            case 0:
                let data = bitmap.isMultiColor ? bitmap.exportKoala() : bitmap.exportArtStudio()
                try? data.write(to: url)
            case 1:
                try? bitmap.exportAsAssembly().write(to: url, atomically: true, encoding: .utf8)
            case 2:
                try? bitmap.exportAsBASIC().write(to: url, atomically: true, encoding: .utf8)
            case 3:
                try? bitmap.exportAsPRG().write(to: url)
            default: break
            }
            self?.statusLabel.stringValue = "Exported to \(url.lastPathComponent)"
        }
    }

    @objc private func saveToD64(_ sender: Any?) {
        guard let bitmap = resultBitmap else {
            statusLabel.stringValue = "Convert an image first."
            return
        }

        let data = bitmap.isMultiColor ? bitmap.exportKoala() : bitmap.exportArtStudio()

        let alert = NSAlert()
        alert.messageText = "Save to D64"
        alert.addButton(withTitle: "New D64…")
        alert.addButton(withTitle: "Existing D64…")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard response != .alertThirdButtonReturn else { return }

        let filename = "CONVERTED"

        if response == .alertFirstButtonReturn {
            let panel = NSSavePanel()
            panel.allowedContentTypes  = [.init(filenameExtension: "d64")!]
            panel.nameFieldStringValue = "converted.d64"
            panel.begin { saveResponse in
                guard saveResponse == .OK, let url = panel.url else { return }
                let disk = D64Image(diskName: "CONVERTED", diskID: "CV")
                if disk.writeFile(name: filename, data: Array(data)) {
                    try? disk.save(to: url)
                }
            }
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.init(filenameExtension: "d64")!]
            panel.begin { openResponse in
                guard openResponse == .OK, let url = panel.url else { return }
                if let disk = try? D64Image(contentsOf: url) {
                    if disk.writeFile(name: filename, data: Array(data)) { try? disk.save() }
                }
            }
        }
    }
}
