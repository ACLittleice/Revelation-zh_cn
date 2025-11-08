/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

    Pass: Temporal Reprojection Anti-Aliasing
    Reference: https://github.com/playdeadgames/temporal

--------------------------------------------------------------------------------
*/

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 1,4 */
layout (location = 0) out vec4 temporalOut;
layout (location = 1) out vec3 clearOut;

#ifdef MOTION_BLUR
/* RENDERTARGETS: 1,4,3 */
layout (location = 2) out vec2 motionVectorOut;
#endif

//======// Input //===============================================================================//

// flat in float exposure;

//======// Uniform //=============================================================================//

#include "/lib/universal/Uniform.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Fetch.glsl"

vec3 GetClosestFragment(in ivec2 texel, in float depth) {
    vec3 closestFragment = vec3(texel, depth);

    for (uint i = 0u; i < 8u; ++i) {
        ivec2 sampleTexel = offset3x3N[i] + texel;
        float sampleDepth = loadDepth0(sampleTexel);
        closestFragment = sampleDepth < closestFragment.z ? vec3(sampleTexel, sampleDepth) : closestFragment;
    }

    closestFragment.xy *= viewPixelSize;
    return closestFragment;
}

// Lumiance aware perceptual weight
vec3 perceptualWeight(vec3 colorYCoCg) {
    return colorYCoCg * rcp(1.0 + colorYCoCg.x);
}

vec3 perceptualWeightInv(vec3 colorYCoCg) {
    return colorYCoCg * rcp(1.0 - colorYCoCg.x);
}

vec3 historyClipAABB(in vec3 history, in vec3 center, in vec3 extent) {
    vec3 delta = history - center;
    float maxUnit = maxOf(abs(delta / extent));

    if (maxUnit > 1.0) {
        return center + delta / maxUnit;
    }

    return history;
}

vec4 TemporalReprojection(in vec2 screenCoord, in vec2 motionVector) {
    ivec2 texel = uvToTexel(screenCoord + taaOffset * 0.5);

    vec3 currData = loadSceneMain(texel);
    vec2 prevCoord = screenCoord - motionVector;

    if (saturate(prevCoord) != prevCoord) return vec4(currData, 1.0);

    #ifdef TAA_SHARPEN
        vec4 temporalData = textureCatmullRomFastAntiRing(colortex1, prevCoord);
    #else
        vec4 temporalData = texture(colortex1, prevCoord);
    #endif

    vec3 prevData = sRGBToYCoCg(temporalData.rgb);
    currData = sRGBToYCoCg(currData);

    float currLum = currData.x, prevLum = prevData.x;
    float temporalContrast = saturate(abs(currLum - prevLum) / max(currLum, prevLum));

    #ifdef TAA_CLIPPING
        #define currentLoad(offset) sRGBToYCoCg(texelFetchOffset(colortex0, texel, 0, offset).rgb)
        #define mean(a, b, c, d, e, f, g, h, i) (a + b + c + d + e + f + g + h + i) * rcp(9.0)
        #define sqrMean(a, b, c, d, e, f, g, h, i) (a * a + b * b + c * c + d * d + e * e + f * f + g * g + h * h + i * i) * rcp(9.0)

        vec3 sample0 = currData;
        vec3 sample1 = currentLoad(ivec2(-1,  1));
        vec3 sample2 = currentLoad(ivec2( 0,  1));
        vec3 sample3 = currentLoad(ivec2( 1,  1));
        vec3 sample4 = currentLoad(ivec2(-1,  0));
        vec3 sample5 = currentLoad(ivec2( 1,  0));
        vec3 sample6 = currentLoad(ivec2(-1, -1));
        vec3 sample7 = currentLoad(ivec2( 0, -1));
        vec3 sample8 = currentLoad(ivec2( 1, -1));

        vec3 clipAvg = mean(sample0, sample1, sample2, sample3, sample4, sample5, sample6, sample7, sample8);
        vec3 clipAvg2 = sqrMean(sample0, sample1, sample2, sample3, sample4, sample5, sample6, sample7, sample8);
        vec3 clipStdDev = sqrt(abs(clipAvg2 - clipAvg * clipAvg)) * TAA_AGGRESSION;

        #if 1
            // Ellipsoid intersection clipping
            prevData -= clipAvg;
            prevData *= saturate(inversesqrt(sdot(prevData / clipStdDev)));
            prevData += clipAvg;
        #else
            // AABB clipping
            prevData = historyClipAABB(prevData, clipAvg, clipStdDev);
        #endif
    #endif

    // Subpixel sharpening
	prevData = mix(prevData, currData, sdot(fract(prevCoord * viewSize) - 0.5) * 0.5);

    float blendWeight = min(++temporalData.a, TAA_MAX_ACCUM_FRAMES);
    blendWeight *= 1.0 + sqr(temporalContrast) * TAA_ANTIFLICKER;

    currData = mix(perceptualWeight(prevData), perceptualWeight(currData), rcp(blendWeight));
    return vec4(YCoCgToSRGB(perceptualWeightInv(currData)), temporalData.a);
}

//======// Main //================================================================================//
void main() {
    clearOut = vec3(0.0); // Clear the output buffer for bloom tiles

	ivec2 screenTexel = ivec2(gl_FragCoord.xy);

    float depth = loadDepth0(screenTexel);
	vec2 screenCoord = gl_FragCoord.xy * viewPixelSize;

    #if RENDER_MODE == 1
        #ifdef TAA_CLOSEST_FRAGMENT
            vec3 closestFragment = GetClosestFragment(screenTexel, depth);
            vec2 motionVector = closestFragment.xy - Reproject(closestFragment).xy;
        #else
            vec2 motionVector = screenCoord - Reproject(vec3(screenCoord, depth)).xy;
        #endif

        #ifdef MOTION_BLUR
            motionVectorOut = depth < 0.56 ? motionVector * 0.25 : motionVector;
        #endif

        #ifdef TAA_ENABLED
            temporalOut = TemporalReprojection(screenCoord, motionVector);
        #else
            temporalOut = vec4(loadSceneMain(screenTexel), 1.0);
        #endif
    #else
        ivec2 srcTexel = uvToTexel(screenCoord + taaOffset * 0.5);
        temporalOut = vec4(loadSceneMain(srcTexel), 1.0);

        vec2 prevCoord = Reproject(vec3(screenCoord, depth)).xy;
        if (distance(prevCoord, screenCoord) < EPS) {
            vec4 prevData = texture(colortex1, prevCoord);

            temporalOut.rgb = mix(prevData.rgb, temporalOut.rgb, rcp(++prevData.a));
            temporalOut.a = prevData.a;
        }
    #endif
}
