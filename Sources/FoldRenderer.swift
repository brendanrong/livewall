import AppKit
import CoreVideo
import Metal
import MetalKit
import QuartzCore

/// Layout mirrors `FoldUniforms` in the shader: two float2, then ten floats. 56 bytes.
struct FoldUniforms {
    var imageSize = SIMD2<Float>(1, 1)
    var cover = SIMD2<Float>(1, 1)
    var aspect: Float = 1
    var turn: Float = 0
    var blurStrength: Float = 0.5
    var reflection: Float = 1
    var sampleCount: Float = 32
    var motionBoost: Float = 0
    var sideVoid: Float = 0
    var finalClose: Float = 1
    var bend: Float = 0        // radians, the real angle the glass has closed through (capped)
    var eye: Float = 2.5       // viewer distance in screen heights
}

private struct PyramidParams {
    var srcTexel: SIMD2<Float>
    var srcLod: Float
    var pad: Float = 0
}

/// Metal view that draws one frozen frame folded by `targetTurn`.
///
/// The fold is an inverse mapping in the fragment shader: the frozen picture stays in the plane
/// of the open lid and the glass rotates about the bottom edge toward the viewer; each screen
/// pixel looks up the picture point behind it. Nothing is drawn as a rotated rectangle, so there
/// is no trapezoid and, with `sideVoid` at 0, no side gaps.
///
/// `targetTurn` is written on the main thread per sensor tick. The exponential follow filter runs
/// here, once per displayed frame at the panel's native rate, so sensor jitter never reaches the
/// geometry directly.
final class FoldRenderer: MTKView, MTKViewDelegate {
    /// Linear turn, 0 at the start angle and 1 at the end angle. Eased here; shaped for the shader in draw().
    var targetTurn: Float = 0
    /// Degrees between the start and end angles, so displayed turn converts back to real degrees of bend.
    var rangeDegrees: Float = 107
    var followSpeed: Double = 16
    var blurStrength: Float = 0.5
    var motionBoost: Float = 0
    var finalClose: Float = 1
    /// Main thread, after every drawn frame, with the frame's timestamp.
    var onFrame: ((CFTimeInterval) -> Void)?
    /// Main thread, when a frame handed to `setFrame` is on the GPU and drawable.
    var onFrameReady: (() -> Void)?
    private(set) var displayedTurn: Float = 0
    var hasFrame: Bool { frozen != nil }

    /// Front-load the frost and void: 20% of the travel gives 36%. 1 = linear. Geometry is not
    /// affected; the bend always tracks the real lid angle.
    static let frontLoad: Float = 2
    /// The bend follows the lid degree for degree up to here. Past about 80 the plane is edge-on
    /// to the viewer and the projection degenerates, so the close-to-black covers the rest.
    static let maxBendDegrees: Float = 75
    /// Viewer distance in screen heights at 100 percent intensity. A 16-inch panel is about 21 cm
    /// tall; 2.5 is arm's length. Lower intensity multiplies this up to 1.64x (see draw).
    static let eyeDistance: Float = 2.5
    /// Horizontal part of the projection. 1 = physical: the picture narrows toward the top as the
    /// glass comes closer to the eye, which is what makes it read as staying put in space. 0 keeps
    /// the frame at full width (v2 first cut; the fold then reads as rotating with the lid).
    static let sideVoid: Float = 1
    static let reflection: Float = 1
    private static let mipLevels = 6

    private let queue: MTLCommandQueue
    private let foldPipeline: MTLRenderPipelineState
    private let pyramidPipeline: MTLRenderPipelineState
    private let sampler: MTLSamplerState
    private let uploadQueue = DispatchQueue(label: "com.brendan.livewall.fold-upload", qos: .userInteractive)
    private var textureCache: CVMetalTextureCache?
    private var frozen: MTLTexture?   // named to avoid NSView.frame
    private var frameSize = SIMD2<Float>(1, 1)
    private var generation: UInt64 = 0
    private var lastDrawTime: CFTimeInterval = 0
    private var easedBoost: Float = 0
    private var seededTurn: Float?
    private var taps: Float = 12

