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

#define mean(a, b, c, d, e, f, g, h, i) (a + b + c + d + e + f + g + h + i) * rcp(9.0)
#define sqrMean(a, b, c, d, e, f, g, h, i) (a * a + b * b + c * c + d * d + e * e + f * f + g * g + h * h + i * i) * rcp(9.0)

vec4 TemporalReprojection(in vec2 screenCoord, in vec2 motionVector) {
    ivec2 texel = uvToTexel(screenCoord + taaOffset * 0.5);

    vec3 currData = loadSceneColor(texel);
    vec2 prevCoord = screenCoord - motionVector;

    if (saturate(prevCoord) != prevCoord) return vec4(currData, 1.0);

    #ifdef TAA_SHARPEN
        vec4 temporalData = textureCatmullRomFast(colortex1, prevCoord);
    #else
        vec4 temporalData = texture(colortex1, prevCoord);
    #endif

    vec3 prevData = sRGBToYCoCg(temporalData.rgb);
    currData = sRGBToYCoCg(currData);

    #ifdef TAA_CLIPPING
        #define currentLoad(offset) sRGBToYCoCg(texelFetchOffset(colortex0, texel, 0, offset).rgb)

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

        // Ellipsoid intersection clipping
        prevData -= clipAvg;
        prevData *= saturate(inversesqrt(sdot(prevData / clipStdDev)));
        prevData += clipAvg;
    #endif

    float frameIndex = temporalData.a + 1.0;
    // frameIndex *= 1.0 - saturate(cameraVelocity * 0.02);
    // frameIndex *= 1.0 - saturate(length(motionVector * viewSize) * 0.02);

    float currLum = currData.x, prevLum = prevData.x;
    float temporalContrast = saturate(abs(currLum - prevLum) / max(currLum, prevLum));

    float blendWeight = min(frameIndex, TAA_MAX_ACCUM_FRAMES);
    blendWeight *= 1.0 + sqr(temporalContrast) * TAA_ANTIFLICKER;

    float subpixelSharpen = sdot(fract(prevCoord * viewSize) - 0.5);
    blendWeight *= oms(saturate(subpixelSharpen) * 0.25) / (blendWeight + 1.0);

    currData = mix(perceptualWeight(currData), perceptualWeight(prevData), blendWeight);
    return vec4(YCoCgToSRGB(perceptualWeightInv(currData)), frameIndex);
}

//======// Main //================================================================================//
void main() {
    clearOut = vec3(0.0); // Clear the output buffer for bloom tiles

	ivec2 screenTexel = ivec2(gl_FragCoord.xy);

    float depth = loadDepth0(screenTexel);
	vec2 screenCoord = gl_FragCoord.xy * viewPixelSize;

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
        temporalOut = vec4(loadSceneColor(screenTexel), 1.0);
    #endif
}
