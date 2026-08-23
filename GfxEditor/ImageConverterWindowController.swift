import Cocoa
import UniformTypeIdentifiers

// ═══════════════════════════════════════════════════════════
// MARK: - Image Converter Window Controller
// ═══════════════════════════════════════════════════════════

class ImageConverterWindowController: NSWindowController {
    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Image Converter"
        window.center()
        window.minSize = NSSize(width: 860, height: 520)
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
// MARK: - Preview View
// ═══════════════════════════════════════════════════════════

/// Image preview that scales without smoothing, so a 320×200 C64 result stays
/// crisp when blown up. `NSImageView` always interpolates, which turned the
/// result panel into a blur. Doubles as the drag-and-drop target for the
/// source image.
final class ImageConverterPreviewView: NSView {

    /// Smooth the source photo (it is a real photo at real resolution) but
    /// never the C64 result, whose whole point is visible pixels.
    var smoothScaling = false

    var image: NSImage? {
        didSet { needsDisplay = true }
    }

    /// Set to accept file drops. Nil leaves the view inert.
    var onDropURL: ((URL) -> Void)? {
        didSet {
            if onDropURL != nil { registerForDraggedTypes([.fileURL]) } else { unregisterDraggedTypes() }
        }
    }

    private var isDropTarget = false {
        didSet { if isDropTarget != oldValue { needsDisplay = true } }
    }

    override func draw(_ dirtyRect: NSRect) {
        let rounded = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        AppTheme.current.panelDetailBackground.setFill()
        rounded.fill()

        if let image, image.size.width > 0, image.size.height > 0 {
            let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
            let w = image.size.width * scale
            let h = image.size.height * scale
            let rect = NSRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.imageInterpolation = smoothScaling ? .high : .none
            image.draw(in: rect)
            NSGraphicsContext.restoreGraphicsState()
        }

        if isDropTarget {
            AppTheme.current.syntaxKeyword.setStroke()
            rounded.lineWidth = 2
            rounded.stroke()
        }
    }

    // MARK: Drag and drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard droppedImageURL(from: sender) != nil else { return [] }
        isDropTarget = true
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDropTarget = false
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        isDropTarget = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        isDropTarget = false
        guard let url = droppedImageURL(from: sender) else { return false }
        onDropURL?(url)
        return true
    }

    private func droppedImageURL(from sender: NSDraggingInfo) -> URL? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
            .urlReadingContentsConformToTypes: [UTType.image.identifier, UTType.pdf.identifier],
        ]
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL]
        return urls?.first
    }
}

// ═══════════════════════════════════════════════════════════
// MARK: - Conversion Settings
// ═══════════════════════════════════════════════════════════

/// One-shot cancellation flag shared between the main thread and a conversion
/// worker. Locked rather than plain, because the worker polls it from a
/// background queue while the main thread flips it.
private final class CancellationToken {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }
}

/// How the source image is mapped onto the C64's 320×200 visible area.
private enum ScaleMode: Int {
    case stretch = 0   // distort to fill
    case fit     = 1   // preserve aspect, letterbox with the backdrop colour
    case fill    = 2   // preserve aspect, crop the overflow
}

/// Everything `performConversion` needs, snapshotted on the main thread so the
/// background worker never touches a control.
private struct ConversionSettings {
    var multiColor: Bool
    var dither: Int
    var brightness: Double
    var contrast: Double
    var scaleMode: ScaleMode
    var backdrop: (r: Double, g: Double, b: Double)
    /// Nil means "search all 16 for the best global background".
    var forcedBackground: Int?
}

// ═══════════════════════════════════════════════════════════
// MARK: - Image Converter View Controller
// ═══════════════════════════════════════════════════════════

class ImageConverterViewController: NSViewController {

    private var sourceImageView: ImageConverterPreviewView!
    private var resultImageView: ImageConverterPreviewView!
    /// Rasterised once at load time — re-deriving it per conversion re-rendered
    /// vector sources every time and cost real milliseconds on large photos.
    private var sourceCGImage: CGImage?
    private var resultBitmap: C64Bitmap?

    private var modeSelector: NSPopUpButton!
    private var ditherSelector: NSPopUpButton!
    private var scaleSelector: NSPopUpButton!
    private var backdropSelector: NSPopUpButton!
    private var bgColorSelector: NSPopUpButton!
    private var brightnessSlider: NSSlider!
    private var contrastSlider: NSSlider!
    private var statusLabel: NSTextField!
    private var spinner: NSProgressIndicator!
    private var bgColorLabel: NSTextField!

    private var bgColor: NSColor { AppTheme.current.panelBackground }
    private var sectionLabels: [NSTextField] = []
    private var dimLabels:     [NSTextField] = []

    private var conversionWorkItem: DispatchWorkItem?

    /// The token belonging to the newest conversion. Starting a conversion
    /// cancels the previous token, so an older worker both bails out early and
    /// has its result discarded on arrival — without it, a slow conversion
    /// could land after a newer one and overwrite it.
    private var conversionToken: CancellationToken?
    private var activeConversions = 0

