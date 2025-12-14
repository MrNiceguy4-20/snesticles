#include <metal_stdlib>
using namespace metal;

struct VOut {
    float4 p [[position]];
    float2 t;
};

vertex VOut vertex_main(uint id [[vertex_id]]) {
    float2 p[4] = { float2(-1,-1), float2(1,-1), float2(-1,1), float2(1,1) };
    float2 t[4] = { float2(0,1), float2(1,1), float2(0,0), float2(1,0) };
    VOut o;
    o.p = float4(p[id], 0, 1);
    o.t = t[id];
    return o;
}

fragment float4 fragment_main(VOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]]) {
    constexpr sampler s(mag_filter::nearest, min_filter::nearest);
    return tex.sample(s, in.t);
}
