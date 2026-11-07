#include <metal_stdlib>
using namespace metal;

struct PhaseVertex {
    float4 position [[position]];
    float2 uv;
};

struct PhaseUniforms {
    float4 signal;   // phase, local validity gate, active, animation time
    float4 geometry; // aspect ratio, reserved, reserved, reserved
};

vertex PhaseVertex phaseVertexMain(uint vertexID [[vertex_id]]) {
    const float2 coordinates[4] = {
        float2(0.0, 1.0), float2(1.0, 1.0),
        float2(0.0, 0.0), float2(1.0, 0.0)
    };
    const float4 positions[4] = {
        float4(-1.0, -1.0, 0.0, 1.0), float4(1.0, -1.0, 0.0, 1.0),
        float4(-1.0, 1.0, 0.0, 1.0), float4(1.0, 1.0, 0.0, 1.0)
    };
    PhaseVertex result;
    result.position = positions[vertexID];
    result.uv = coordinates[vertexID];
    return result;
}

fragment float4 phaseFragmentMain(
    PhaseVertex stageInput [[stage_in]],
    constant PhaseUniforms& uniforms [[buffer(0)]]
) {
    float2 point = stageInput.uv - float2(0.5);
    point.x *= uniforms.geometry.x;
    float radius = length(point);
    float active = uniforms.signal.z;
    float valid = uniforms.signal.y;
    float time = uniforms.signal.w;
    float phase = uniforms.signal.x;

    // This deliberately abstract wave is a visualization of phase, not a scan,
    // object detection, direction estimate, or image of the surroundings.
    float wave = 0.5 + 0.5 * sin(radius * 50.0 - time * 2.0 + phase);
    float rings = pow(wave, 9.0) * exp(-radius * 2.0);
    float3 idleColor = float3(0.18, 0.28, 0.34);
    float3 activeColor = mix(float3(0.93, 0.58, 0.20), float3(0.16, 0.88, 0.82), valid);
    float3 color = mix(idleColor, activeColor, active);
    float cross = (1.0 - smoothstep(0.0005, 0.002, abs(point.x)))
                + (1.0 - smoothstep(0.0005, 0.002, abs(point.y)));
    float3 background = float3(0.025, 0.04, 0.06);
    return float4(background + color * (0.62 * rings + 0.05 * cross), 1.0);
}
