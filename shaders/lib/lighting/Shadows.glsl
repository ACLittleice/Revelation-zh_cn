
#define PCF_SAMPLES 16 // [4 6 8 10 12 14 16 18 20 22 24 26 28 30 32 48 64]

const float shadowDistanceRenderMul = 1.0; // [-1.0 1.0]
const float realShadowMapRes = float(shadowMapResolution) * MC_SHADOW_QUALITY;

//================================================================================================//

#include "ShadowDistortion.glsl"

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
	float searchDepth = 0.0;
	float sumWeight = 0.0;

	vec2 searchRadius = searchScale * diagonal2(shadowProjection);

	// dither = TentFilter(dither);
	vec2 dir = cossin(dither * TAU) * searchRadius;
	const vec2 angleStep = cossin(TAU * 0.125);
	const mat2 rot = mat2(angleStep, -angleStep.y, angleStep.x);

	for (uint i = 0u; i < 8u; ++i, dir *= rot) {
		float radius = (float(i) + dither) * 0.125;
		vec2 sampleCoord = shadowScreenPos.xy + dir * radius;

		float sampleDepth = texelFetch(shadowtex0, ivec2(sampleCoord * realShadowMapRes), 0).x;
		float weight = step(sampleDepth, shadowScreenPos.z);

		searchDepth += sampleDepth * weight;
		sumWeight += weight;
	}

	searchDepth *= 1.0 / sumWeight;
	searchDepth = clamp(2.0 * (shadowScreenPos.z - searchDepth) / searchDepth, 0.025, 0.25);

	return searchDepth;
}

vec2 BlockerSearchSSS(in vec3 shadowScreenPos, in float dither, in float searchScale) {
	float searchDepth = 0.0;
	float sumWeight = 0.0;
	float sssDepth = 0.0;

	vec2 searchRadius = searchScale * diagonal2(shadowProjection);

	// dither = TentFilter(dither);
	vec2 dir = cossin(dither * TAU) * searchRadius;
	const vec2 angleStep = cossin(TAU * 0.125);
	const mat2 rot = mat2(angleStep, -angleStep.y, angleStep.x);

	for (uint i = 0u; i < 8u; ++i, dir *= rot) {
		float radius = (float(i) + dither) * 0.125;
		vec2 sampleCoord = shadowScreenPos.xy + dir * radius;

		float sampleDepth = texelFetch(shadowtex0, ivec2(sampleCoord * realShadowMapRes), 0).x;
		float weight = step(sampleDepth, shadowScreenPos.z);

		sssDepth += max0(shadowScreenPos.z - sampleDepth);
		searchDepth += sampleDepth * weight;
		sumWeight += weight;
	}

	searchDepth *= 1.0 / sumWeight;
	searchDepth = clamp(2.0 * (shadowScreenPos.z - searchDepth) / searchDepth, 0.025, 0.25);

	return vec2(searchDepth, sssDepth * shadowProjectionInverse[2].z);
}

vec3 CalculateWaterCaustics(in vec3 worldPos, in float waterDepth, in float dither) {
	vec3 surfacePos = worldPos + vec3(0.0, 1.0, 0.0);

	float caustics = 0.0;
	for (uint i = 0u; i < 16u; ++i) {
		vec3 samplePos = surfacePos;
		vec2 rand = fract(R2(i) + dither);
		samplePos.xz += sincos(rand.x * TAU) * approxSqrt(rand.y) * 0.15;

		vec2 sampleCoord = WorldToShadowScreenSpace(samplePos).xy;
		vec3 waveNormal = OctDecodeUnorm(texture(shadowcolor1, sampleCoord).xy);

		vec3 refractDir = fastRefract(vec3(0.0, 1.0, 0.0), waveNormal, 1.0 / WATER_REFRACT_IOR);
		vec3 refractedPos = samplePos - refractDir * rcp(refractDir.y);

		caustics += saturate(1.0 - 512.0 * sdot(worldPos - refractedPos));
	}

	return caustics * exp2(-rLOG2 * WATER_FOG_DENSITY * waterDepth * waterExtinction);
}

vec3 PercentageCloserFilter(in vec3 shadowScreenPos, in vec3 worldPos, in float dither, in float penumbraScale) {
	const float rSteps = 1.0 / float(PCF_SAMPLES);

	vec2 penumbraRadius = penumbraScale * diagonal2(shadowProjection);

	vec2 dir = cossin(dither * TAU) * penumbraRadius;
	const vec2 angleStep = cossin(TAU * rSteps);
	const mat2 rot = mat2(angleStep, -angleStep.y, angleStep.x);

	vec3 result = vec3(0.0);
	vec2 causticData = vec2(0.0);

	for (uint i = 0u; i < PCF_SAMPLES; ++i, dir *= rot) {
		float radius = (float(i) + dither) * rSteps;
		vec2 sampleCoord = shadowScreenPos.xy + dir * radius * inversesqrt(radius);

		float sampleDepth1 = textureLod(shadowtex1, vec3(sampleCoord, shadowScreenPos.z), 0).x;

	#ifdef COLORED_SHADOWS
		ivec2 sampleTexel = ivec2(sampleCoord * realShadowMapRes);
		float sampleDepth0 = step(shadowScreenPos.z, texelFetch(shadowtex0, sampleTexel, 0).x);
		if (sampleDepth0 != sampleDepth1) {
			float waterDepth = texelFetch(shadowcolor1, sampleTexel, 0).w;
			if (waterDepth > EPS) causticData += vec2(waterDepth, 1.0);
			else result += pow4(texelFetch(shadowcolor0, sampleTexel, 0).rgb) * sampleDepth1;
		} else
	#endif
		result += sampleDepth1;
	}

	result *= rSteps;

	#ifdef WATER_CAUSTICS
		if (causticData.y > EPS) {
			causticData.x /= causticData.y;

			float waterDepth = max0(causticData.x * 512.0 - 128.0 - worldPos.y - eyeAltitude);
			vec3 caustics = CalculateWaterCaustics(worldPos, waterDepth, dither);
			result += causticData.y * rSteps * (caustics - result);
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

	vec3 rayDir = viewLightVector * -viewPos.z * (0.1 / float(SCREEN_SPACE_SHADOWS_SAMPLES)) * oms(sssAmount * 0.5);
	rayDir = vec3(diagonal2(gbufferProjection) * rayDir.xy * 0.5, -rayDir.z);

	vec3 rayPos = vec3((diagonal2(gbufferProjection) * viewPos.xy + gbufferProjection[3].xy) * 0.5, -viewPos.z);
	rayPos += dither * rayDir;

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