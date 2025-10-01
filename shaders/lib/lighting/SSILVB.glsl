// Adapted from "Screen Space sBitMask Lighting with Visibility Bitmask" by Olivier Therrien, et al.
// https://arxiv.org/pdf/2301.11376
// https://cdrinmatane.github.io/posts/cgspotlight-slides/
// https://cybereality.com/screen-space-indirect-lighting-with-visibility-bitmask-improvement-to-gtao-ssao-real-time-ambient-occlusion-algorithm-glsl-shader-implementation/

//================================================================================================//

#define SSILVB_SLICE_COUNT 1 // [1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16]
#define SSILVB_SAMPLE_COUNT 16 // [4 6 8 10 12 14 16 18 20 22 24 26 28 30 32]
#define SSILVB_SAMPLE_RADIUS 8.0 // [4.0 6.0 8.0 10.0 12.0 14.0 16.0 18.0 20.0 22.0 24.0 26.0 28.0 30.0 32.0]
#define SSILVB_HIT_THICKNESS 1.0 // [0.25 0.5 1.0 1.5 2.0 2.5 3.0 3.5 4.0 4.5 5.0 5.5 6.0 6.5 7.0 7.5 8.0]

//================================================================================================//

#include "/lib/utility/ShaderFastMathLib.glsl"

// https://www.shadertoy.com/view/XcdBWf
// MIT License. Copyright (C) 2024 Mirko Salm.
vec2 cmul(vec2 c0, vec2 c1) {
    return vec2(c0.x * c1.x - c0.y * c1.y, c0.y * c1.x + c0.x * c1.y);
}

float SamplePartialSlice(float x, float sin_thVN) {
    float abs_x = abs(x);
    if (abs_x < EPS || abs_x >= 1.0) return x;

    float s = sin_thVN;

    float o = s - s * s;
    float slp0 = 1.0 / (1.0 + (PI  - 1.0) * (s - o * 0.30546));
    float slp1 = 1.0 / (1.0 - (1.0 - exp2(-20.0)) * (s + o * mix(0.5, 0.785, s)));
    float k = mix(0.1, 0.25, s);

    float a = 1.0 - (PI - 2.0) / (PI - 1.0);
    float b = 1.0 / (PI - 1.0);

    float d0 =   a - slp0 * b;
    float d1 = 1.0 - slp1;

    float f0 = d0 * (PI * abs_x - asinFast4(clamp(abs_x, -1.0, 1.0)));
    float f1 = d1 * (abs_x - 1.0);

    float kk = k * k;

    float h0 = fastSqrtNR0(f0 * f0 + kk) - k;
    float h1 = fastSqrtNR0(f1 * f1 + kk) - k;

    float hh = (h0 * h1) / (h0 + h1);

    float y = abs_x - fastSqrtNR0(hh * (hh + 2.0 * k));

    return x < 0.0 ? -y : y;
}

vec2 SamplePartialSliceDir(vec3 vvsN, vec2 dir0) {
    float l = sdot(vvsN.xy);
    if (l < EPS) return dir0;

    float rl = fastRcpSqrtNR0(l);
    vec2 n = vvsN.xy * rl;
    // align n with x-axis
    dir0 = cmul(dir0, n * vec2(1.0, -1.0));

    // sample slice angle
    float x = atan(dir0.x, dir0.y) * rPI;
    float ang = SamplePartialSlice(x, l * rl) * PI;

    // ray space slice direction
    vec2 dir = vec2(cos(ang), sin(ang));

    // align x-axis with n
    return cmul(dir, n);
}

// https://cdrinmatane.github.io/posts/ssaovb-code/
const uint sectorCount = 32u;
uint updateSectors(float minHorizon, float maxHorizon) {
    uint startBit = uint(minHorizon * float(sectorCount));
    uint horizonAngle = uint(ceil((maxHorizon - minHorizon) * float(sectorCount)));
    uint angleBit = horizonAngle > 0u ? uint(0xFFFFFFFFu >> (sectorCount - horizonAngle)) : 0u;
    uint currentBitfield = angleBit << startBit;
    return currentBitfield;
}