    override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 620))
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
        sourceImageView?.needsDisplay = true
        resultImageView?.needsDisplay = true
        if bgColorSelector != nil { setBackgroundPickerEnabled(bgColorSelector.isEnabled) }
    }

    // MARK: - UI

    private func buildUI() {
        let w = view.bounds.width
        var y = view.bounds.height - 15

        // ── Row 1: actions ───────────────────────────────
        y -= 22
        let loadBtn = makeButton("Load Image…", bold: false, action: #selector(loadImage(_:)))
        loadBtn.frame = NSRect(x: 12, y: y, width: 105, height: 24)

        let convertBtn = makeButton("Convert", bold: true, action: #selector(convertImage(_:)))
        convertBtn.frame = NSRect(x: 125, y: y, width: 75, height: 24)

        let exportBtn = makeButton("Export…", bold: false, action: #selector(exportResult(_:)))
        exportBtn.frame = NSRect(x: 208, y: y, width: 72, height: 24)

        let d64Btn = makeButton("→ D64", bold: false, action: #selector(saveToD64(_:)))
        d64Btn.frame = NSRect(x: 288, y: y, width: 62, height: 24)

        let editorBtn = makeButton("→ Editor", bold: false, action: #selector(sendToEditor(_:)))
        editorBtn.frame = NSRect(x: 358, y: y, width: 78, height: 24)

        spinner = NSProgressIndicator(frame: NSRect(x: 446, y: y + 4, width: 16, height: 16))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.autoresizingMask = [.minYMargin]
        view.addSubview(spinner)

        // ── Row 2: format ────────────────────────────────
        y -= 30
        addLabel("Mode:", x: 12, y: y + 3, width: 42)
        modeSelector = makePopUp(x: 56, y: y, width: 160,
                                 items: ["Hi-Res (320×200)", "Multi-Color (160×200)"])
        modeSelector.action = #selector(modeChanged(_:))

        addLabel("Dither:", x: 226, y: y + 3, width: 48)
        ditherSelector = makePopUp(x: 276, y: y, width: 150,
                                   items: ["None", "Floyd-Steinberg", "Ordered (Bayer)"])
        ditherSelector.selectItem(at: 1)

        addLabel("Scale:", x: 436, y: y + 3, width: 44)
        scaleSelector = makePopUp(x: 482, y: y, width: 150,
                                  items: ["Stretch to Fill", "Fit (Letterbox)", "Fill (Crop)"])

        addLabel("Backdrop:", x: 642, y: y + 3, width: 66)
        backdropSelector = makePopUp(x: 710, y: y, width: 90, items: ["White", "Black"])

        // ── Row 3: tone ──────────────────────────────────
        y -= 30
        addLabel("Brightness:", x: 12, y: y + 4, width: 78)
        brightnessSlider = makeSlider(x: 92, y: y + 2, width: 120)

        addLabel("Contrast:", x: 226, y: y + 4, width: 64)
        contrastSlider = makeSlider(x: 292, y: y + 2, width: 120)

        let resetBtn = makeButton("Reset", bold: false, action: #selector(resetSliders(_:)))
        resetBtn.frame = NSRect(x: 422, y: y + 1, width: 54, height: 22)
        resetBtn.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)

        bgColorLabel = addLabel("Background:", x: 496, y: y + 4, width: 80)
        bgColorSelector = makePopUp(x: 578, y: y, width: 150,
                                    items: ["Auto"] + C64Reference.colorPalette.map { "\($0.index). \($0.name)" })
        // Only meaningful in multi-color mode, where $D021 is a real global slot.
        setBackgroundPickerEnabled(false)

        // ── Image views ──────────────────────────────────
        y -= 26
        let halfW = (w - 36) / 2

        let srcLabel = makeLabel("SOURCE", bold: true, color: AppTheme.current.syntaxKeyword)
        srcLabel.frame = NSRect(x: 12, y: y, width: 80, height: 16)
        srcLabel.autoresizingMask = [.minYMargin]
        view.addSubview(srcLabel)

        let resLabel = makeLabel("C64 RESULT", bold: true, color: AppTheme.current.syntaxKeyword)
        resLabel.frame = NSRect(x: halfW + 24, y: y, width: 100, height: 16)
        resLabel.autoresizingMask = [.minYMargin]
        view.addSubview(resLabel)

        y -= 8
        let imgH = y - 28

        sourceImageView = ImageConverterPreviewView(frame: NSRect(x: 12, y: 28, width: halfW, height: imgH))
        sourceImageView.smoothScaling = true
        sourceImageView.autoresizingMask = [.width, .height]
        sourceImageView.onDropURL = { [weak self] url in self?.load(url: url) }
        view.addSubview(sourceImageView)

        resultImageView = ImageConverterPreviewView(frame: NSRect(x: halfW + 24, y: 28, width: halfW, height: imgH))
        resultImageView.autoresizingMask = [.width, .height]
        view.addSubview(resultImageView)

        // ── Status ───────────────────────────────────────
        statusLabel = makeLabel("Load an image — or drop one on the SOURCE panel — to convert it.",
                                bold: false, color: AppTheme.current.statusLabel)
        statusLabel.frame = NSRect(x: 12, y: 6, width: w - 24, height: 16)
        statusLabel.autoresizingMask = [.width, .maxYMargin]
        view.addSubview(statusLabel)
    }

    private func makeButton(_ title: String, bold: Bool, action: Selector) -> NSButton {
        let btn = NSButton(title: title, target: self, action: action)
        btn.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .medium)
        btn.autoresizingMask = [.minYMargin]
        view.addSubview(btn)
        return btn
    }

    private func makePopUp(x: CGFloat, y: CGFloat, width: CGFloat, items: [String]) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: NSRect(x: x, y: y, width: width, height: 24))
        popUp.addItems(withTitles: items)
        popUp.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
        popUp.target = self
        popUp.action = #selector(settingsChanged(_:))
        popUp.autoresizingMask = [.minYMargin]
        view.addSubview(popUp)
        return popUp
    }

    private func makeSlider(x: CGFloat, y: CGFloat, width: CGFloat) -> NSSlider {
        let slider = NSSlider(value: 0, minValue: -50, maxValue: 50,
                              target: self, action: #selector(settingsChanged(_:)))
        slider.frame = NSRect(x: x, y: y, width: width, height: 20)
        slider.autoresizingMask = [.minYMargin]
        view.addSubview(slider)
        return slider
    }

    @discardableResult
    private func addLabel(_ text: String, x: CGFloat, y: CGFloat, width: CGFloat) -> NSTextField {
        let label = makeLabel(text, bold: false, color: AppTheme.current.statusLabel)
        label.frame = NSRect(x: x, y: y, width: width, height: 16)
        label.autoresizingMask = [.minYMargin]
        view.addSubview(label)
        return label
    }

    private func makeLabel(_ text: String, bold: Bool, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = NSFont.monospacedSystemFont(ofSize: 11, weight: bold ? .bold : .regular)
        label.textColor = color
        if bold { sectionLabels.append(label) } else { dimLabels.append(label) }
        return label
    }

    private func setBackgroundPickerEnabled(_ enabled: Bool) {
        bgColorSelector.isEnabled = enabled
        bgColorLabel.textColor = enabled
            ? AppTheme.current.statusLabel
            : AppTheme.current.statusLabel.withAlphaComponent(0.4)
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
            self?.load(url: url)
        }
    }

    private func load(url: URL) {
        guard let image = NSImage(contentsOf: url) else {
            statusLabel.stringValue = "Failed to load \(url.lastPathComponent)."
            return
        }
        guard let cgImage = rasterize(image) else {
            statusLabel.stringValue = "Could not read pixel data from \(url.lastPathComponent)."
            return
        }

        sourceCGImage = cgImage
        sourceImageView.image = image
        statusLabel.stringValue = "Loaded: \(url.lastPathComponent) (\(cgImage.width)×\(cgImage.height) px)"
    }

    /// Produce a CGImage to convert from.
    ///
    /// Bitmap sources hand back their own pixels. Vector sources (SVG, PDF)
    /// report `pixelsWide == 0` and rasterise at their tiny intrinsic size, so
    /// they are re-rendered large enough that downscaling to 320×200 still has
    /// detail to work with.
    private func rasterize(_ image: NSImage) -> CGImage? {
        let pixelWidth = image.representations.map(\.pixelsWide).max() ?? 0
        if pixelWidth > 0 {
            return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        }

        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        // 4× the C64's visible area is plenty of detail without being wasteful.
        let scale = max(1280 / size.width, 800 / size.height)
        let pixelsWide = max(1, Int((size.width * scale).rounded()))
        let pixelsHigh = max(1, Int((size.height * scale).rounded()))

        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelsWide, pixelsHigh: pixelsHigh,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = size

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: size), from: .zero,
                   operation: .sourceOver, fraction: 1.0)
        return rep.cgImage
    }

    // MARK: - Convert

    @objc private func modeChanged(_ sender: Any?) {
        setBackgroundPickerEnabled(modeSelector.indexOfSelectedItem == 1)
        settingsChanged(sender)
    }

    @objc private func settingsChanged(_ sender: Any?) {
        guard sourceCGImage != nil else { return }
        conversionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.runConversion() }
        conversionWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    @objc private func resetSliders(_ sender: Any?) {
        brightnessSlider.doubleValue = 0
        contrastSlider.doubleValue = 0
        if sourceCGImage != nil { convertImage(sender) }
    }

    @objc private func convertImage(_ sender: Any?) {
        guard sourceCGImage != nil else {
            statusLabel.stringValue = "Load an image first."
            return
        }
        // Cancel any pending debounced work and convert immediately.
        conversionWorkItem?.cancel()
        conversionWorkItem = nil
        runConversion()
    }

    /// Shared conversion entry point for both the Convert button and the
    /// debounced settings path. Always called on the main thread; pixel
    /// extraction and quantization happen on a background queue.
    private func runConversion() {
        guard let cgImage = sourceCGImage else { return }

        let bgIndex = bgColorSelector.indexOfSelectedItem
        let isMultiColor = modeSelector.indexOfSelectedItem == 1
        let settings = ConversionSettings(
            multiColor:       isMultiColor,
            dither:           ditherSelector.indexOfSelectedItem,
            brightness:       brightnessSlider.doubleValue,
            contrast:         contrastSlider.doubleValue,
            scaleMode:        ScaleMode(rawValue: scaleSelector.indexOfSelectedItem) ?? .stretch,
            backdrop:         backdropSelector.indexOfSelectedItem == 1 ? (0, 0, 0) : (255, 255, 255),
            forcedBackground: (isMultiColor && bgIndex > 0) ? bgIndex - 1 : nil
        )

        // Anything already running is now stale.
        conversionToken?.cancel()
        let token = CancellationToken()
        conversionToken = token
        activeConversions += 1

        statusLabel.stringValue = "Converting…"
        spinner.startAnimation(nil)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bitmap = Self.performConversion(cgImage: cgImage, settings: settings,
                                                isCancelled: { token.isCancelled })

            DispatchQueue.main.async {
                guard let self else { return }
                self.activeConversions -= 1
                if self.activeConversions <= 0 { self.spinner.stopAnimation(nil) }
                // A newer conversion started while this one ran — drop the result.
                guard !token.isCancelled, let bitmap else { return }

                self.resultBitmap = bitmap
                self.resultImageView.image = Self.bitmapToNSImage(bitmap)
                let mode = settings.multiColor ? "multi-color" : "hi-res"
                let bg = settings.multiColor
                    ? " (background: \(C64Reference.colorPalette[Int(bitmap.backgroundColor)].name))"
                    : ""
                self.statusLabel.stringValue = "Converted to C64 \(mode) format\(bg)."
            }
        }
    }

    // MARK: - Conversion Engine

    /// Returns nil if the conversion was superseded before it finished.
    private static func performConversion(
        cgImage: CGImage,
        settings: ConversionSettings,
        isCancelled: () -> Bool
    ) -> C64Bitmap? {

        let targetW = settings.multiColor ? 160 : 320
        let targetH = 200

        let pixels = getScaledPixels(from: cgImage, width: targetW, height: targetH, settings: settings)

        let bitmap = C64Bitmap()
        bitmap.isMultiColor = settings.multiColor

        let cellPixelW = settings.multiColor ? 4 : 8
        let cellCols   = targetW / cellPixelW
        let cellRows   = targetH / 8
        let cellCount  = cellPixelW * 8

        // Gather each cell's pixels once. The previous version rebuilt these
        // arrays inside the 16-candidate background search and again in pass 1
        // — seventeen times over.
        var cells = [[RGB]](repeating: [], count: cellRows * cellCols)
        for cellRow in 0..<cellRows {
            for cellCol in 0..<cellCols {
                var cellPixels = [RGB]()
                cellPixels.reserveCapacity(cellCount)
                for py in 0..<8 {
                    let y = cellRow * 8 + py
                    for px in 0..<cellPixelW {
                        cellPixels.append(pixels[y * targetW + cellCol * cellPixelW + px])
                    }
                }
                cells[cellRow * cellCols + cellCol] = cellPixels
            }
        }

        // ── Multi-color global background ─────────────────────────────────────
        var globalBg = 0
        if settings.multiColor {
            if let forced = settings.forcedBackground {
                globalBg = forced
            } else {
                var bestBgError = Double.infinity
                for candidate in 0..<16 {
                    if isCancelled() { return nil }
                    var totalError = 0.0
                    for cellPixels in cells {
                        let palette = [candidate] + findBestColors(cellPixels, count: 3, excluding: candidate)
                        for pixel in cellPixels {
                            var minDist = Double.infinity
                            for c in palette {
                                let d = colorDistance(pixel, c64Color: c)
                                if d < minDist { minDist = d }
                            }
                            totalError += minDist
                        }
                    }
                    if totalError < bestBgError {
                        bestBgError = totalError
                        globalBg    = candidate
                    }
                }
            }
            bitmap.backgroundColor = UInt8(globalBg)
        }

        if isCancelled() { return nil }

        // -- Pass 1: choose per-cell palettes ----------------------------------
        //
        // Palette layout matches C64Bitmap pixel slot values directly:
        //   hi-res:      palette[0] = cell background (pixel 0)
        //                palette[1] = cell foreground (pixel 1)
        //   multi-color: palette[0] = global background ($D021, pixel 0)
        //                palette[1..3] = fg / cell bg / color RAM (pixels 1-3)
        // so closestPaletteIndex() returns the pixel value to store.
        var cellPalettes = [[Int]](repeating: [], count: cellRows * cellCols)

        for cellRow in 0..<cellRows {
            for cellCol in 0..<cellCols {
                let index = cellRow * cellCols + cellCol
                let cellPixels = cells[index]

                if settings.multiColor {
                    var cellColors = findBestColors(cellPixels, count: 3, excluding: globalBg)
                    // Pad short palettes with the background so slots 0-3 always
                    // exist and the exported screen/colour RAM never carries a
                    // leftover default for a slot the image does not use.
                    while cellColors.count < 3 { cellColors.append(globalBg) }

                    bitmap.cellForeground[cellRow][cellCol] = UInt8(cellColors[0])
                    bitmap.cellBackground[cellRow][cellCol] = UInt8(cellColors[1])
                    bitmap.cellColorRAM[cellRow][cellCol]   = UInt8(cellColors[2])
                    cellPalettes[index] = [globalBg] + cellColors
                } else {
                    var bestColors = findBestColors(cellPixels, count: 2)
                    // A cell that needs only one colour still has to fill both
                    // slots; reuse the one colour rather than an arbitrary white.
                    while bestColors.count < 2 { bestColors.append(bestColors.first ?? 0) }

                    bitmap.cellBackground[cellRow][cellCol] = UInt8(bestColors[0])
                    bitmap.cellForeground[cellRow][cellCol] = UInt8(bestColors[1])
                    cellPalettes[index] = bestColors
                }
            }
        }

        if isCancelled() { return nil }

        // -- Pass 2: assign pixels, scanline-major -----------------------------
        //
        // Floyd-Steinberg error diffusion REQUIRES scanline order: each
        // pixel's error flows right and down into neighbours that have not
        // been quantized yet. Palettes are already fixed by pass 1, so this
        // pass can walk the image row by row.

        // Bayer 4x4 ordered-dither matrix, normalised to -0.5...0.4375.
        let bayerMatrix: [[Double]] = [
            [-0.5,     0.0,    -0.375,   0.125 ],
            [ 0.25,   -0.25,    0.375,  -0.125 ],
            [-0.3125,  0.1875, -0.4375,  0.0625],
            [ 0.4375, -0.0625,  0.3125, -0.1875],
        ]
        // Neighbouring C64 palette entries sit 40-80 apart in each channel, so
        // the old ±8 swing was too small to break up a band. ±32 actually
        // dithers without swamping the image.
        let bayerAmplitude = 64.0

        // Rolling two-row error buffer: [0] = current row, [1] = next row.
        var fsError = Array(
            repeating: [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: targetW),
            count: 2
        )

        for y in 0..<targetH {
            let cellRow = y / 8

            for x in 0..<targetW {
                let palette = cellPalettes[cellRow * cellCols + x / cellPixelW]

                var rgb = pixels[y * targetW + x]

                if settings.dither == 1 {
                    // Floyd-Steinberg: apply accumulated error
                    rgb.r = max(0, min(255, rgb.r + fsError[0][x].r))
                    rgb.g = max(0, min(255, rgb.g + fsError[0][x].g))
                    rgb.b = max(0, min(255, rgb.b + fsError[0][x].b))
                } else if settings.dither == 2 {
                    let threshold = bayerMatrix[y % 4][x % 4] * bayerAmplitude
                    rgb.r = max(0, min(255, rgb.r + threshold))
                    rgb.g = max(0, min(255, rgb.g + threshold))
                    rgb.b = max(0, min(255, rgb.b + threshold))
                }

                let chosenIdx = closestPaletteIndex(rgb, from: palette)
                bitmap.pixels[y][x] = UInt8(chosenIdx)

                if settings.dither == 1 {
                    // Distribute quantization error to unvisited neighbours
                    let chosenRGB = c64PaletteRGB[palette[chosenIdx]]
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

            // Advance the rolling buffer at the end of each full scanline
            if settings.dither == 1 {
                fsError[0] = fsError[1]
                for i in 0..<targetW { fsError[1][i] = RGB(r: 0, g: 0, b: 0) }
            }
        }

        return bitmap
    }

    // MARK: - Pixel Extraction

    /// A single pixel's colour. A struct rather than a tuple so the pixel grid
    /// can live in one flat array instead of an array of arrays of tuples.
    private struct RGB {
        var r: Double
        var g: Double
        var b: Double
    }

    /// Renders `cgImage` into a `width`×`height` context, then reads back raw
    /// RGBA bytes and applies brightness/contrast. Returns a flat row-major
    /// grid of `width * height` pixels.
    private static func getScaledPixels(
        from cgImage: CGImage,
        width: Int,
        height: Int,
        settings: ConversionSettings
    ) -> [RGB] {

        let bytesPerPixel = 4
        let bytesPerRow   = width * bytesPerPixel
        var rawBytes      = [UInt8](repeating: 0, count: height * bytesPerRow)
        var pixels        = [RGB](repeating: RGB(r: 0, g: 0, b: 0), count: width * height)

        let drawn: Bool = rawBytes.withUnsafeMutableBytes { buffer -> Bool in
            // The context must be created, drawn into, and finished inside this
            // closure: passing `&rawBytes` straight to CGContext() would leave
            // the context holding a pointer that is only valid for that one call.
            guard let ctx = CGContext(
                data:             buffer.baseAddress,
                width:            width,
                height:           height,
                bitsPerComponent: 8,
                bytesPerRow:      bytesPerRow,
                space:            CGColorSpaceCreateDeviceRGB(),
                bitmapInfo:       CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }

            // Lay down the backdrop first so transparent pixels — and the bars
            // left by "Fit" — come out as a real colour instead of the black
            // that un-premultiplying zeroes would produce.
            ctx.setFillColor(red:   settings.backdrop.r / 255,
                             green: settings.backdrop.g / 255,
                             blue:  settings.backdrop.b / 255,
                             alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

            ctx.interpolationQuality = .high
            ctx.draw(cgImage, in: destinationRect(for: cgImage, width: width, height: height,
                                                 scaleMode: settings.scaleMode))
            return true
        }

        // Context creation failed — hand back a flat backdrop rather than crash.
        guard drawn else {
            return [RGB](repeating: RGB(r: settings.backdrop.r, g: settings.backdrop.g, b: settings.backdrop.b),
                         count: width * height)
        }

        let contrastFactor = (259.0 * (settings.contrast + 255.0)) / (255.0 * (259.0 - settings.contrast))

        for i in 0..<(width * height) {
            let offset = i * bytesPerPixel
            var r = Double(rawBytes[offset])
            var g = Double(rawBytes[offset + 1])
            var b = Double(rawBytes[offset + 2])
            let a = Double(rawBytes[offset + 3])

            // Un-premultiply alpha so brightness/contrast operate on the true
            // colour values. The opaque backdrop makes this a no-op in practice,
            // but it keeps the maths right if that ever changes.
            if a > 0, a < 255 {
                let invA = 255.0 / a
                r *= invA; g *= invA; b *= invA
            }

            // Apply brightness
            r += settings.brightness; g += settings.brightness; b += settings.brightness

            // Apply contrast (standard formula: C = (259*(K+255))/(255*(259-K)))
            r = contrastFactor * (r - 128) + 128
            g = contrastFactor * (g - 128) + 128
            b = contrastFactor * (b - 128) + 128

            pixels[i] = RGB(r: max(0, min(255, r)), g: max(0, min(255, g)), b: max(0, min(255, b)))
        }

        return pixels
    }

    /// Where to draw the source inside the target bitmap.
    ///
    /// Aspect ratio is worked out against the C64's 320×200 *visible* area and
    /// only then squashed into the target grid, because a multi-color pixel is
    /// twice as wide as it is tall — computing the fit directly against 160×200
    /// would letterbox to the wrong shape.
    private static func destinationRect(for cgImage: CGImage, width: Int, height: Int, scaleMode: ScaleMode) -> CGRect {
        let visualW = 320.0
        let visualH = 200.0
        let imageW  = Double(cgImage.width)
        let imageH  = Double(cgImage.height)

        var rect: CGRect
        switch scaleMode {
        case .stretch:
            rect = CGRect(x: 0, y: 0, width: visualW, height: visualH)
        case .fit, .fill:
            guard imageW > 0, imageH > 0 else {
                rect = CGRect(x: 0, y: 0, width: visualW, height: visualH)
                break
            }
            let scale = scaleMode == .fit
                ? min(visualW / imageW, visualH / imageH)
                : max(visualW / imageW, visualH / imageH)
            let w = imageW * scale
            let h = imageH * scale
            rect = CGRect(x: (visualW - w) / 2, y: (visualH - h) / 2, width: w, height: h)
        }

        // Squash horizontally into the target grid (a no-op in hi-res).
        let sx = Double(width) / visualW
        let sy = Double(height) / visualH
        return CGRect(x: rect.minX * sx, y: rect.minY * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }

    // MARK: - Color Matching

    /// Euclidean distance weighted by human perceptual sensitivity (ITU-R BT.601)
    private static func colorDistance(_ pixel: RGB, c64Color: Int) -> Double {
        let c  = c64PaletteRGB[c64Color]
        let dr = pixel.r - Double(c.r)
        let dg = pixel.g - Double(c.g)
        let db = pixel.b - Double(c.b)
        // Weighted distance (human eye is most sensitive to green)
        return dr * dr * 0.299 + dg * dg * 0.587 + db * db * 0.114
    }

    private static func closestPaletteIndex(_ pixel: RGB, from palette: [Int]) -> Int {
        var bestIdx  = 0
        var bestDist = Double.infinity
        for (i, colorIdx) in palette.enumerated() {
            let dist = colorDistance(pixel, c64Color: colorIdx)
            if dist < bestDist { bestDist = dist; bestIdx = i }
        }
        return bestIdx
    }

    /// Pick the `count` C64 palette entries that best represent a set of pixels,
    /// optionally on top of an `excluding` colour that is already available for
    /// free (the multi-color global background).
    ///
    /// Greedy residual-error minimisation: repeatedly take the colour that most
    /// reduces the total error of the pixels *as they currently stand*, then
    /// refine by swapping. The previous implementation seeded from the centroid
    /// of the whole cell — which for a black-and-white cell is grey, matching
    /// neither — and then discarded exactly the pixels its new colour served
    /// while keeping the ones already covered. In hi-res that emptied the
    /// working set after the first pick, so it always returned a single colour
    /// and every cell fell back to "cell average plus white".
    private static func findBestColors(_ pixels: [RGB], count: Int, excluding: Int? = nil) -> [Int] {
        guard !pixels.isEmpty, count > 0 else { return [] }

        let candidates = (0..<16).filter { $0 != excluding }
        guard !candidates.isEmpty else { return [] }

        // dist[pixel * 16 + colour] — every step below is a table lookup.
        var dist = [Double](repeating: 0, count: pixels.count * 16)
        for (i, pixel) in pixels.enumerated() {
            for c in 0..<16 { dist[i * 16 + c] = colorDistance(pixel, c64Color: c) }
        }

        /// Error of the whole cell under `set` (plus the free `excluding` colour).
        func totalError(_ set: [Int]) -> Double {
            var total = 0.0
            for i in 0..<pixels.count {
                var best = excluding.map { dist[i * 16 + $0] } ?? Double.infinity
                for c in set {
                    let d = dist[i * 16 + c]
                    if d < best { best = d }
                }
                total += best
            }
            return total
        }

        // Residual error per pixel under the colours chosen so far.
        var residual = [Double](repeating: .infinity, count: pixels.count)
        if let excluding {
            for i in 0..<pixels.count { residual[i] = dist[i * 16 + excluding] }
        }

        var chosen: [Int] = []
        while chosen.count < count {
            var bestColor = -1
            var bestError = Double.infinity
            for c in candidates where !chosen.contains(c) {
                var error = 0.0
                for i in 0..<pixels.count { error += min(residual[i], dist[i * 16 + c]) }
                if error < bestError { bestError = error; bestColor = c }
            }
            guard bestColor >= 0 else { break }
            chosen.append(bestColor)
            for i in 0..<pixels.count { residual[i] = min(residual[i], dist[i * 16 + bestColor]) }
        }

        // Local search: greedy can settle for a set a single swap improves on.
        var currentError = totalError(chosen)
        var improved = true
        var rounds = 0
        while improved && rounds < 4 {
            improved = false
            rounds += 1
            for slot in 0..<chosen.count {
                for c in candidates where !chosen.contains(c) {
                    var trial = chosen
                    trial[slot] = c
                    let error = totalError(trial)
                    if error < currentError - 1e-9 {
                        currentError = error
                        chosen = trial
                        improved = true
                    }
                }
            }
        }

        return chosen
    }

    // MARK: - Bitmap → NSImage

    private static func bitmapToNSImage(_ bitmap: C64Bitmap) -> NSImage {
        let w = 320
        let h = 200

        guard let rep = NSBitmapImageRep(
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
        ), let data = rep.bitmapData else {
            return NSImage(size: NSSize(width: w, height: h))
        }

        let rowBytes = rep.bytesPerRow
        for y in 0..<h {
            for x in 0..<w {
                let c      = c64PaletteRGB[min(Int(bitmap.displayColor(x: x, y: y)), 15)]
                let offset = y * rowBytes + x * 3
                data[offset]     = UInt8(c.r)
                data[offset + 1] = UInt8(c.g)
                data[offset + 2] = UInt8(c.b)
            }
        }

        let image = NSImage(size: NSSize(width: w, height: h))
        image.addRepresentation(rep)
        return image
    }

    // MARK: - Export

    /// The formats offered in the Export sheet, in menu order.
    private enum ExportFormat: Int, CaseIterable {
        case native = 0   // Koala (multi-color) or Art Studio (hi-res)
        case assembly
        case basic
        case prg

        func title(multiColor: Bool) -> String {
            switch self {
            case .native:   return multiColor ? "Koala Painter (.kla)" : "Art Studio (.art)"
            case .assembly: return "Assembly (.asm)"
            case .basic:    return "BASIC DATA (.bas)"
            case .prg:      return "PRG (.prg)"
            }
        }

        func fileExtension(multiColor: Bool) -> String {
            switch self {
            case .native:   return multiColor ? "kla" : "art"
            case .assembly: return "asm"
            case .basic:    return "bas"
            case .prg:      return "prg"
            }
        }
    }

    private var exportPanel: NSSavePanel?

    @objc private func exportResult(_ sender: Any?) {
        guard let bitmap = resultBitmap else {
            statusLabel.stringValue = "Convert an image first."
            return
        }

        let panel = NSSavePanel()
        let accessory = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        accessory.addItems(withTitles: ExportFormat.allCases.map { $0.title(multiColor: bitmap.isMultiColor) })
        // Keep the filename's extension in step with the chosen format —
        // picking "PRG" used to still save a file named "converted.art".
        accessory.target = self
        accessory.action = #selector(exportFormatChanged(_:))
        panel.accessoryView = accessory
        panel.nameFieldStringValue = "converted." + ExportFormat.native.fileExtension(multiColor: bitmap.isMultiColor)
        exportPanel = panel

        panel.begin { [weak self] response in
            guard let self else { return }
            self.exportPanel = nil
            guard response == .OK, let url = panel.url else { return }

            let format = ExportFormat(rawValue: accessory.indexOfSelectedItem) ?? .native
            var basicListingSize = 0
            do {
                switch format {
                case .native:
                    let data = bitmap.isMultiColor ? bitmap.exportKoala() : bitmap.exportArtStudio()
                    try data.write(to: url)
                case .assembly:
                    try bitmap.exportAsAssembly().write(to: url, atomically: true, encoding: .utf8)
                case .basic:
                    let listing = bitmap.exportAsBASIC()
                    try listing.write(to: url, atomically: true, encoding: .utf8)
                    basicListingSize = C64Bitmap.tokenizedProgramSize(of: listing)
                case .prg:
                    try bitmap.exportAsPRG().write(to: url)
                }
            } catch {
                self.statusLabel.stringValue = "Export failed: \(error.localizedDescription)"
                self.presentError(error, title: "Could not export the image.")
                return
            }

            // A full-screen bitmap does not always fit in DATA statements. Say
            // so rather than handing over a listing that will not load.
            if format == .basic, basicListingSize > C64Bitmap.basicSizeBudget {
                self.statusLabel.stringValue =
                    "Exported \(url.lastPathComponent) — but at ~\(basicListingSize) bytes it will not leave "
                    + "room to run in a C64's \(C64Bitmap.c64BasicRAM) bytes of BASIC RAM. Use the PRG export."
                return
            }
            self.statusLabel.stringValue = "Exported to \(url.lastPathComponent)"
        }
    }

    @objc private func exportFormatChanged(_ sender: NSPopUpButton) {
        guard let panel = exportPanel, let bitmap = resultBitmap else { return }
        let format = ExportFormat(rawValue: sender.indexOfSelectedItem) ?? .native
        let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
        let name = base.isEmpty ? "converted" : base
        panel.nameFieldStringValue = name + "." + format.fileExtension(multiColor: bitmap.isMultiColor)
    }

    // MARK: - Save to D64

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
        guard let d64Type = UTType(filenameExtension: "d64") else {
            statusLabel.stringValue = "Could not determine the .d64 file type."
            return
        }

        if response == .alertFirstButtonReturn {
            let panel = NSSavePanel()
            panel.allowedContentTypes  = [d64Type]
            panel.nameFieldStringValue = "converted.d64"
            panel.begin { [weak self] saveResponse in
                guard let self, saveResponse == .OK, let url = panel.url else { return }
                let disk = D64Image(diskName: "CONVERTED", diskID: "CV")
                guard disk.writeFile(name: filename, data: Array(data)) else {
                    self.report(failure: "Could not write \(filename) to the new disk image.")
                    return
                }
                do {
                    try disk.save(to: url)
                    self.statusLabel.stringValue = "Saved \(filename) to \(url.lastPathComponent)"
                } catch {
                    self.statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
                    self.presentError(error, title: "Could not save the disk image.")
                }
            }
        } else {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [d64Type]
            panel.begin { [weak self] openResponse in
                guard let self, openResponse == .OK, let url = panel.url else { return }
                let disk: D64Image
                do {
                    disk = try D64Image(contentsOf: url)
                } catch {
                    self.statusLabel.stringValue = "Could not open \(url.lastPathComponent): \(error.localizedDescription)"
                    self.presentError(error, title: "Could not open the disk image.")
                    return
                }
                guard disk.writeFile(name: filename, data: Array(data)) else {
                    self.report(failure: "Could not write \(filename) — the disk may be full.")
                    return
                }
                do {
                    try disk.save()
                    self.statusLabel.stringValue = "Saved \(filename) to \(url.lastPathComponent)"
                } catch {
                    self.statusLabel.stringValue = "Save failed: \(error.localizedDescription)"
                    self.presentError(error, title: "Could not save the disk image.")
                }
            }
        }
    }

    // MARK: - Send to Graphics Editor

    @objc private func sendToEditor(_ sender: Any?) {
        guard let bitmap = resultBitmap else {
            statusLabel.stringValue = "Convert an image first."
            return
        }
        guard let appDelegate = NSApp.delegate as? AppDelegate else { return }

        let data = bitmap.isMultiColor ? bitmap.exportKoala() : bitmap.exportArtStudio()
        if appDelegate.openGfxEditorWith(imageData: data, multiColor: bitmap.isMultiColor) {
            statusLabel.stringValue = "Sent the converted image to the Graphics Editor."
        }
    }

    // MARK: - Error Reporting

    private func report(failure message: String) {
        statusLabel.stringValue = message
        let alert = NSAlert()
        alert.messageText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }

    private func presentError(_ error: Error, title: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = view.window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}
