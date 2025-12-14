//
//  Shader.metal
//  SwiftSNES – Perfect Pixel Metal Shader
//  Nearest-neighbor, no blur, crisp retro glory
//

#include <metal_stdlib>
using namespace metal;

// Input vertex ID from Swift (0...3)
struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Full-screen quad – covers entire NDC space
vertex VertexOut vertex_main(uint vertexID [[vertex_id]]) {
    // 4 vertices: bottom-left, bottom-right, top-left, top-right
    const float2 positions[4] = {
        float2(-1.0, -1.0),
        float2( 1.0, -1.0),
        float2(-1.0,  1.0),
        float2( 1.0,  1.0)
    };
    
    const float2 texCoords[4] = {
        float2(0.0, 1.0),  // flip Y because Metal texture origin is top-left
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = texCoords[vertexID];
    return out;
}

// Sample SNES framebuffer (256×224 → stretched to window with crisp pixels)
fragment float4 fragment_main(VertexOut in [[stage_in]],
                              texture2d<float> frameBuffer [[texture(0)]],
                              sampler s [[sampler(0)]]) {
    // Nearest-neighbor = perfect retro pixels
    constexpr sampler pixelPerfect(
        mag_filter::nearest,
        min_filter::nearest,
        address::clamp_to_edge
    );
    
    return frameBuffer.sample(pixelPerfect, in.texCoord);
}