//================================================================================================//

vec4 CalculateSSILVB(in vec2 fragCoord, in vec3 viewPos, in vec3 worldNormal, in vec2 lightmap) {
	const uint sliceCount = SSILVB_SLICE_COUNT;
	const uint sampleCount = SSILVB_SAMPLE_COUNT;
	const float sampleRadius = SSILVB_SAMPLE_RADIUS;
	const float hitThickness = SSILVB_HIT_THICKNESS;

	const float rSliceCount = 1.0 / float(sliceCount);
	const float rSampleCount = 1.0 / float(sampleCount);
	const float rSectorCount = 1.0 / float(sectorCount);

    float dither = SampleStbnVec1(ivec2(gl_GlobalInvocationID.xy), frameCounter);

    vec3 viewDir = normalize(-viewPos);
    vec3 viewNormal = mat3(gbufferModelView) * worldNormal;

    vec4 irradiance = vec4(0.0);

    vec2 sampleScale = -sampleRadius / viewPos.z * diagonal2(gbufferProjection);

    for (int slice = 0; slice < sliceCount; ++slice) {
        vec2 dir = SampleStbnUnitvec2(ivec2(gl_GlobalInvocationID.xy), frameCounter + slice);
        dir = SamplePartialSliceDir(viewNormal, normalize(dir * 2.0 - 1.0));

        vec3 sliceN = normalize(cross(vec3(dir, 0.0), viewDir));
        vec3 projN = viewNormal - sliceN * dot(viewNormal, sliceN);
        float cosN = dot(projN, viewDir) * inversesqrt(sdot(projN));

        float angN = -fastSign(dot(projN, cross(viewDir, sliceN))) * acosFast4(clamp(cosN, -1.0, 1.0));
        float angOff = angN * rPI + 0.5;

        uint bitMask = 0u;

        for (uint currentSample = 0u; currentSample < sampleCount; ++currentSample) {
            float sampleStep = (float(currentSample) + dither) * rSampleCount;
            vec2 sampleUV = fragCoord + sampleStep * sampleScale * dir;

			if (saturate(sampleUV) == sampleUV) {
				vec3 sampleDiff = ScreenToViewSpace(sampleUV) - viewPos;
                float frontDistSq = sdot(sampleDiff);

                if (frontDistSq < sampleRadius * sampleRadius * 4.0) {
                    vec3 sampleDirFront = sampleDiff * fastRcpSqrtNR0(frontDistSq);
                    vec3 sampleDirBack = normalize(sampleDiff - viewDir * hitThickness);

                    vec2 frontBackHorizon = vec2(dot(sampleDirFront, viewDir), dot(sampleDirBack, viewDir));

                    frontBackHorizon = acosFast4(clamp(frontBackHorizon, -1.0, 1.0));
                    frontBackHorizon = saturate(frontBackHorizon * rPI + angOff);

                    uint sBitMask = updateSectors(frontBackHorizon.x, frontBackHorizon.y);
                    uint sampleOccludedBit = sBitMask & ~bitMask;

                    if (sampleOccludedBit > 0u) {
                        ivec2 sampleTexel = uvToTexel(sampleUV);
                        // vec3 sampleNormal = mat3(gbufferModelView) * FetchWorldNormal(sampleTexel);

                        vec3 sampleRadiance = texelFetch(colortex4, sampleTexel >> 1, 0).rgb;
                        irradiance.rgb += float(bitCount(sampleOccludedBit)) *
                            saturate(dot(viewNormal, sampleDirFront)) *
                            // saturate(-dot(sampleNormal, sampleDirFront)) *
                            sampleRadiance;

                        bitMask |= sBitMask;
                    }
                }
			}
        }

        irradiance.a += float(bitCount(bitMask));
    }

    irradiance *= rSectorCount * rSliceCount;
    irradiance = vec4(irradiance.rgb * PI, 1.0 - irradiance.a);

    vec3 skylight = ConvolvedReconstructSH3(global.light.skySH, worldNormal);
    irradiance.rgb += skylight * irradiance.a * cube(lightmap.y);
    return irradiance;
}
