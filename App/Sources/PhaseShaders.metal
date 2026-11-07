#include <metal_stdlib>
using namespace metal;

struct PhaseVertex {
    float4 position [[position]];
    float2 uv;
};

// Keep byte-for-byte aligned with MetalPhaseRenderer.Uniforms: six float4s.
struct PhaseUniforms {
    float4 signal;             // wrapped phase, valid, amplitude, simulated source
    float4 geometry;           // aspect, pixel width, pixel height, reduce motion
    float4 display;            // display gain dB, persistence, palette, active
    float4 previousPhases;     // up to four actual preceding valid phases
    float4 previousAmplitudes; // corresponding amplitudes; zero means absent
    float4 mode;               // waterfall, texture rows, actual frame count, reserved
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

// All three are display palettes. "Thermal" is a false-color palette name,
// not an inferred temperature, thermal sensor, or additional measurement.
static float3 falseColor(float value, float palette) {
    float t = clamp(value, 0.0, 1.0);
    if (palette > 1.5) {
        return mix(float3(0.016, 0.023, 0.031), float3(0.90, 0.94, 0.96), pow(t, 1.25));
    }
    float3 a, b, c, d;
    if (palette > 0.5) {
        a = float3(0.018, 0.020, 0.038);
        b = float3(0.25, 0.08, 0.28);
        c = float3(0.84, 0.26, 0.16);
        d = float3(1.00, 0.91, 0.66);
    } else {
        a = float3(0.016, 0.023, 0.038);
        b = float3(0.08, 0.18, 0.34);
        c = float3(0.06, 0.65, 0.64);
        d = float3(0.74, 0.97, 0.83);
    }
    if (t < 0.34) return mix(a, b, smoothstep(0.0, 0.34, t));
    if (t < 0.72) return mix(b, c, smoothstep(0.34, 0.72, t));
    return mix(c, d, smoothstep(0.72, 1.0, t));
}

static float3 uncertainty(float2 pixel) {
    float diagonal = abs(fract((pixel.x + pixel.y) / 18.0) - 0.5);
    float hatch = 1.0 - smoothstep(0.055, 0.12, diagonal);
    return float3(0.022, 0.030, 0.039) + float3(0.046, 0.057, 0.064) * hatch;
}

static float fieldPattern(float2 point, float phase, bool simulated) {
    float radius = length(point);
    float argument;
    if (simulated) {
        // An explicitly synthetic 2D traveling-wave illustration. It is never
        // used for microphone data, nor presented as a spatial reconstruction.
        argument = (point.x * 0.82 + point.y * 0.40) * 40.0 - phase;
    } else {
        // One probe, one phase: concentric abstract contours, with no spatial,
        // depth, direction, scene geometry, or reflector-location claim.
        argument = radius * 44.0 - phase;
    }
    float contour = pow(0.5 + 0.5 * cos(argument), 11.0);
    return contour * exp(-radius * (simulated ? 0.75 : 1.65));
}

static float fieldBrightness(float amplitude, float gainDB) {
    float gained = max(amplitude, 0.0) * pow(10.0, gainDB / 20.0);
    return clamp(pow(gained, 0.25) * 1.2, 0.0, 1.0);
}

static float3 drawField(float2 uv, constant PhaseUniforms& uniforms) {
    float2 pixel = uv * uniforms.geometry.yz;
    if (uniforms.signal.y < 0.5) return uncertainty(pixel);

    float2 point = (uv - float2(0.5)) * float2(uniforms.geometry.x, 1.0);
    bool simulated = uniforms.signal.w > 0.5;
    bool reducedMotion = uniforms.geometry.w > 0.5;
    // Reduce Motion fixes contour positions. Fresh samples may change their
    // intensity, but never move the geometry or create a time-based animation.
    float phase = reducedMotion ? 0.0 : uniforms.signal.x;
    float intensity = fieldPattern(point, phase, simulated)
        * fieldBrightness(uniforms.signal.z, uniforms.display.x);
    if (!reducedMotion) {
        float decay = uniforms.display.y * 0.82;
        float weight = decay;
        for (uint index = 0; index < 4; ++index) {
            float trail = fieldPattern(point, uniforms.previousPhases[index], simulated)
                * fieldBrightness(uniforms.previousAmplitudes[index], uniforms.display.x);
            intensity = max(intensity, trail * weight);
            weight *= decay;
        }
    }

    float2 gridDistance = abs(fract(pixel / 56.0) - 0.5);
    float grid = 1.0 - smoothstep(0.008, 0.025, min(gridDistance.x, gridDistance.y));
    float3 background = float3(0.016, 0.023, 0.031) + grid * float3(0.008, 0.012, 0.016);
    float3 ink = falseColor(0.73 + 0.22 * intensity, uniforms.display.z);
    float3 color = background + ink * intensity * 0.75;
    if (!simulated) {
        float radiusPixels = length((uv - float2(0.5)) * uniforms.geometry.yz);
        float probe = 1.0 - smoothstep(1.7, 3.0, radiusPixels);
        float probeRing = 1.0 - smoothstep(0.65, 1.4, abs(radiusPixels - 8.0));
        color += float3(0.46, 0.55, 0.59) * (probe * 0.45 + probeRing * 0.16);
    }
    return color;
}

static float spectralIntensity(float levelDBFS, float gainDB) {
    return pow(clamp((levelDBFS + gainDB + 120.0) / 120.0, 0.0, 1.0), 1.25);
}

static float3 drawWaterfall(
    float2 uv, constant PhaseUniforms& uniforms,
    texture2d<float, access::read> spectrumTexture
) {
    float2 pixel = uv * uniforms.geometry.yz;
    if (uniforms.mode.z < 0.5) return uncertainty(pixel);
    // A single observed spectrum has no past duration. Do not stretch it into
    // an apparently populated history: show only the newest strip.
    if (uniforms.mode.z < 1.5 && uniforms.mode.y < 1.5 && uv.y > 0.035) {
        return uncertainty(pixel);
    }
    uint width = spectrumTexture.get_width();
    uint height = spectrumTexture.get_height();
    uint column = uint(clamp(round(uv.x * float(width - 1)), 0.0, float(width - 1)));
    uint row = uint(clamp(round(uv.y * float(height - 1)), 0.0, float(height - 1)));
    float2 bin = spectrumTexture.read(uint2(column, row)).rg;
    if (bin.y < 0.5) return uncertainty(pixel);

    float intensity = spectralIntensity(bin.x, uniforms.display.x);
    // Display afterglow uses only actual earlier spectra at this frequency.
    // Missing intervals are never filled, and the stored dBFS is unmodified.
    float decay = uniforms.display.y * 0.84;
    float weight = decay;
    for (uint offset = 1; offset <= 4 && row + offset < height; ++offset) {
        float2 earlier = spectrumTexture.read(uint2(column, row + offset)).rg;
        if (earlier.y < 0.5) break;
        intensity = max(intensity, spectralIntensity(earlier.x, uniforms.display.x) * weight);
        weight *= decay;
    }
    float3 color = falseColor(intensity, uniforms.display.z);
    // Sparse frequency/time guides are screen annotations, not signal energy.
    float frequencyGuide = abs(fract(uv.x * 8.0 + 0.5) - 0.5);
    float timeGuide = abs(fract(uv.y * 4.0 + 0.5) - 0.5);
    float vertical = 1.0 - smoothstep(0.0, 8.0 / max(uniforms.geometry.y, 1.0), frequencyGuide);
    float horizontal = 1.0 - smoothstep(0.0, 4.0 / max(uniforms.geometry.z, 1.0), timeGuide);
    return color + float3(0.024, 0.029, 0.033) * max(vertical, horizontal);
}

fragment float4 phaseFragmentMain(
    PhaseVertex stageInput [[stage_in]],
    constant PhaseUniforms& uniforms [[buffer(0)]],
    texture2d<float, access::read> spectrumTexture [[texture(0)]]
) {
    float3 color = uniforms.mode.x > 0.5
        ? drawWaterfall(stageInput.uv, uniforms, spectrumTexture)
        : drawField(stageInput.uv, uniforms);
    return float4(clamp(color, 0.0, 1.0), 1.0);
}
