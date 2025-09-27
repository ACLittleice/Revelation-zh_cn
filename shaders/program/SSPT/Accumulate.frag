/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

    Pass: Accumulation for SSPT and variance estimation
	Reference:  https://research.nvidia.com/sites/default/files/pubs/2017-07_Spatiotemporal-Variance-Guided-Filtering://svgf_preprint.pdf
                https://cescg.org/wp-content/uploads/2018/04/Dundr-Progressive-Spatiotemporal-Variance-Guided-Filtering-2.pdf

--------------------------------------------------------------------------------
*/

const bool colortex3MipmapEnabled = true;

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 3,2,14 */
layout (location = 0) out vec4 indirectCurrent;
layout (location = 1) out vec4 indirectHistory;
layout (location = 2) out vec2 varianceMoments;

//======// Uniform //=============================================================================//

#include "/lib/universal/Uniform.glsl"

//======// SSBO //================================================================================//

#include "/lib/universal/SSBO.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Fetch.glsl"
#include "/lib/universal/Random.glsl"

void TemporalFilter(in ivec2 texel, in vec3 screenPos, in vec3 worldNormal) {
    vec2 prevCoord = Reproject(screenPos).xy;

    float luma = luminance(texelFetch(colortex3, texel, 0).rgb);
    ivec2 texelEnd = ivec2(halfViewEnd);

    // Estimate spatial variance
    vec2 currMoments = vec2(luma, luma * luma);
    {
	    for (uint i = 0u; i < 8u; ++i) {
            ivec2 sampleTexel = clamp(texel + offset3x3N[i], ivec2(0), texelEnd);
            vec3 sampleColor = texelFetch(colortex3, sampleTexel, 0).rgb;
            float sampleLuma = luminance(sampleColor);

            // vec3 sampleNormal = FetchWorldNormal(loadGbufferData0(sampleTexel << 1));
            // float weight = saturate(dot(sampleNormal, worldNormal) * 20.0 - 19.0);

            currMoments += vec2(sampleLuma, sampleLuma * sampleLuma);
        }

        currMoments *= 1.0 / 9.0;
    }
    varianceMoments.xy = currMoments;

    if (saturate(prevCoord) == prevCoord && !worldTimeChanged) {
        vec3 viewPos = ScreenToViewSpace(screenPos);
        float currViewDistance = length(viewPos);

        vec4 prevDiffuse = vec4(0.0);
        vec2 prevMoments = vec2(0.0);
        float sumWeight = 0.0;

        prevCoord += (prevTaaOffset - taaOffset) * 0.25;

        // Custom bilinear filter
        vec2 prevTexel = prevCoord * 0.5 * viewSize - vec2(0.5);
        ivec2 floorTexel = ivec2(floor(prevTexel));
        vec2 fractTexel = prevTexel - vec2(floorTexel);

        float bilinearWeight[4] = {
            oms(fractTexel.x) * oms(fractTexel.y),
            fractTexel.x      * oms(fractTexel.y),
            oms(fractTexel.x) * fractTexel.y,
            fractTexel.x      * fractTexel.y
        };

        ivec2 offsetToBR = ivec2(halfViewSize.x, 0);

        for (uint i = 0u; i < 4u; ++i) {
            ivec2 sampleTexel = floorTexel + offset2x2[i];
            if (clamp(sampleTexel, ivec2(0), texelEnd) == sampleTexel) {
                vec3 sampleAux = texelFetch(colortex2, sampleTexel + offsetToBR, 0).rgb;

                if (abs((currViewDistance - sampleAux.z) - cameraVelocity) < 0.1 * currViewDistance) {
                    float weight = bilinearWeight[i];
                    weight *= pow8(saturate(dot(OctDecodeSnorm(sampleAux.xy), worldNormal)));

                    prevDiffuse += texelFetch(colortex2, sampleTexel, 0) * weight;
                    prevMoments += texelFetch(colortex14, sampleTexel, 0).xy * weight;
                    sumWeight += weight;
                }
            }
        }

        if (sumWeight > EPS) {
            sumWeight = 1.0 / sumWeight;
            prevDiffuse *= sumWeight;
            prevMoments *= sumWeight;

            indirectHistory.a = min(prevDiffuse.a + 1.0, SSPT_MAX_ACCUM_FRAMES);
            float alpha = rcp(indirectHistory.a);

            // See section 4.2 of the paper
            if (indirectHistory.a > 4.5) {
                varianceMoments.xy = mix(prevMoments, varianceMoments.xy, alpha);
            }

            float mipLevel = 4.0 * saturate(1.0 - indirectHistory.a * rcp(16.0));
            indirectCurrent.rgb = textureLod(colortex3, screenPos.xy * 0.5, mipLevel).rgb;

            indirectCurrent.rgb = indirectHistory.rgb = mix(prevDiffuse.rgb, indirectCurrent.rgb, alpha);

            varianceMoments.x *= varianceMoments.x;
            indirectCurrent.a = maxEps(varianceMoments.y - varianceMoments.x);
            indirectCurrent.a *= inversesqrt(indirectCurrent.a);
            return;
        }
    }

    indirectCurrent.rgb = textureLod(colortex3, screenPos.xy * 0.5, 4.0).rgb;
    indirectCurrent.a = varianceMoments.x;
}

