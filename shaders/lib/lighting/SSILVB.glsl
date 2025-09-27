// Adapted from "Screen Space sBitMask Lighting with Visibility Bitmask" by Olivier Therrien, et al.
// https://arxiv.org/pdf/2301.11376
// https://cdrinmatane.github.io/posts/cgspotlight-slides/
// https://cybereality.com/screen-space-indirect-lighting-with-visibility-bitmask-improvement-to-gtao-ssao-real-time-ambient-occlusion-algorithm-glsl-shader-implementation/

// https://cdrinmatane.github.io/posts/ssaovb-code/
const uint sectorCount = 32u;
uint updateSectors(float minHorizon, float maxHorizon) {
    uint startBit = uint(minHorizon * float(sectorCount));
    uint horizonAngle = uint(ceil((maxHorizon - minHorizon) * float(sectorCount)));
    uint angleBit = horizonAngle > 0u ? uint(0xFFFFFFFFu >> (sectorCount - horizonAngle)) : 0u;
    uint currentBitfield = angleBit << startBit;
    return currentBitfield;
}

float horizonWeight(vec3 projNormal, vec3 pos) {
    float cosH = saturate(dot(pos, projNormal));
    return sqrt(1.0 - cosH * cosH);
}

vec4 CalculateSSILVB(in vec2 fragCoord, in vec3 viewPos, in vec3 worldNormal, in vec2 lightmap) {
	const uint sliceCount = 2u;
	const uint sampleCount = 8u;
	const float sampleRadius = 4.0;
	const float hitThickness = 1.0;

	const float rSliceCount = 1.0 / float(sliceCount);
	const float rSampleCount = 1.0 / float(sampleCount);
	const float rSectorCount = 1.0 / float(sectorCount);

    vec2 noise = SampleStbnVec2(ivec2(gl_GlobalInvocationID.xy), frameCounter);

    vec3 viewDir = normalize(-viewPos);
    vec3 viewNormal = mat3(gbufferModelView) * worldNormal;

    vec4 irradiance = vec4(0.0);

    const float sliceRotation = TAU * rSliceCount;
    vec2 sampleScale = -sampleRadius / viewPos.z * diagonal2(gbufferProjection);

    for (uint slice = 0u; slice < sliceCount; ++slice) {
        float phi = sliceRotation * (float(slice) + noise.x);
        vec2 omega = vec2(cos(phi), sin(phi));
        vec3 orthoDir = cross(vec3(omega, 0.0), viewDir);
        vec3 projNormal = viewNormal - orthoDir * dot(viewNormal, orthoDir);
        vec2 stepDir = omega * sampleScale;

        uint bitMask = 0u;

        for (uint currentSample = 0u; currentSample < sampleCount; ++currentSample) {
            float sampleStep = (float(currentSample) + noise.y) * rSampleCount;
            vec2 sampleUV = fragCoord + sampleStep * stepDir;

			if (saturate(sampleUV) == sampleUV) {
				vec3 sampleDiff = ScreenToViewSpace(sampleUV) - viewPos;
                float frontDistSq = sdot(sampleDiff);

                if (frontDistSq < sampleRadius * sampleRadius) {
                    vec3 sampleDirFront = sampleDiff * inversesqrt(frontDistSq);
                    vec3 sampleDirBack = normalize(sampleDiff - viewDir * hitThickness);

                    float frontHorizon = horizonWeight(projNormal, sampleDirFront);
                    float backHorizon = horizonWeight(projNormal, sampleDirBack);

                    uint sBitMask = updateSectors(min(frontHorizon, backHorizon), max(frontHorizon, backHorizon));
                    uint sampleOccludedBit = sBitMask & ~bitMask;

                    if (sampleOccludedBit > 0u) {
                        ivec2 sampleTexel = uvToTexel(sampleUV);
                        vec3 sampleNormal = mat3(gbufferModelView) * FetchWorldNormal(sampleTexel);

                        vec3 sampleRadiance = texelFetch(colortex4, sampleTexel >> 1, 0).rgb;
                        irradiance.rgb += float(bitCount(sampleOccludedBit)) *
                            saturate(dot(viewNormal, sampleDirFront)) *
                            saturate(0.5 - 0.5 * dot(sampleNormal, sampleDirFront)) *
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

    irradiance.rgb += FromSphericalHarmonics(global.light.skySH, worldNormal) * irradiance.a * cube(lightmap.y);
    return irradiance;
}
