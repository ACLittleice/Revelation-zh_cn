
#define PCSS_SEARCH_SAMPLES 8 // [4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 48 64]
#define PCSS_FILTER_SAMPLES 16 // [4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 48 64]

const float shadowDistanceRenderMul = 1.0; // [-1.0 1.0]
const float realShadowMapRes = float(shadowMapResolution) * MC_SHADOW_QUALITY;

//================================================================================================//

#include "Common.glsl"

vec3 WorldToShadowScreenSpace(in vec3 worldPos) {
	vec3 shadowClipPos = transMAD(shadowModelView, worldPos);
	shadowClipPos = projMAD(shadowProjection, shadowClipPos);

	return DistortShadowSpace(shadowClipPos) * 0.5 + 0.5;
}

vec3 WorldToShadowScreenSpace(in vec3 worldPos, out float distortionFactor) {
	vec3 shadowClipPos = transMAD(shadowModelView, worldPos);
	shadowClipPos = projMAD(shadowProjection, shadowClipPos);

	distortionFactor = CalcDistortionFactor(shadowClipPos.xy);
	return DistortShadowSpace(shadowClipPos, distortionFactor) * 0.5 + 0.5;
}

//================================================================================================//

uniform sampler2DShadow shadowtex1;
uniform sampler2D shadowtex0;
uniform sampler2D shadowcolor0;
uniform sampler2D shadowcolor1;

float BlockerSearch(in vec3 shadowScreenPos, in float dither, in float searchScale) {
	float blockerDepth = 0.0;
	float sumWeight = 0.0;

	vec2 searchRadius = searchScale * diagonal2(shadowProjection);

	for (uint i = 0u; i < PCSS_SEARCH_SAMPLES; ++i) {
		vec2 sampleCoord = shadowScreenPos.xy + sampleVogelDisk(i, PCSS_SEARCH_SAMPLES, dither) * searchRadius;

		float sampleDepth = texelFetch(shadowtex0, ivec2(sampleCoord * realShadowMapRes), 0).x;
		float weight = step(sampleDepth, shadowScreenPos.z);

		blockerDepth += sampleDepth * weight;
		sumWeight += weight;
	}

	blockerDepth *= 1.0 / sumWeight;
	blockerDepth = clamp(2.0 * (shadowScreenPos.z - blockerDepth) / blockerDepth, 0.025, 0.25);

	return blockerDepth;
}

vec2 BlockerSearchSSS(in vec3 shadowScreenPos, in float dither, in float searchScale) {
	float blockerDepth = 0.0;
	float sumWeight = 0.0;
	float sssDepth = 0.0;

	vec2 searchRadius = searchScale * diagonal2(shadowProjection);

	for (uint i = 0u; i < PCSS_SEARCH_SAMPLES; ++i) {
		vec2 sampleCoord = shadowScreenPos.xy + sampleVogelDisk(i, PCSS_SEARCH_SAMPLES, dither) * searchRadius;

		float sampleDepth = texelFetch(shadowtex0, ivec2(sampleCoord * realShadowMapRes), 0).x;
		float weight = step(sampleDepth, shadowScreenPos.z);

		sssDepth += max0(shadowScreenPos.z - sampleDepth);
		blockerDepth += sampleDepth * weight;
		sumWeight += weight;
	}

	blockerDepth *= 1.0 / sumWeight;
	blockerDepth = clamp(2.0 * (shadowScreenPos.z - blockerDepth) / blockerDepth, 0.025, 0.25);

	return vec2(blockerDepth, sssDepth * rcp(float(PCSS_SEARCH_SAMPLES)) * shadowProjectionInverse[2].z);
}

vec3 CalculateWaterCaustics(in vec3 worldPos, in float waterDepth, in float dither) {
	vec3 surfacePos = worldPos + vec3(0.0, 1.0, 0.0);

	float caustics = 0.0;
	for (int i = 0; i < 16; ++i) {
		vec3 samplePos = surfacePos;
		samplePos.xz += sampleVogelDisk(i, 16, dither) * 0.125;

		vec2 sampleCoord = WorldToShadowScreenSpace(samplePos - vec3(0.0, 1.0, 0.0)).xy;
		vec3 waveNormal = OctDecodeUnorm(texture(shadowcolor1, sampleCoord).xy);

		vec3 refractDir = refract(vec3(0.0, 1.0, 0.0), waveNormal, 1.0 / WATER_IOR);
		vec3 refractedPos = samplePos - refractDir * rcp(refractDir.y);

		caustics += saturate(1.0 - 512.0 * sdot(worldPos - refractedPos));
	}

	return -smin(-caustics, -0.2, 0.2) * exp2(-rLOG2 * waterExtinction * waterDepth);
}

