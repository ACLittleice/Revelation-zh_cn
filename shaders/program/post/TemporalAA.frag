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

float sinc(float x) {
    return sin(PI * x) / (PI * x);
}

float lanczos2(float x) {
    x = clamp(x, -2.0, 2.0);
    if (abs(x) < EPS) return 1.0;
    else return sinc(x) * sinc(x * 0.5);
}

vec3 textureLanczos(in sampler2D tex, in vec2 coord) {
	const int radius = 2;

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

// Approximation from SMAA presentation [Jimenez 2016]
vec4 textureCatmullRomFast(in sampler2D tex, in vec2 coord) {
    vec2 resolution = textureSize(tex, 0);
    vec2 pixelSize = 1.0 / resolution;

    vec2 pos = coord * resolution;
    vec2 tc1 = floor(pos - 0.5) + 0.5;
    vec2 f  = pos - tc1;
    vec2 f2 = f * f;
    vec2 f3 = f * f2;

    const float c = 0.5;
    vec2 w0  = -c         * f3 +  2.0 * c        * f2 - c * f;
    vec2 w1  =  (2.0 - c) * f3 - (3.0 - c)       * f2 + 1.0;
    vec2 w2  = -(2.0 - c) * f3 + (3.0 - 2.0 * c) * f2 + c * f;
    vec2 w3  = c          * f3 - c               * f2;
    vec2 w12 = w1 + w2;

    vec2 tc0  = pixelSize * (tc1 - 1.0);
    vec2 tc3  = pixelSize * (tc1 + 2.0);
    vec2 tc12 = pixelSize * (tc1 + w2 / w12);

    vec4 s0 = texture(tex, vec2(tc12.x,  tc0.y));
    vec4 s1 = texture(tex, vec2(tc0.x,  tc12.y));
    vec4 s2 = texture(tex, vec2(tc12.x, tc12.y));
    vec4 s3 = texture(tex, vec2(tc3.x,   tc0.y));
    vec4 s4 = texture(tex, vec2(tc12.x,  tc3.y));

    vec4 minColor = min(min(min(s0, s1), min(s2, s3)), s4);
    vec4 maxColor = max(max(max(s0, s1), max(s2, s3)), s4);

    float cw0 = w12.x * w0.y;
    float cw1 = w0.x  * w12.y;
    float cw2 = w12.x * w12.y;
    float cw3 = w3.x  * w12.y;
    float cw4 = w12.x * w3.y;

    s0 *= cw0;
    s1 *= cw1;
    s2 *= cw2;
    s3 *= cw3;
    s4 *= cw4;

    vec4 color = (s0 + s1 + s2 + s3 + s4) / (cw0 + cw1 + cw2 + cw3 + cw4);

    // Anti-ring from unity
    return clamp(color, minColor, maxColor);
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
        vec4 temporalData = textureCatmullRomFast(colortex1, prevCoord);
    #else
        vec4 temporalData = texture(colortex1, prevCoord);
    #endif

    vec3 prevData = sRGBToYCoCg(temporalData.rgb);
    currData = sRGBToYCoCg(currData);

    #ifdef TAA_CLIPPING
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
        vec3 clipStdDev = sqrt(max0(clipAvg2 - clipAvg * clipAvg));

        float currLum = currData.x, prevLum = prevData.x;
        float temporalContrast = saturate(abs(currLum - prevLum) / max(currLum, prevLum));
        clipStdDev *= (1.0 + temporalContrast) * TAA_AGGRESSION;

        // Ellipsoid intersection clipping
        prevData -= clipAvg;
        prevData *= saturate(inversesqrt(sdot(prevData / clipStdDev)));
        prevData += clipAvg;
    #endif

    float frameIndex = temporalData.a + 1.0;
    // frameIndex *= 1.0 - saturate(cameraVelocity * 0.02);
    // frameIndex *= 1.0 - saturate(length(motionVector * viewSize) * 0.02);

    float blendWeight = min(frameIndex, TAA_MAX_ACCUM_FRAMES);
    blendWeight /= blendWeight + 1.0;

    float subpixelSharpen = sdot(fract(prevCoord * viewSize) * 2.0 - 1.0);
    blendWeight *= 1.0 - approxSqrt(saturate(subpixelSharpen)) * 0.125;

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