float GetClosestDepth(in ivec2 texel) {
    float depth = loadDepth0(texel);

    for (uint i = 0u; i < 8u; ++i) {
        ivec2 sampleTexel = (offset3x3N[i] << 1) + texel;
        float sampleDepth = loadDepth0(sampleTexel);
        depth = min(depth, sampleDepth);
    }

    return depth;
}

//======// Main //================================================================================//
void main() {
    vec2 currentCoord = gl_FragCoord.xy * viewPixelSize * 2.0;

    indirectCurrent = vec4(vec3(0.0), 1e6);
    indirectHistory = vec4(0.0);
    varianceMoments = vec2(0.0);

    if (currentCoord.y < 1.0) {
        ivec2 screenTexel = ivec2(gl_FragCoord.xy);

        if (currentCoord.x < 1.0) {
            ivec2 currentTexel = screenTexel << 1;
            float depth = loadDepth0(currentTexel);
            #if defined DISTANT_HORIZONS
                bool dhTerrainMask = depth > (1.0 - EPS);
                if (dhTerrainMask) depth = loadDepth0DH(currentTexel);
            #endif

            if (depth < 1.0) {
                vec3 screenPos = vec3(currentCoord, depth);
                vec3 worldNormal = FetchWorldNormal(currentTexel);
                TemporalFilter(screenTexel, screenPos, worldNormal);

                float blocklight = Unpack2x8UX(loadGbufferData0(currentTexel).x);
                blocklight = pow5(blocklight) * exp2(-64.0 * luminance(indirectCurrent.rgb) * global.exposure.value);
                indirectCurrent.rgb += blackbody(float(BLOCKLIGHT_TEMPERATURE)) * saturate(blocklight) * SSPT_BLENDED_LIGHTMAP;
            }
        } else {
            ivec2 currentTexel = (screenTexel << 1) - ivec2(viewWidth, 0);
            float depth = loadDepth0(currentTexel);
            #if defined DISTANT_HORIZONS
                bool dhTerrainMask = depth > (1.0 - EPS);
                if (dhTerrainMask) depth = loadDepth0DH(currentTexel);
            #endif

            if (depth < 1.0) {
                vec3 worldNormal = FetchWorldNormal(currentTexel);
                vec3 screenPos = vec3(currentCoord - vec2(1.0, 0.0), depth);
                vec3 viewPos = ScreenToViewSpace(screenPos);
                #if defined DISTANT_HORIZONS
                    if (dhTerrainMask) viewPos = ScreenToViewSpaceDH(screenPos);
                #endif
                float viewDistance = length(viewPos);

                indirectHistory = vec4(OctEncodeSnorm(worldNormal), viewDistance, 0.0);
            }
        }
    }
}