vec3 PercentageCloserFilter(in vec3 shadowScreenPos, in vec3 worldPos, in float dither, in float penumbraScale) {
	const float rSteps = 1.0 / float(PCSS_FILTER_SAMPLES);

	vec2 penumbraRadius = penumbraScale * diagonal2(shadowProjection);

	vec3 result = vec3(0.0);
	vec2 waterData = vec2(0.0);

	for (uint i = 0u; i < PCSS_FILTER_SAMPLES; ++i) {
		vec2 offset = sampleVogelDisk(i, PCSS_FILTER_SAMPLES, dither) * penumbraRadius;
		vec2 sampleCoord = shadowScreenPos.xy + offset;

		float sampleDepth1 = textureLod(shadowtex1, vec3(sampleCoord, shadowScreenPos.z), 0).x;

	#ifdef COLORED_SHADOWS
		ivec2 sampleTexel = ivec2(sampleCoord * realShadowMapRes);
		float sampleDepth0 = texelFetch(shadowtex0, sampleTexel, 0).x;

		if (step(shadowScreenPos.z, sampleDepth0) != sampleDepth1) {
			float waterMask = texelFetch(shadowcolor1, sampleTexel, 0).w;
			if (waterMask > EPS) {
				waterData += vec2(sampleDepth0 - shadowScreenPos.z, 1.0);
			} else {
				result += pow4(texelFetch(shadowcolor0, sampleTexel, 0).rgb) * sampleDepth1;
			}
		} else
	#endif
		result += sampleDepth1;
	}

	result *= rSteps;

	#ifdef WATER_CAUSTICS
		if (waterData.y > EPS) {
			waterData.x /= waterData.y;

			float waterDepth = waterData.x * shadowProjectionInverse[2].z * 5.0;
			vec3 caustics = CalculateWaterCaustics(worldPos, waterDepth, dither);
			result += waterData.y * rSteps * (caustics - result);
		}
	#endif

	return result;
}

//================================================================================================//

float ScreenSpaceShadow(in vec3 viewPos, in vec3 viewNormal, in float dither, in float sssAmount) {
	float viewDist = length(viewPos);
	float NdotL = dot(viewLightVector, viewNormal);
	viewPos += viewDist * maxOf(viewPixelSize) / max(sqr(NdotL), 0.05) * 0.5 * viewNormal;

    float absorption = exp2(-0.125 * approxSqrt(viewDist) / sssAmount);

	float stepLength = -0.1 / float(SCREEN_SPACE_SHADOWS_SAMPLES) * viewPos.z;
	vec3 rayDir = viewLightVector * stepLength * oms(sssAmount * 0.5);
	rayDir = vec3(diagonal2(gbufferProjection) * rayDir.xy * 0.5, -rayDir.z);

	vec3 rayPos = vec3((diagonal2(gbufferProjection) * viewPos.xy + gbufferProjection[3].xy) * 0.5, -viewPos.z);
	rayPos += (dither + 0.5) * rayDir;

	float diffTolerance = 2e-2 + 1e-2 * viewDist;
	float result = 1.0;

	for (uint i = 0u; i < SCREEN_SPACE_SHADOWS_SAMPLES; ++i, rayPos += rayDir) {
		vec2 sampleCoord = rayPos.xy / rayPos.z + taaOffset * 0.5;
		if (any(greaterThan(abs(sampleCoord), vec2(0.5))) || result < 1e-2) break;

		ivec2 sampleTexel = uvToTexel(sampleCoord + 0.5);
		float sampleDepth = loadDepth0(sampleTexel);

		#if defined DISTANT_HORIZONS
			float difference;
			if (sampleDepth > 1.0 - EPS) {
				sampleDepth = loadDepth0DH(sampleTexel);
				difference = ScreenToViewDepthDH(sampleDepth) + rayPos.z;
			} else {
				difference = ScreenToViewDepth(sampleDepth) + rayPos.z;
			}
		#else
			float difference = ScreenToViewDepth(sampleDepth) + rayPos.z;
		#endif

		if (clamp(difference, 0.0, diffTolerance) == difference) result *= absorption;
	}

	return result;
}