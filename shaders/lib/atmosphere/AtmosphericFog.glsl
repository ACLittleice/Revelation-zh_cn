#include "/lib/atmosphere/Rainbow.glsl"

uniform float biomeSandstorm;
uniform float biomeSnowstorm;
uniform float biomeGreenVapor;

//================================================================================================//

// x: Mie y: Rayleigh
const vec2 falloffScale = -1.0 / vec2(8.0, 32.0);
const float realShadowMapRes = float(shadowMapResolution) * MC_SHADOW_QUALITY;

vec2 CalculateFogDensity(in vec3 rayPos, in float uniformFog) {
	rayPos += cameraPosition;

	// float rayLength = length(rayPos + vec3(0.0, planetRadius, 0.0));
	vec2 density = exp2(max0(rayPos.y - VF_HEIGHT) * falloffScale);

#if VF_NOISE_QUALITY == LOW
	rayPos.xz -= vec2(1.0, 0.75) * worldTimeCounter;

	float noise = texture(noisetex, rayPos.xz * 0.002).z;
#elif VF_NOISE_QUALITY == MEDIUM
	vec3 windOffset = vec3(0.07, 0.04, 0.05) * worldTimeCounter;

	rayPos *= 0.03;
	rayPos -= windOffset;
	float noise = Calculate3DNoise(rayPos) * 2.5;
	noise -= Calculate3DNoise(rayPos * 4.0 - windOffset);
#endif

	density.x *= sqr(noise) * (2.0 + biomeSandstorm * 8.0 + biomeSnowstorm * 4.0);
	density += uniformFog;

	return density * linearstep(cumulusTopAltitude, cumulusBottomAltitude, rayPos.y);
}

//================================================================================================//

#if !defined CLOUD_SHADOWS || defined PASS_SKY_MAP
	#undef VF_CLOUD_SHADOWS
#endif

