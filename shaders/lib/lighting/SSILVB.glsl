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

// https://cdrinmatane.github.io/posts/ssaovb-code/
const uint sectorCount = 32u;
uint updateSectors(float minHorizon, float maxHorizon) {
    uint startBit = uint(minHorizon * float(sectorCount));
    uint horizonAngle = uint(ceil((maxHorizon - minHorizon) * float(sectorCount)));
    uint angleBit = horizonAngle > 0u ? uint(0xFFFFFFFFu >> (sectorCount - horizonAngle)) : 0u;
    uint currentBitfield = angleBit << startBit;
    return currentBitfield;
}

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
        dir = normalize(dir * 2.0 - 1.0);

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
                    vec3 sampleDirFront = sampleDiff * inversesqrt(frontDistSq);
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
    irradiance.rgb += max(global.light.skyIlluminance * rPI, skylight) * irradiance.a * cube(lightmap.y);
    return irradiance;
}
