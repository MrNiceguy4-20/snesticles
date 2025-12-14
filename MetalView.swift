import MetalKit
import SwiftUI

struct MetalView: NSViewRepresentable {
    let renderer: MetalRenderer
    func makeNSView(context: Context) -> MTKView {
        let v = MTKView()
        v.device = renderer.device
        v.delegate = renderer
        v.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        v.framebufferOnly = false
        // Drive rendering via setNeedsDisplay or continuous redraw
        v.enableSetNeedsDisplay = true
        v.isPaused = false
        v.preferredFramesPerSecond = 60
        return v
    }
    func updateNSView(_ nsView: MTKView, context: Context) { nsView.setNeedsDisplay(nsView.bounds) }
}
class MetalRenderer: NSObject, MTKViewDelegate {
    var device: MTLDevice!; var commandQueue: MTLCommandQueue!
    var texture: MTLTexture!; var pipelineState: MTLRenderPipelineState!
    let w = 512; let h = 478
    let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 p [[position]]; float2 t; };
    vertex VOut vertex_main(uint id [[vertex_id]]) {
        float2 p[] = { {-1, -1}, { 1, -1}, {-1,  1}, { 1,  1} };
        float2 t[] = { {0, 1}, {1, 1}, {0, 0}, {1, 0} };
        VOut o; o.p = float4(p[id], 0, 1); o.t = t[id]; return o;
    }
    fragment float4 fragment_main(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(mag_filter::nearest, min_filter::nearest);
        return tex.sample(s, in.t);
    }
    """
    override init() {
        super.init()
        device = MTLCreateSystemDefaultDevice(); commandQueue = device.makeCommandQueue()
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead, .shaderWrite]; texture = device.makeTexture(descriptor: desc)
        let lib = try? device.makeLibrary(source: shader, options: nil)
        let pDesc = MTLRenderPipelineDescriptor()
        pDesc.vertexFunction = lib?.makeFunction(name: "vertex_main")
        pDesc.fragmentFunction = lib?.makeFunction(name: "fragment_main")
        pDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        pipelineState = try? device.makeRenderPipelineState(descriptor: pDesc)
    }
    func updateTexture(pixels: [UInt32]) {
        guard !pixels.isEmpty else { return }
        // Convert from ARGB (0xAARRGGBB) used by the PPU into BGRA layout
        // expected by a .bgra8Unorm Metal texture.
        var bgraPixels = [UInt32](repeating: 0, count: pixels.count)
        for i in 0..<pixels.count {
            let px = pixels[i]
            let a = (px >> 24) & 0xFF
            let r = (px >> 16) & 0xFF
            let g = (px >> 8) & 0xFF
            let b = px & 0xFF
            bgraPixels[i] = (UInt32(b) << 24) | (UInt32(g) << 16) | (UInt32(r) << 8) | UInt32(a)
        }
        let region = MTLRegionMake2D(0, 0, w, h)
        bgraPixels.withUnsafeBytes {
            texture.replace(region: region,
                            mipmapLevel: 0,
                            withBytes: $0.baseAddress!,
                            bytesPerRow: w * 4)
        }
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard let d = view.currentDrawable, let rpd = view.currentRenderPassDescriptor, let buf = commandQueue.makeCommandBuffer(), let enc = buf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipelineState); enc.setFragmentTexture(texture, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding(); buf.present(d); buf.commit()
    }
}
