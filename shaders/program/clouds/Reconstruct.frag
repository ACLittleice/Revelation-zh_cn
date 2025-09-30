/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

	Pass: Temporal reconstruct clouds

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

#include "/lib/atmosphere/Common.glsl"
#include "/lib/atmosphere/clouds/Common.glsl"

vec4 CatmullRomWeights(in float f) {
    return vec4(
        f * (-0.5 + f * (1.0 - 0.5 * f)),
        1.0 + f * f * (-2.5 + 1.5 * f),
        f * (0.5 + f * (2.0 - 1.5 * f)),
        f * f * (-0.5 + 0.5 * f)
    );
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
	const int radius = 2;

	vec2 res = textureSize(tex, 0);
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
	// Initialize
	cloudOut = vec4(0.0, 0.0, 0.0, 1.0);
	frameOut = 0u;

	vec2 screenCoord = gl_FragCoord.xy * viewPixelSize;

	const float currScale = rcp(float(CLOUD_TAAU_SCALE));
	vec2 currCoord = screenCoord * currScale - R2(frameCounter + 11) * viewPixelSize;
	currCoord = min(currCoord, currScale - viewPixelSize);

	// Fetch closest cloud depth
	float cloudDepth = minOf(textureGather(cloudDepthOriginTex, currCoord, 0));

	// Skip ground
	if (cloudDepth < EPS) {
		discard;
		return;
	}

	frameOut = 1u;

	vec2 prevCoord = ReprojectClouds(screenCoord, cloudDepth).xy;
	uint frameIndex = texture(colortex13, prevCoord).x;

	bool disocclusion = worldTimeChanged;
	// Offscreen invalidation
	disocclusion = disocclusion || saturate(prevCoord) != prevCoord;
	// Previous ground invalidation
	disocclusion = disocclusion || frameIndex < 1u;
	// Fov change invalidation
	// disocclusion = disocclusion || (gbufferProjection[0].x - gbufferPreviousProjection[0].x) > 0.25;

	if (disocclusion) {
		// Return smoothed origin
		cloudOut = textureBicubic(cloudOriginTex, currCoord);
	} else {
		vec4 prevData = textureLanczos(cloudReconstructTex, prevCoord);
		prevData = vec4(satU16f(prevData.rgb), saturate(prevData.a));

		vec2 centerPixel = currCoord * viewSize - 0.5;
		vec2 floorPixel = floor(centerPixel);
		vec2 fractPixel = centerPixel - floorPixel;

		// Catmull-Rom filter for current pixel
		vec4 weightX = CatmullRomWeights(fractPixel.x);
		vec4 weightY = CatmullRomWeights(fractPixel.y);

		vec4 currData = vec4(0.0);
		vec4 moment1  = vec4(0.0);
		vec4 moment2  = vec4(0.0);

		// Fetch 4x4 neighbour pixels
		ivec2 baseTexel = ivec2(floorPixel) - 1;
		for (uint y = 0u; y < 4u; ++y) {
			for (uint x = 0u; x < 4u; ++x) {
				vec4 sampleData = texelFetch(cloudOriginTex, baseTexel + ivec2(x, y), 0);
				currData += sampleData * weightX[x] * weightY[y];

				moment1 += sampleData;
				moment2 += sampleData * sampleData;
			}
		}
		moment1 *= 1.0 / 16.0;
		moment2 *= 1.0 / 16.0;

		// Ellipsoid intersection clipping
		#ifdef CLOUD_TAAU_CLIPPING
			vec4 clipStdDevInv = inversesqrt(maxEps(moment2 - moment1 * moment1));
			prevData -= moment1;
			prevData *= saturate(inversesqrt(sdot(prevData * clipStdDevInv * 0.25))) * 0.5 + 0.5;
			prevData += moment1;
		#endif

		// Accumulate
		frameOut = min(frameIndex + 1u, CLOUD_MAX_ACCUM_FRAMES);
		cloudOut = satU16f(mix(prevData, currData, rcp(float(frameOut))));
	}
}