/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

	Pass: Temporal reconstruct clouds
	Reference: https://www.intel.com/content/dam/develop/external/us/en/documents/checkerboard-rendering-for-real-time-upscaling-on-intel-integrated-graphics.pdf
			   https://developer.nvidia.com/sites/default/files/akamai/gameworks/samples/DeinterleavedTexturing.pdf

--------------------------------------------------------------------------------
*/

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 9,13 */
layout (location = 0) out vec4 cloudOut;
layout (location = 1) out uint frameOut;

//======// Uniform //=============================================================================//

uniform sampler2D cloudOriginTex;
uniform sampler2D cloudDepthOriginTex;

#include "/lib/universal/Uniform.glsl"

//======// SSBO //================================================================================//

#include "/lib/universal/SSBO.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Fetch.glsl"
#include "/lib/universal/Random.glsl"
#include "/lib/universal/Offset.glsl"

#include "/lib/atmosphere/Common.glsl"
#include "/lib/atmosphere/clouds/Common.glsl"

vec4 textureCatmullRom(in sampler2D tex, in vec2 coord) {
	vec2 res = vec2(textureSize(tex, 0));
	vec2 pixelSize = 1.0 / res;

	vec2 position = coord * res;
	vec2 centerPosition = floor(position - 0.5) + 0.5;

	vec2 f = position - centerPosition;

	vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
	vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
	vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
	vec2 w3 = f * f * (-0.5 + 0.5 * f);

	vec2 w12 = w1 + w2;

	vec2 tc0 = pixelSize * (centerPosition - 1.0);
	vec2 tc3 = pixelSize * (centerPosition + 2.0);
	vec2 tc12 = pixelSize * (centerPosition + w2 * rcp(w12));

	vec4 color = vec4(0.0);
	color += textureLod(tex, vec2(tc0.x, tc0.y), 0) * w0.x * w0.y;
	color += textureLod(tex, vec2(tc12.x, tc0.y), 0) * w12.x * w0.y;
	color += textureLod(tex, vec2(tc3.x, tc0.y), 0) * w3.x * w0.y;

	color += textureLod(tex, vec2(tc0.x, tc12.y), 0) * w0.x * w12.y;
	color += textureLod(tex, vec2(tc12.x, tc12.y), 0) * w12.x * w12.y;
	color += textureLod(tex, vec2(tc3.x, tc12.y), 0) * w3.x * w12.y;

	color += textureLod(tex, vec2(tc0.x, tc3.y), 0) * w0.x * w3.y;
	color += textureLod(tex, vec2(tc12.x, tc3.y), 0) * w12.x * w3.y;
	color += textureLod(tex, vec2(tc3.x, tc3.y), 0) * w3.x * w3.y;

	return color;
}

// Approximation from SMAA presentation from siggraph 2016
vec4 textureCatmullRomFast(in sampler2D tex, in vec2 coord, in const float sharpness) {
    vec2 position = viewSize * coord;
    vec2 centerPosition = floor(position - 0.5) + 0.5;
    vec2 f = position - centerPosition;
    vec2 f2 = f * f;
    vec2 f3 = f * f2;

    vec2 w0 = -sharpness        * f3 + 2.0 * sharpness         * f2 - sharpness * f;
    vec2 w1 = (2.0 - sharpness) * f3 - (3.0 - sharpness)       * f2 + 1.0;
    vec2 w2 = (sharpness - 2.0) * f3 + (3.0 - 2.0 * sharpness) * f2 + sharpness * f;
    vec2 w3 = sharpness         * f3 - sharpness               * f2;

    vec2 w12 = w1 + w2;

    vec2 tc0 = viewPixelSize * (centerPosition - 1.0);
    vec2 tc3 = viewPixelSize * (centerPosition + 2.0);
    vec2 tc12 = viewPixelSize * (centerPosition + w2 / w12);

    float l0 = w12.x * w0.y;
    float l1 = w0.x  * w12.y;
    float l2 = w12.x * w12.y;
    float l3 = w3.x  * w12.y;
    float l4 = w12.x * w3.y;

    vec4 color =  texture(tex, vec2(tc12.x, tc0.y )) * l0
                + texture(tex, vec2(tc0.x,  tc12.y)) * l1
                + texture(tex, vec2(tc12.x, tc12.y)) * l2
                + texture(tex, vec2(tc3.x,  tc12.y)) * l3
                + texture(tex, vec2(tc12.x, tc3.y )) * l4;

    return color / (l0 + l1 + l2 + l3 + l4);
}