    /// `init?(frame:)` would collide with NSView's non-failable init(frame:), hence `size`.
    init?(size: CGSize) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let pipelines = Self.makePipelines(device),
              let sampler = Self.makeSampler(device) else { return nil }
        self.queue = queue
        foldPipeline = pipelines.fold
        pyramidPipeline = pipelines.pyramid
        self.sampler = sampler
        super.init(frame: CGRect(origin: .zero, size: size), device: device)
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0.003, green: 0.004, blue: 0.005, alpha: 1)
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = true
        autoresizingMask = [.width, .height]
        delegate = self
    }

    required init(coder: NSCoder) { fatalError("FoldRenderer is created in code") }

    // MARK: - Control

    /// Draw at the panel's native rate (120 Hz on ProMotion).
    func resume(on screen: NSScreen?) {
        preferredFramesPerSecond = min(120, max(30, screen?.maximumFramesPerSecond ?? 60))
        isPaused = false
    }

    /// Stop drawing. The first frame after the next resume snaps to the target instead of easing across the gap.
    func suspend() {
        isPaused = true
        lastDrawTime = 0
        seededTurn = nil
    }

    /// The first frame after the next resume starts from `turn` and grows into the target.
    func seed(turn: Float) { seededTurn = turn }

    /// Upload one captured frame (IOSurface-backed BGRA) and build its blur pyramid.
    /// `onFrameReady` fires on the main thread when it can be drawn. Newer uploads win.
    func setFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let device = device else { return }
        generation &+= 1
        let gen = generation
        uploadQueue.async { [weak self] in
            guard let self = self else { return }
            if self.textureCache == nil {
                CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &self.textureCache)
            }
            let width = CVPixelBufferGetWidth(pixelBuffer)
            let height = CVPixelBufferGetHeight(pixelBuffer)
            var cvTexture: CVMetalTexture?
            guard let cache = self.textureCache,
                  CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, cache, pixelBuffer, nil,
                                                            .bgra8Unorm, width, height, 0, &cvTexture) == kCVReturnSuccess,
                  let keeper = cvTexture,
                  let source = CVMetalTextureGetTexture(keeper) else { return }
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            desc.mipmapLevelCount = Self.mipLevels
            desc.usage = [.shaderRead, .renderTarget]
            desc.storageMode = .private
            guard let texture = device.makeTexture(descriptor: desc),
                  let cb = self.queue.makeCommandBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return }
            blit.copy(from: source, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                      sourceSize: MTLSize(width: width, height: height, depth: 1),
                      to: texture, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
            blit.endEncoding()
            self.encodePyramid(texture, on: cb)
            cb.addCompletedHandler { [weak self] _ in
                withExtendedLifetime((keeper, pixelBuffer)) {}   // the source mapping must outlive the GPU copy
                DispatchQueue.main.async {
                    guard let self = self, self.generation == gen else { return }
                    self.frameSize = SIMD2<Float>(Float(width), Float(height))
                    self.frozen = texture
                    self.onFrameReady?()
                }
            }
            cb.commit()
        }
    }

    /// Drop the frozen frame (about 40 MB at native Retina) and any upload still in flight.
    func discardFrame() {
        generation &+= 1
        frozen = nil
        uploadQueue.async { [weak self] in
            if let cache = self?.textureCache { CVMetalTextureCacheFlush(cache, 0) }
        }
    }

    // MARK: - Pyramid

    /// Level k+1 = binomial 3x3 of level k at half size, so mip k is a true Gaussian of sigma about
    /// 1.2 * 2^k texels. Five small passes, once per frozen frame, never per drawn frame.
    private func encodePyramid(_ texture: MTLTexture, on cb: MTLCommandBuffer) {
        for level in 1..<Self.mipLevels {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].level = level
            pass.colorAttachments[0].loadAction = .dontCare
            pass.colorAttachments[0].storeAction = .store
            guard let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }
            let sourceWidth = max(1, texture.width >> (level - 1))
            let sourceHeight = max(1, texture.height >> (level - 1))
            var params = PyramidParams(srcTexel: SIMD2<Float>(1 / Float(sourceWidth), 1 / Float(sourceHeight)),
                                       srcLod: Float(level - 1))
            enc.setRenderPipelineState(pyramidPipeline)
            enc.setFragmentTexture(texture, index: 0)
            enc.setFragmentSamplerState(sampler, index: 0)
            enc.setFragmentBytes(&params, length: MemoryLayout<PyramidParams>.stride, index: 0)
            enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            enc.endEncoding()
        }
    }

    // MARK: - Drawing

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        let now = CACurrentMediaTime()
        defer { onFrame?(now) }
        guard let frozen = frozen,
              let drawable = currentDrawable,
              let pass = currentRenderPassDescriptor,
              let cb = queue.makeCommandBuffer(),
              let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return }

        // Render-rate easing: one exponential step per displayed frame with the real frame dt.
        if lastDrawTime <= 0 {
            displayedTurn = seededTurn ?? targetTurn
            seededTurn = nil
            easedBoost = motionBoost
            taps = Self.baseTaps(displayedTurn)
        } else {
            let dt = min(max(now - lastDrawTime, 0), 0.1)
            if dt > 0 {
                displayedTurn += (targetTurn - displayedTurn) * Float(1 - exp(-dt * followSpeed))
                if abs(targetTurn - displayedTurn) < 0.0005 { displayedTurn = targetTurn }
                easedBoost += (motionBoost - easedBoost) * Float(1 - exp(-dt * 12.5))   // tau about 80 ms
            }
        }
        lastDrawTime = now

        let size = drawableSize
        let aspect = Float(size.width / max(1, size.height))
        let imageAspect = frameSize.x / max(1, frameSize.y)
        var u = FoldUniforms()
        u.imageSize = frameSize
        u.cover = SIMD2<Float>(min(1, aspect / imageAspect), min(1, imageAspect / aspect))
        u.aspect = aspect
        u.turn = Self.shaped(displayedTurn)
        u.bend = min(displayedTurn * rangeDegrees, Self.maxBendDegrees) * .pi / 180
        // Intensity pulls the eye back: at 20 percent the perspective is a lot gentler, at 100 it is
        // the measured 2.5 screen heights. The picture still tracks the lid degree for degree.
        u.eye = Self.eyeDistance * (1.8 - 0.8 * min(max(blurStrength, 0.2), 1))
        u.blurStrength = blurStrength
        u.reflection = Self.reflection
        u.sampleCount = adaptiveTaps(displayedTurn)
        u.motionBoost = easedBoost
        u.sideVoid = Self.sideVoid
        u.finalClose = finalClose

        enc.setRenderPipelineState(foldPipeline)
        enc.setFragmentTexture(frozen, index: 0)
        enc.setFragmentSamplerState(sampler, index: 0)
        enc.setFragmentBytes(&u, length: MemoryLayout<FoldUniforms>.stride, index: 0)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        enc.endEncoding()
        cb.present(drawable)
        cb.commit()
    }

    private static func shaped(_ t: Float) -> Float {
        let c = min(max(t, 0), 1)
        return 1 - pow(1 - c, frontLoad)
    }

    private static func baseTaps(_ turn: Float) -> Float { turn < 0.2 ? 12 : (turn < 0.6 ? 20 : 32) }

    /// Tap count with hysteresis, so a turn hovering at a boundary does not change blur character every frame.
    private func adaptiveTaps(_ turn: Float) -> Float {
        if taps <= 12 {
            if turn >= 0.6 { taps = 32 } else if turn >= 0.2 { taps = 20 }
        } else if taps <= 20 {
            if turn >= 0.6 { taps = 32 } else if turn < 0.16 { taps = 12 }
        } else if turn < 0.56 {
            taps = turn < 0.16 ? 12 : 20
        }
        return taps
    }

    // MARK: - Setup helpers

    private static func makePipelines(_ device: MTLDevice) -> (fold: MTLRenderPipelineState, pyramid: MTLRenderPipelineState)? {
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            guard let vertex = library.makeFunction(name: "foldVertex"),
                  let fold = library.makeFunction(name: "foldFragment"),
                  let pyramid = library.makeFunction(name: "pyramidFragment") else { return nil }
            let foldDesc = MTLRenderPipelineDescriptor()
            foldDesc.vertexFunction = vertex
            foldDesc.fragmentFunction = fold
            foldDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            let pyramidDesc = MTLRenderPipelineDescriptor()
            pyramidDesc.vertexFunction = vertex
            pyramidDesc.fragmentFunction = pyramid
            pyramidDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
            return (try device.makeRenderPipelineState(descriptor: foldDesc),
                    try device.makeRenderPipelineState(descriptor: pyramidDesc))
        } catch {
            NSLog("LiveWall hinge: shader build failed: %@", error.localizedDescription)
            return nil
        }
    }

    private static func makeSampler(_ device: MTLDevice) -> MTLSamplerState? {
        let d = MTLSamplerDescriptor()
        d.minFilter = .linear
        d.magFilter = .linear
        d.mipFilter = .linear
        d.sAddressMode = .clampToEdge
        d.tAddressMode = .clampToEdge
        return device.makeSamplerState(descriptor: d)
    }

    // MARK: - Shader (compiled at runtime; build.sh has no Metal step)

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    constant float3 kVoid = float3(0.003, 0.004, 0.005);

    struct FoldUniforms {
        float2 imageSize;
        float2 cover;
        float aspect;
        float turn;
        float blurStrength;
        float reflection;
        float sampleCount;
        float motionBoost;
        float sideVoid;
        float finalClose;
        float bend;
        float eye;
    };

    struct PyramidParams {
        float2 srcTexel;
        float srcLod;
        float pad;
    };

    struct Varyings {
        float4 position [[position]];
        float2 uv;
    };

    vertex Varyings foldVertex(uint vid [[vertex_id]]) {
        const float2 corners[6] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(-1, 1), float2(1, -1), float2(1, 1) };
        Varyings out;
        float2 p = corners[vid];
        out.position = float4(p, 0, 1);
        out.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);   // (0,0) top left; the hinge runs along uv.y = 1
        return out;
    }

    // One pyramid level: binomial 3x3 of the level above.
    fragment float4 pyramidFragment(Varyings in [[stage_in]],
                                    texture2d<float> tex [[texture(0)]],
                                    sampler s [[sampler(0)]],
                                    constant PyramidParams &p [[buffer(0)]]) {
        float2 t = p.srcTexel;
        float lod = p.srcLod;
        float3 acc = tex.sample(s, in.uv, level(lod)).rgb * 4.0;
        acc += (tex.sample(s, in.uv + float2( t.x, 0.0), level(lod)).rgb
              + tex.sample(s, in.uv + float2(-t.x, 0.0), level(lod)).rgb
              + tex.sample(s, in.uv + float2(0.0,  t.y), level(lod)).rgb
              + tex.sample(s, in.uv + float2(0.0, -t.y), level(lod)).rgb) * 2.0;
        acc += tex.sample(s, in.uv + float2( t.x,  t.y), level(lod)).rgb
             + tex.sample(s, in.uv + float2(-t.x,  t.y), level(lod)).rgb
             + tex.sample(s, in.uv + float2( t.x, -t.y), level(lod)).rgb
             + tex.sample(s, in.uv + float2(-t.x, -t.y), level(lod)).rgb;
        return float4(acc / 16.0, 1.0);
    }

    // Gaussian of any radius: the pyramid level whose sigma matches, polished by a small Vogel disc
    // at that level's texel scale. The disc never grows with radius, so no ghost copies of bright text.
    inline float3 gaussianSample(texture2d<float> tex, sampler s, float2 uv, float radius,
                                 float2 cover, float2 uiPixel, float2 screenPos, int taps) {
        float2 tuv = (uv - 0.5) * cover + 0.5;
        if (radius <= 0.15) {
            return tex.sample(s, tuv, level(0.0)).rgb;
        }
        float lod = clamp(log2(max(1.0, radius * 0.25)), 0.0, 5.0);
        float2 mipTexel = uiPixel * 0.5 * exp2(lod);
        float jitter = (fract(sin(dot(screenPos, float2(12.9898, 78.233))) * 43758.5453) - 0.5) * 0.12;
        float cj = cos(jitter);
        float sj = sin(jitter);
        int n = clamp(taps, 4, 32);
        float3 acc = float3(0.0);
        float wsum = 0.0;
        for (int i = 0; i < 32; i++) {
            if (i >= n) { break; }
            float fi = float(i);
            float theta = fi * 2.39996323;
            float r = sqrt((fi + 0.5) / float(n));
            float2 d = float2(cos(theta), sin(theta));
            d = float2(d.x * cj - d.y * sj, d.x * sj + d.y * cj);
            float w = exp(-2.3 * r * r);
            acc += tex.sample(s, clamp(tuv + d * (r * 1.2 * mipTexel), 0.0, 1.0), level(lod)).rgb * w;
            wsum += w;
        }
        float3 sharp = tex.sample(s, tuv, level(0.0)).rgb;
        return mix(sharp, acc / wsum, smoothstep(0.0, 2.0, radius));
    }

    fragment float4 foldFragment(Varyings in [[stage_in]],
                                 texture2d<float> tex [[texture(0)]],
                                 sampler s [[sampler(0)]],
                                 constant FoldUniforms &u [[buffer(0)]]) {
        float turn = clamp(u.turn, 0.0, 1.0);
        float2 uiPixel = 2.0 / max(float2(1.0), u.imageSize);   // two texels per point at native Retina
        int taps = int(clamp(u.sampleCount, 4.0, 32.0));
        if (turn <= 0.00001) {
            return float4(gaussianSample(tex, s, in.uv, 0.0, u.cover, uiPixel, in.position.xy, taps), 1.0);
        }

        // Inverse mapping. The frozen picture stays in the plane of the open lid; the glass rotates
        // about the bottom edge toward the viewer. For each screen pixel, find the picture point behind it.
        // Units are screen heights. The glass row at fromHinge sits fromHinge*sin(bend) closer to the
        // eye than the picture plane; the ray from the eye through it meets the picture plane at
        // fromHinge*cos(bend) scaled by eye/(eye - depth). Hinge row fixed; top rows compress and
        // narrow. Real geometry, no fudge: the bend is the degrees the lid has actually closed.
        float fromHinge = clamp(1.0 - in.uv.y, 0.0, 1.0);
        float bend = clamp(u.bend, 0.0, 1.5);
        float c = cos(bend);
        float sn = sin(bend);
        float eye = max(1.0, u.eye);
        float depth = fromHinge * sn;
        float persp = eye / max(0.05, eye - depth);
        float2 plane;
        plane.y = 1.0 - fromHinge * c * persp;
        float spread = 1.0 + (persp - 1.0) * clamp(u.sideVoid, 0.0, 2.0);   // 0: full width, no side void
        plane.x = 0.5 + (in.uv.x - 0.5) * spread;

        // Depth-weighted defocus: sharp at the hinge, frosted at the top. Lid speed adds a little more.
        float spreadUp = pow(smoothstep(0.0, 0.85, fromHinge), 1.2);
        float focus = smoothstep(0.0, 1.0, turn) * mix(0.20, 1.0, spreadUp);
        float radius = 56.0 * focus * max(0.05, u.blurStrength) + clamp(u.motionBoost, 0.0, 24.0) * spreadUp;

        float mask = 1.0;
        if (u.sideVoid > 0.001) {
            float soft = fwidth(in.uv.x) + radius * 0.002;
            mask = 1.0 - smoothstep(0.5 - soft, 0.5 + soft, abs(plane.x - 0.5));
        }
        float3 color = gaussianSample(tex, s, plane, radius, u.cover, uiPixel, in.position.xy, taps);

        // Glass at a grazing angle: darker toward the top, a soft specular band two thirds up, a thin line at the hinge.
        color *= 1.0 - 0.20 * clamp(u.blurStrength, 0.2, 1.0) * sn * pow(fromHinge, 1.5);
        color += float3(0.82, 0.85, 0.86) * exp(-pow((fromHinge - 0.65) / 0.35, 2.0)) * sn * 0.025 * u.reflection;
        color += float3(0.90, 0.93, 0.95) * exp(-pow(fromHinge / 0.06, 2.0)) * sn * 0.035;

        // Into the void: the top darkens with turn, up to 80 percent at full intensity (40 at the
        // minimum); the last tenth of the turn closes to black regardless.
        float k = clamp(u.blurStrength, 0.2, 1.0);
        float voidAmount = pow(turn, 1.1) * clamp((fromHinge - 0.20) / 0.80, 0.0, 1.0);
        color *= 1.0 - 0.80 * mix(0.5, 1.0, k) * voidAmount;
        float close = mix(1.0, 1.0 - smoothstep(0.90, 1.0, turn), u.finalClose);
        color *= close;
        return float4(mix(kVoid, color, mask * close), 1.0);
    }
    """
}
