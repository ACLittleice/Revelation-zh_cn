/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

    Pass: RSM accumulation
	Reference:  https://users.soe.ucsc.edu/~pang/160/s13/proposal/mijallen/proposal/media/p203-dachsbacher.pdf
                https://cescg.org/wp-content/uploads/2018/04/Dundr-Progressive-Spatiotemporal-Variance-Guided-Filtering-2.pdf

--------------------------------------------------------------------------------
*/

const bool colortex3MipmapEnabled = true;

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 2 */
out vec4 indirectHistory;

//======// Uniform //=============================================================================//

#include "/lib/universal/Uniform.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Fetch.glsl"
#include "/lib/universal/Random.glsl"
#include "/lib/universal/Offset.glsl"

void TemporalFilter(in vec3 screenPos, in vec3 worldNormal) {
    vec2 prevCoord = Reproject(screenPos).xy;

    if (saturate(prevCoord) == prevCoord && !worldTimeChanged) {
        vec3 viewPos = ScreenToViewSpace(screenPos);
        float currViewDistance = length(viewPos);

        vec4 prevLight = vec4(0.0);
        float sumWeight = 0.0;

        prevCoord += (prevTaaOffset - taaOffset) * 0.25;

        // Custom bilinear filter
        vec2 prevTexel = prevCoord * 0.5 * viewSize - vec2(0.5);
        ivec2 floorTexel = ivec2(floor(prevTexel));
        vec2 fractTexel = fract(prevTexel - floorTexel);

        float bilinearWeight[4] = {
            oms(fractTexel.x) * oms(fractTexel.y),
            fractTexel.x      * oms(fractTexel.y),
            oms(fractTexel.x) * fractTexel.y,
            fractTexel.x      * fractTexel.y
        };

        ivec2 offsetToBR = ivec2(halfViewSize.x, 0);
        ivec2 texelEnd = ivec2(halfViewEnd);

        for (uint i = 0u; i < 4u; ++i) {
            ivec2 sampleTexel = floorTexel + offset2x2[i];
            if (clamp(sampleTexel, ivec2(0), texelEnd) == sampleTexel) {
                vec3 sampleAux = texelFetch(colortex2, sampleTexel + offsetToBR, 0).rgb;

                if (abs((currViewDistance - sampleAux.z) - cameraVelocity) < 0.1 * abs(currViewDistance)) {
                    float weight = bilinearWeight[i];
                    weight *= pow8(saturate(dot(OctDecodeSnorm(sampleAux.xy), worldNormal)));

                    prevLight += texelFetch(colortex2, sampleTexel, 0) * weight;
                    sumWeight += weight;
                }
            }
        }

        if (sumWeight > EPS) {
            prevLight *= 1.0 / sumWeight;

            indirectHistory.a = min(prevLight.a + 1.0, RSM_MAX_ACCUM_FRAMES);

            float alpha = rcp(indirectHistory.a);

            float mipLevel = 2.0 * saturate(1.0 - indirectHistory.a * rcp(8.0));
            indirectHistory.rgb = textureLod(colortex3, screenPos.xy * 0.5, mipLevel).rgb;
            indirectHistory.rgb = mix(prevLight.rgb, indirectHistory.rgb, alpha);
            return;
        }
    }

    indirectHistory.rgb = textureLod(colortex3, screenPos.xy * 0.5, 2.0).rgb;
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

    if (currentCoord.y < 1.0) {
        ivec2 screenTexel = ivec2(gl_FragCoord.xy);

        if (currentCoord.x < 1.0) {
            ivec2 currentTexel = screenTexel << 1;
            // vec3 closestFragment = GetClosestFragment(currentTexel, depth);
            float depth = loadDepth0(currentTexel);

            if (depth > (1.0 - EPS)) {
                discard;
                return;
            }

            vec3 screenPos = vec3(currentCoord, depth);
            vec3 worldNormal = FetchWorldNormal(currentTexel);
            TemporalFilter(screenPos, worldNormal);
        } else {
            ivec2 currentTexel = (screenTexel << 1) - ivec2(int(viewWidth), 0);
            float depth = loadDepth0(currentTexel);

            if (depth > (1.0 - EPS)) {
                discard;
                return;
            }
            vec3 worldNormal = FetchWorldNormal(currentTexel);
            float viewDistance = length(ScreenToViewSpace(vec3(currentCoord - vec2(1.0, 0.0), depth)));

            indirectHistory = vec4(OctEncodeSnorm(worldNormal), viewDistance, 0.0);
        }
    }
}