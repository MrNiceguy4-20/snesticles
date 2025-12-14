//
//  MetalView.swift
//  snits
//
//  Created by kevin on 2025-12-05.
//

import MetalKit
import SwiftUI

// MARK: - SwiftUI Wrapper

struct MetalView: NSViewRepresentable {
    let renderer: MetalRenderer

    func makeCoordinator() -> Coordinator {
        Coordinator(renderer)
    }

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = renderer.device
        mtkView.delegate = context.coordinator
        
        // Pixel Format matching PPU output (BGRA8)
        mtkView.colorPixelFormat = .bgra8Unorm
        
        // Clear to black
        mtkView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        
        // Performance settings
        mtkView.framebufferOnly = false
        mtkView.isPaused = false
        mtkView.enableSetNeedsDisplay = false
        mtkView.preferredFramesPerSecond = 60
        
        // Handle aspect ratio / scaling
        mtkView.autoResizeDrawable = true
        
        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        // Window resizing is handled automatically by Metal's drawable resize
    }

    // MARK: - Coordinator (MTKViewDelegate)
    
    class Coordinator: NSObject, MTKViewDelegate {
        private let parentRenderer: MetalRenderer

        init(_ renderer: MetalRenderer) {
            self.parentRenderer = renderer
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
            // Viewport resizing handled by normalized device coordinates in shader
        }

        func draw(in view: MTKView) {
            parentRenderer.draw(in: view)
        }
    }
}

// MARK: - Metal Renderer Engine

final class MetalRenderer: NSObject {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    
    private var pipelineState: MTLRenderPipelineState!
    private var texture: MTLTexture!
    private let vertexBuffer: MTLBuffer
    
    // SNES Resolution
    private let snesWidth = 256
    private let snesHeight = 224

    override init() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this Mac")
        }
        self.device = device
        self.commandQueue = device.makeCommandQueue()!

        // Full-screen quad vertices (X, Y) and Texture Coordinates (U, V)
        // Metal NDC is -1 to 1. Texture coords are 0 to 1.
        let vertices: [Float] = [
            -1.0, -1.0,  0.0, 1.0,   // Bottom-Left
             1.0, -1.0,  1.0, 1.0,   // Bottom-Right
            -1.0,  1.0,  0.0, 0.0,   // Top-Left
             1.0,  1.0,  1.0, 0.0    // Top-Right
        ]
        
        self.vertexBuffer = device.makeBuffer(
            bytes: vertices,
            length: vertices.count * MemoryLayout<Float>.size,
            options: .storageModeShared
        )!

        super.init()

        setupPipeline()
        createFramebufferTexture()
    }

    private func setupPipeline() {
        var library: MTLLibrary?
        
        // 1. Try loading the separate 'shader.metal' file (Default Library)
        if let defaultLib = device.makeDefaultLibrary() {
            library = defaultLib
            print("Metal: Loaded default library (shader.metal)")
        } else {
            // 2. Fallback: Compile embedded shader string if file is missing/unlinked
            print("Metal: Default library not found, compiling embedded shader...")
            do {
                library = try device.makeLibrary(source: embeddedShaderSource, options: nil)
            } catch {
                fatalError("Metal Shader Compilation Error: \(error)")
            }
        }
        
        guard let lib = library else { fatalError("Could not create Metal Library") }
        
        // Create Pipeline
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = lib.makeFunction(name: "vertex_main")
        pipelineDescriptor.fragmentFunction = lib.makeFunction(name: "fragment_main")
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        
        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Failed to create pipeline state: \(error)")
        }
    }

    private func createFramebufferTexture() {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: snesWidth,
            height: snesHeight,
            mipmapped: false
        )
        // Usage: Shader reads it, CPU writes to it
        descriptor.usage = [.shaderRead, .shaderWrite]
        
        // Managed mode allows CPU -> GPU synchronization on macOS
        descriptor.storageMode = .managed
        
        guard let tex = device.makeTexture(descriptor: descriptor) else {
            fatalError("Failed to create SNES texture")
        }
        texture = tex
    }

    /// Called by PPU to upload the frame
    func updateTexture(with pixels: UnsafePointer<UInt32>) {
        let region = MTLRegionMake2D(0, 0, snesWidth, snesHeight)
        
        texture.replace(
            region: region,
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: snesWidth * 4 // 4 bytes per pixel (BGRA)
        )
    }

    // MARK: - Draw Loop
    
    func draw(in view: MTKView) {
        guard
            let drawable = view.currentDrawable,
            let renderPass = view.currentRenderPassDescriptor,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else { return }

        // Set state
        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(texture, index: 0)
        
        // Draw Quad
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        
        encoder.endEncoding()

        // Present
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
    
    // MARK: - Fallback Shader
    // Used only if shader.metal is missing from the bundle
    private let embeddedShaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 texCoord;
    };

    vertex VertexOut vertex_main(uint vid [[vertex_id]],
                                 constant float4 *vertices [[buffer(0)]]) {
        VertexOut out;
        // vertices[vid] contains x, y, u, v
        out.position = float4(vertices[vid].xy, 0.0, 1.0);
        out.texCoord = vertices[vid].zw;
        return out;
    }

    fragment float4 fragment_main(VertexOut in [[stage_in]],
                                  texture2d<float> tex [[texture(0)]]) {
        constexpr sampler s(mag_filter::nearest, min_filter::nearest);
        return tex.sample(s, in.texCoord);
    }
    """
}