float sinc(float x) {
    return sin(PI * x) / (PI * x);
}

float lanczos2(float x) {
    x = clamp(x, -2.0, 2.0);
    if (abs(x) < EPS) return 1.0;
    else return sinc(x) * sinc(x * 0.5);
}

vec4 textureLanczos(in sampler2D tex, in vec2 coord) {
	const int radius = 1;

	vec2 res = vec2(textureSize(tex, 0));
	coord = coord * res - 0.5;

    vec2 p = floor(coord);
    vec2 f = coord - p;

	ivec2 texel = ivec2(p);

    vec4 sum = vec4(0.0);
	float sumWeight = 0.0;

    for (int x = -radius; x <= radius; ++x) {
        float fx = lanczos2(float(x) - f.x);

        for (int y = -radius; y <= radius; ++y) {
			float fy = lanczos2(float(y) - f.y);
			float weight = fx * fy;

			vec4 sampleData = texelFetch(tex, texel + ivec2(x, y), 0);
            sum += sampleData * weight;
			sumWeight += weight;
        }
    }

    return sum * rcp(sumWeight);
}

#define currentLoad(offset) texelFetchOffset(cloudOriginTex, currTexel, 0, offset)

#define mean(a, b, c, d, e, f, g, h, i) (a + b + c + d + e + f + g + h + i) * rcp(9.0)
#define sqrMean(a, b, c, d, e, f, g, h, i) (a * a + b * b + c * c + d * d + e * e + f * f + g * g + h * h + i * i) * rcp(9.0)

vec3 ReprojectClouds(in vec2 coord, in float radius) {
	vec3 cloudPos = ScreenToViewVectorRaw(coord) * radius;
	cloudPos = transMAD(gbufferModelViewInverse, cloudPos); // To world space

	// Apply wind
	vec3 motionVector = vec3(0.0);
	if (radius < cloudMidRadius) {
		// Low clouds
		const float windAngle = radians(45.0);
		const vec3 windDir = vec3(cos(windAngle), 0.5, sin(windAngle));
		const vec3 windVelocity = windDir * CLOUD_LOW_WIND_SPEED;
		motionVector -= windVelocity;
	} else if (radius < cloudHighRadius) {
		// Mid clouds
		const float windAngle = radians(10.0);
		const vec2 windVelocity = vec2(cos(windAngle), sin(windAngle)) * CLOUD_MID_WIND_SPEED;
		motionVector.xz -= windVelocity;
	} else {
		// High clouds
		const float windAngle = radians(30.0);
		const vec2 windVelocity = vec2(cos(windAngle), sin(windAngle)) * CLOUD_HIGH_WIND_SPEED;
		motionVector.xz -= windVelocity;
	}
	motionVector *= worldTime - global.prevWorldTime;
	motionVector += cameraPosition - previousCameraPosition;

	cloudPos += motionVector; // To previous frame's world space
    cloudPos = transMAD(gbufferPreviousModelView, cloudPos); // To previous frame's view space
	cloudPos = projMAD(gbufferPreviousProjection, cloudPos) * rcp(-cloudPos.z); // To previous frame's NDC space

    return cloudPos * 0.5 + 0.5;
}