mat2x3 RaymarchAtmosphericFog(in vec3 worldPos, in float dither, in bool skyMask) {
	#if defined DISTANT_HORIZONS
		#define far float(dhRenderDistance)
	#endif

	vec3 rayStart = gbufferModelViewInverse[3].xyz;

	float rayLength = sdot(worldPos);
	float norm = inversesqrt(rayLength);
	rayLength *= norm;

	vec3 worldDir = worldPos * norm;

	// Adaptive step count
	uint steps = VF_MAX_SAMPLES;
	steps = min(steps, uint(float(steps) * 0.4 + rayLength * rcp(16.0)));

	float maxRayLengh = max(far, 2e4);
	if (skyMask) {
		vec2 intersection = RaySphericalShellIntersection(viewerHeight, worldDir.y, planetRadius, cumulusTopRadius);

		// Not intersecting the volume
		if (intersection.y < 0.0 || viewerHeight > cumulusBottomRadius) return mat2x3(vec3(0.0), vec3(1.0));

		rayLength = clamp(intersection.y - intersection.x, 0.0, maxRayLengh);
		rayStart += worldDir * intersection.x;
		steps *= 2u;
	}

	float rSteps = rcp(float(steps));

	float stepLength = rayLength * rSteps;
	vec3 rayStep = stepLength * worldDir;
	vec3 rayPos = rayStart + rayStep * dither;

	vec3 shadowViewStart = transMAD(shadowModelView, rayStart);
	vec3 shadowStart = projMAD(shadowProjection, shadowViewStart);

	vec3 shadowViewStep = mat3(shadowModelView) * rayStep;
	vec3 shadowStep = diagonal3(shadowProjection) * shadowViewStep;
	vec3 shadowPos = shadowStart + shadowStep * dither;

	float LdotV = dot(worldLightVector, worldDir);
	vec2 phase = vec2(CornetteShanksPhase(LdotV, mie_phase_g), RayleighPhase(LdotV));

	float mieDensityMult = VF_MIE_DENSITY * (1.0 + wetness * VF_MIE_DENSITY_RAIN_MULT);

	#ifdef VF_TIME_FADE
		mieDensityMult *= max(wetness, 1.5 - approxSqrt(timeNoon) * 1.5 - timeSunset * 0.75 - timeMidnight * 0.5);
	#endif

	vec3 fogMieExtinction = atmosphereModel.mie_extinction * mieDensityMult;
	vec3 fogMieScattering = atmosphereModel.mie_scattering * mieDensityMult;

	#ifdef PER_BIOME_FOG
		vec3 biomeAlbedo = mix(vec3(1.0), vec3(1.1, 0.9, 0.7), biomeSandstorm);
		biomeAlbedo = mix(biomeAlbedo, vec3(0.95, 1.1, 1.0), biomeGreenVapor);
		fogMieScattering *= biomeAlbedo;
	#endif

	mat2x3 fogExtinctionCoeff = mat2x3(
		fogMieExtinction,
		atmosphereModel.rayleigh_scattering * VF_RAYLEIGH_DENSITY * 0.05
	);

	mat2x3 fogScatteringCoeff = mat2x3(
		fogMieScattering,
		atmosphereModel.rayleigh_scattering * VF_RAYLEIGH_DENSITY * 0.05
	);

	float uniformFog = (16.0 + wetness * VF_MIE_DENSITY_RAIN_MULT * 16.0) / maxRayLengh;

	vec3 scatteringSun = vec3(0.0);
	vec3 scatteringSky = vec3(0.0);
	vec3 transmittance = vec3(1.0);

	for (uint i = 0u; i < steps; ++i, rayPos += rayStep, shadowPos += shadowStep) {
		vec2 stepDensity = CalculateFogDensity(rayPos, uniformFog);

		if (dot(stepDensity, vec2(1.0)) < EPS) continue; // Faster than maxOf()

    #if defined PASS_SKY_MAP
        const float sampleShadow = 1.0;
    #else
		vec3 shadowScreenPos = DistortShadowSpace(shadowPos) * 0.5 + 0.5;
		#ifdef COLORED_VOLUMETRIC_FOG
			vec3 sampleShadow = vec3(1.0);
			if (saturate(shadowScreenPos) == shadowScreenPos) {
				ivec2 shadowTexel = ivec2(shadowScreenPos.xy * realShadowMapRes);
				sampleShadow = step(shadowScreenPos.z, vec3(texelFetch(shadowtex1, shadowTexel, 0).x));

				float sampleDepth0 = step(shadowScreenPos.z, texelFetch(shadowtex0, shadowTexel, 0).x);
				if (sampleShadow.x != sampleDepth0) {
					vec3 shadowColorSample = pow4(texelFetch(shadowcolor0, shadowTexel, 0).rgb);
					sampleShadow = shadowColorSample * (sampleShadow - sampleDepth0) + vec3(sampleDepth0);
				}
			}
		#else
			float sampleShadow = 1.0;
			if (saturate(shadowScreenPos) == shadowScreenPos) {
				ivec2 shadowTexel = ivec2(shadowScreenPos.xy * realShadowMapRes);
				sampleShadow = step(shadowScreenPos.z, texelFetch(shadowtex1, shadowTexel, 0).x);
			}
		#endif
    #endif

		#ifdef VF_CLOUD_SHADOWS
			vec2 cloudShadowCoord = WorldToCloudShadowScreenPos(rayPos).xy;

			if (saturate(cloudShadowCoord) == cloudShadowCoord) {
				float cloudShadow = texture(cloudShadowTex, cloudShadowCoord).x;
				sampleShadow *= cloudShadow;
			}
		#endif

		// Raymarch sunlight transmittance
		vec2 opticalDepthSun = vec2(0.0);

		float stepSize = 4.0;
		vec3 lightPos = rayPos;
		for (uint i = 0u; i < 3u; ++i) {
			stepSize *= 1.5;
			lightPos += worldLightVector * stepSize;

			vec2 density = CalculateFogDensity(lightPos, uniformFog);
			opticalDepthSun += density * stepSize;
		}

		// https://zhuanlan.zhihu.com/p/457997155
		vec2 msV = 0.8 * oms(exp2(-4.0 * stepDensity));
		vec2 msEnergy = phase * exp(-opticalDepthSun) + uniformPhase * msV / oms(msV);

		vec3 stepExtinction = fogExtinctionCoeff * stepDensity;
		vec3 stepTransmittance = exp(-stepLength * stepExtinction);

		vec3 stepIntegral = transmittance * oms(stepTransmittance) / maxEps(stepExtinction);

		scatteringSun += fogScatteringCoeff * (stepDensity * msEnergy * sampleShadow) * stepIntegral;
		scatteringSky += fogScatteringCoeff * stepDensity * stepIntegral;

		transmittance *= stepTransmittance;

		if (dot(transmittance, vec3(1.0)) < 1e-2) break; // Faster than maxOf()
	}

	#ifndef VF_CLOUD_SHADOWS
		scatteringSun *= 1.0 - wetness * CLOUD_SHADOW_STRENGTH;
	#endif
	scatteringSky *= eyeSkylightSmooth;

	// Apply rainbows
	#ifdef RAINBOWS
		float visibility = wetness * oms(rainStrength);
		if (visibility > EPS) {
			float distanceFade = saturate(rayLength / far) * visibility;
			scatteringSun *= 1.0 + RenderRainbows(LdotV) * distanceFade;
		}
	#endif

	vec3 scattering = scatteringSun * global.light.directIlluminance;
	scattering += scatteringSky * uniformPhase * global.light.skyIlluminance;

	return mat2x3(scattering, transmittance);
}