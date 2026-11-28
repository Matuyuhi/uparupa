import CUpaaCore
import Metal

/// Draws one terminal frame with Metal. Zig writes the cell data directly into the Metal buffer.
final class Renderer {
    enum SetupError: Error {
        case font
        case metal(String)
    }

    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    let device: MTLDevice
    /// Size of one cell (pixels).
    private(set) var cellSize: (width: Int, height: Int)
    private var underline: SIMD2<Float>
    private let scale: Double
    /// Margin around the grid (pixels). x is left and right, y is top and bottom.
    private(set) var padding: (top: Int, bottom: Int, horizontal: Int)
    private let topPadding: Int
    /// Pixels kept free above the text on top of the margin, for chrome that floats over the terminal.
    /// The background still fills them.
    var extraTop = 0 {
        didSet { padding.top = topPadding + extraTop }
    }

    /// Margin around the grid (points). The left, right, and bottom margins keep the text from being clipped by the window's rounded corners.
    /// The top margin is smaller because the title bar keeps the text away from the rounded corners.
    static let paddingPoints = (top: 2.0, bottom: 16.0, horizontal: 8.0)

    private let handle: OpaquePointer
    private let backgroundPipeline: MTLRenderPipelineState
    private let glyphPipeline: MTLRenderPipelineState
    private let atlasTexture: MTLTexture
    private var atlasGeneration: UInt64 = 0
    private var cellBuffer: MTLBuffer?
    /// Seconds after the last draw until it should be drawn again (the mascot changes, or the find bar's search has
    /// more of the scrollback to go through), or nil if nothing waits on it.
    private(set) var redrawDelay: TimeInterval?

    /// How much of the default background color covers what is behind the view (0 to 1).
    let backgroundOpacity: Double
    /// Whether the axolotl is drawn behind the text. Turning it on plays its greeting.
    var mascot: Bool {
        didSet { upaa_renderer_set_mascot(handle, mascot) }
    }