//======// Main //================================================================================//
void main() {
	cloudOut = vec4(0.0, 0.0, 0.0, 1.0);
	frameOut = 0u;

    ivec2 screenTexel = ivec2(gl_FragCoord.xy);
	float depth = loadDepth2(screenTexel);
	#if defined DISTANT_HORIZONS
		if (depth > 1.0 - EPS) depth = loadDepth0DH(screenTexel);
	#endif

	if (depth > 1.0 - EPS) {
		frameOut = 1u;

		vec2 screenCoord = gl_FragCoord.xy * viewPixelSize;

		const float currScale = rcp(float(CLOUD_CBR_SCALE));
		vec2 currCoord = min(screenCoord * currScale, currScale - viewPixelSize);

		float cloudDepth = minOf(textureGather(cloudDepthOriginTex, currCoord, 0));

		vec2 prevCoord = ReprojectClouds(screenCoord, cloudDepth).xy;
		uint frameIndex = texture(colortex13, prevCoord).x;

		bool disocclusion = worldTimeChanged;
		// Offscreen invalidation
		disocclusion = disocclusion || saturate(prevCoord) != prevCoord;
		// Previous land invalidation
		disocclusion = disocclusion || frameIndex < 1u;
		// Fov change invalidation
		// disocclusion = disocclusion || (gbufferProjection[0].x - gbufferPreviousProjection[0].x) > 0.25;

		if (disocclusion) {
			cloudOut = textureBicubic(cloudOriginTex, currCoord);
		} else {
			vec4 prevData = textureCatmullRom(cloudReconstructTex, prevCoord);
			prevData.rgb = sRGBToYCoCg(satU16f(prevData.rgb));
			frameOut = min(frameIndex + 1u, CLOUD_MAX_ACCUM_FRAMES);

			ivec2 currTexel = clamp(screenTexel / CLOUD_CBR_SCALE, ivec2(0), ivec2(viewSize) / CLOUD_CBR_SCALE - 1);
			vec4 currData = texelFetch(cloudOriginTex, currTexel, 0);

			// Checkerboard upscaling
			ivec2 offset = cloudCbrOffset[frameCounter % cloudRenderArea];
			if (screenTexel % CLOUD_CBR_SCALE == offset) {
				// Ellipsoid intersection clipping
				#ifdef CLOUD_EI_CLIP
					vec4 sample1 = currentLoad(ivec2(-1,  1));
					vec4 sample2 = currentLoad(ivec2( 0,  1));
					vec4 sample3 = currentLoad(ivec2( 1,  1));
					vec4 sample4 = currentLoad(ivec2(-1,  0));
					vec4 sample5 = currentLoad(ivec2( 1,  0));
					vec4 sample6 = currentLoad(ivec2(-1, -1));
					vec4 sample7 = currentLoad(ivec2( 0, -1));
					vec4 sample8 = currentLoad(ivec2( 1, -1));

					vec4 clipAvg = mean(currData, sample1, sample2, sample3, sample4, sample5, sample6, sample7, sample8);
					vec4 clipAvg2 = sqrMean(currData, sample1, sample2, sample3, sample4, sample5, sample6, sample7, sample8);

					vec4 clipStdDev = sqrt(maxEps(clipAvg2 - clipAvg * clipAvg)) * 4.0;
					prevData -= clipAvg;
					prevData *= saturate(inversesqrt(sdot(prevData / clipStdDev)));
					prevData += clipAvg;
				#endif

				float alpha = max0(float(frameOut - cloudRenderArea));
				alpha /= alpha + 1.0;

				float subpixelSharpen = sdot(fract(prevCoord * viewSize) * 2.0 - 1.0);
				alpha *= 1.0 - sqr(subpixelSharpen) * 0.5;

				// Accumulate
				cloudOut = mix(currData, prevData, alpha);
			} else {
				// Reuse
				cloudOut = prevData;
			}
		}

		cloudOut.rgb = YCoCgToSRGB(cloudOut.rgb);
	}
}