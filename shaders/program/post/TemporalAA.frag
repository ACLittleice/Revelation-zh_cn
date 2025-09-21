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

vec3 historyClipAABB(in vec3 history, in vec3 clipMin, in vec3 clipMax) {
    vec3 center = 0.5 * (clipMax + clipMin);
    vec3 extent = 0.5 * (clipMax - clipMin);

    vec3 delta = history - center;
    float maxUnit = maxOf(abs(delta / extent));

    if (maxUnit > 1.0) {
        return center + delta / maxUnit;
    }

    return history;
}

float sinc(float x) {
    return sin(PI * x) / (PI * x);
}

float lanczos2(float x) {
    x = clamp(x, -2.0, 2.0);
    if (abs(x) < EPS) return 1.0;
    else return sinc(x) * sinc(x * 0.5);
}

vec3 textureLanczos(in sampler2D tex, in vec2 coord) {
	const int radius = 1;

	vec2 res = vec2(textureSize(tex, 0));
	coord = coord * res - 0.5;

    vec2 p = floor(coord);
    vec2 f = coord - p;

	ivec2 texel = ivec2(p);

    vec3 sum = vec3(0.0);
	float sumWeight = 0.0;

    for (int x = -radius; x <= radius; ++x) {
        float fx = lanczos2(float(x) - f.x);

        for (int y = -radius; y <= radius; ++y) {
			float fy = lanczos2(float(y) - f.y);
			float weight = fx * fy;

			vec3 sampleData = texelFetch(tex, texel + ivec2(x, y), 0).rgb;
            sum += sampleData * weight;
			sumWeight += weight;
        }
    }

    return sum * rcp(sumWeight);
}

// Lumiance aware perceptual weight
vec3 perceptualWeight(vec3 colorYCoCg) {
    return colorYCoCg * rcp(1.0 + colorYCoCg.x);
}

vec3 perceptualWeightInv(vec3 colorYCoCg) {
    return colorYCoCg * rcp(1.0 - colorYCoCg.x);
}

#define currentLoad(offset) sRGBToYCoCg(texelFetchOffset(colortex0, texel, 0, offset).rgb)

#define mean(a, b, c, d, e, f, g, h, i) (a + b + c + d + e + f + g + h + i) * rcp(9.0)
#define sqrMean(a, b, c, d, e, f, g, h, i) (a * a + b * b + c * c + d * d + e * e + f * f + g * g + h * h + i * i) * rcp(9.0)

vec4 TemporalReprojection(in vec2 screenCoord, in vec2 motionVector) {
    ivec2 texel = uvToTexel(screenCoord + taaOffset * 0.5);

    vec3 currData = loadSceneColor(texel);
    vec2 prevCoord = screenCoord - motionVector;

    if (saturate(prevCoord) != prevCoord) return vec4(currData, 1.0);

    #ifdef TAA_SHARPEN
        vec3 prevData = textureLanczos(colortex1, prevCoord).rgb;
    #else
        vec3 prevData = texture(colortex1, prevCoord).rgb;
    #endif

    vec3 sample0 = sRGBToYCoCg(currData);
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
    vec3 clipStdDev = sqrt(max0(clipAvg2 - clipAvg * clipAvg)) * TAA_AGGRESSION;

    #ifdef TAA_EI_CLIP
        // Ellipsoid intersection clipping
        prevData = sRGBToYCoCg(prevData) - clipAvg;
        prevData *= saturate(inversesqrt(sdot(prevData / clipStdDev)));
        prevData = prevData + clipAvg;
    #else
        // Use variance clipping instead
        vec3 clipMin = clipAvg - clipStdDev;
        vec3 clipMax = clipAvg + clipStdDev;
        prevData = historyClipAABB(sRGBToYCoCg(prevData), clipMin, clipMax);
    #endif

    float frameIndex = texture(colortex1, prevCoord).a;

    float alpha = min(++frameIndex, TAA_MAX_ACCUM_FRAMES);
    alpha /= alpha + 1.0;

    float currLum = sample0.x, prevLum = prevData.x;
    float unbiasedDiff = abs(currLum - prevLum) / max(currLum, prevLum);
	alpha *= 1.0 - sqr(saturate(unbiasedDiff)) * 0.25;

    currData = mix(perceptualWeight(sample0), perceptualWeight(prevData), alpha);
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