    /// fontName is the font, then its fallbacks, one per line. fontSize is in points; scale is the screen scale factor
    /// (2 on Retina). mascot draws the axolotl behind the text.
    init(device: MTLDevice, fontName: String, fontSize: Double, scale: Double, mascot: Bool = false,
         backgroundOpacity: Double = 1) throws {
        guard let handle = upaa_renderer_new(fontName, fontSize * scale, mascot) else { throw SetupError.font }
        self.handle = handle
        self.device = device
        self.scale = scale
        self.backgroundOpacity = backgroundOpacity
        self.mascot = mascot
        let metrics = upaa_renderer_metrics(handle)
        cellSize = (Int(metrics.cell_width), Int(metrics.cell_height))
        underline = SIMD2(Float(metrics.underline_offset), Float(metrics.underline_thickness))
        let points = Renderer.paddingPoints
        padding = (
            Int((points.top * scale).rounded()), Int((points.bottom * scale).rounded()),
            Int((points.horizontal * scale).rounded()))
        topPadding = padding.top

        let library: MTLLibrary
        do {
            library = try device.makeDefaultLibrary(bundle: .main)
        } catch {
            upaa_renderer_free(handle)
            throw SetupError.metal("failed to read default.metallib: \(error)")
        }

        func pipeline(_ name: String, blending: Bool) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "\(name)_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "\(name)_fragment")
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = Renderer.pixelFormat
            if blending {
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }

        let atlasSize = Int(upaa_renderer_atlas_size())
        let atlasDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: atlasSize, height: atlasSize, mipmapped: false)
        do {
            backgroundPipeline = try pipeline("background", blending: false)
            glyphPipeline = try pipeline("glyph", blending: true)
            guard let texture = device.makeTexture(descriptor: atlasDescriptor) else {
                throw SetupError.metal("failed to create atlas texture")
            }
            atlasTexture = texture
        } catch {
            upaa_renderer_free(handle)
            throw error
        }
    }

    deinit {
        upaa_renderer_free(handle)
    }

    /// Changes the font (names and size as for init). Returns false, keeping the old font, if it cannot be found.
    func setFont(name: String, size: Double) -> Bool {
        guard upaa_renderer_set_font(handle, name, size * scale) else { return false }
        let metrics = upaa_renderer_metrics(handle)
        cellSize = (Int(metrics.cell_width), Int(metrics.cell_height))
        underline = SIMD2(Float(metrics.underline_offset), Float(metrics.underline_thickness))
        return true
    }

    /// Number of columns and rows that fit in a drawing target of size size (pixels).
    func gridSize(for size: (width: Int, height: Int)) -> (cols: Int, rows: Int) {
        (
            max(1, (size.width - 2 * padding.horizontal) / cellSize.width),
            max(1, (size.height - padding.top - padding.bottom) / cellSize.height)
        )
    }

    /// Size of the drawing target (pixels) that fits a cols x rows grid exactly.
    func pixelSize(cols: Int, rows: Int) -> (width: Int, height: Int) {
        (cols * cellSize.width + 2 * padding.horizontal, rows * cellSize.height + padding.top + padding.bottom)
    }

    /// Draws the session's current screen into the pass's drawing target. viewport is the size of the drawing target (pixels).
    /// preedit is the text being composed with IME (empty if none).
    /// Returns the cursor cell (nil if the cursor is hidden or nothing was drawn).
    @discardableResult
    func draw(
        session: TerminalSession,
        preedit: String = "",
        commandBuffer: MTLCommandBuffer,
        pass: MTLRenderPassDescriptor,
        viewport: (width: Int, height: Int)
    ) -> (col: Int, row: Int)? {
        // Allocate room for every cell that could fit in the drawing target, including cells that extend past the edges.
        let capacity = (viewport.width / cellSize.width + 1) * (viewport.height / cellSize.height + 1)
        let stride = MemoryLayout<UpaaCell>.stride
        if cellBuffer == nil || cellBuffer!.length < capacity * stride {
            cellBuffer = device.makeBuffer(length: capacity * stride, options: .storageModeShared)
        }
        guard let cellBuffer else { return nil }

        let cells = cellBuffer.contents().bindMemory(to: UpaaCell.self, capacity: capacity)
        let preeditBytes = Array(preedit.utf8)
        let frame = upaa_renderer_frame(handle, session.handle, preeditBytes, preeditBytes.count, cells, capacity)
        uploadAtlasIfNeeded(generation: frame.atlas_generation)
        redrawDelay = frame.searching ? 1.0 / 60 : frame.mascot_next_ms > 0 ? Double(frame.mascot_next_ms) / 1000 : nil

        // Colors are premultiplied by alpha, as Core Animation composites them.
        let bg = frame.background
        let alpha = backgroundOpacity
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(bg.0) / 255 * alpha, green: Double(bg.1) / 255 * alpha, blue: Double(bg.2) / 255 * alpha, alpha: alpha)
        pass.colorAttachments[0].loadAction = .clear
        let cursor = frame.cursor_visible ? (col: Int(frame.cursor_col), row: Int(frame.cursor_row)) : nil
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return cursor }
        defer { encoder.endEncoding() }
        guard frame.cell_count > 0 else { return cursor }

        var uniforms = Uniforms(
            viewport: SIMD2(Float(viewport.width), Float(viewport.height)),
            cell: SIMD2(Float(cellSize.width), Float(cellSize.height)),
            atlas: SIMD2(repeating: Float(atlasTexture.width)),
            origin: SIMD2(Float(padding.horizontal), Float(padding.top)),
            underline: underline,
            background: SIMD4(Float(bg.0) / 255, Float(bg.1) / 255, Float(bg.2) / 255, Float(alpha)))
        encoder.setVertexBuffer(cellBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 1)
        encoder.setFragmentTexture(atlasTexture, index: 0)

        let count = Int(frame.cell_count)
        encoder.setRenderPipelineState(backgroundPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        encoder.setRenderPipelineState(glyphPipeline)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        return cursor
    }

    /// Notice drawn above the mascot (e.g. an update is available).
    func setNote(_ text: String) {
        upaa_renderer_set_note(handle, text)
    }

    /// Something happened in the view, so the mascot's idle loop goes on for a while longer before it rests.
    func wakeMascot() {
        upaa_renderer_wake_mascot(handle)
    }

    /// Plays the mascot's greeting again if the point (drawable pixels from the top-left) is on it. Returns whether it was.
    @discardableResult
    func pokeMascot(x: Double, y: Double) -> Bool {
        let col = ((x - Double(padding.horizontal)) / Double(cellSize.width)).rounded(.down)
        let row = ((y - Double(padding.top)) / Double(cellSize.height)).rounded(.down)
        return upaa_renderer_poke_mascot(handle, Int32(col), Int32(row))
    }

    private func uploadAtlasIfNeeded(generation: UInt64) {
        guard generation != atlasGeneration else { return }
        atlasGeneration = generation
        let size = atlasTexture.width
        atlasTexture.replace(
            region: MTLRegionMake2D(0, 0, size, size),
            mipmapLevel: 0,
            withBytes: upaa_renderer_atlas_pixels(handle),
            bytesPerRow: size)
    }

    /// Same layout as Uniforms in Shaders/terminal.metal.
    private struct Uniforms {
        var viewport: SIMD2<Float>
        var cell: SIMD2<Float>
        var atlas: SIMD2<Float>
        var origin: SIMD2<Float>
        var underline: SIMD2<Float>
        var background: SIMD4<Float>
    }
}
