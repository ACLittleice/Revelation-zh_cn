uniform vec3 fogMieExtinction;
uniform vec3 fogMieScattering;
uniform vec3 fogRayleighExtinction;
uniform vec3 fogRayleighScattering;

uniform float biomeSandstorm;
uniform float biomeSnowstorm;

// x: Mie y: Rayleigh
const vec2 falloffScale = -1.0 / vec2(8.0, 32.0);
const float realShadowMapRes = float(shadowMapResolution) * MC_SHADOW_QUALITY;

vec2 CalculateFogDensity(in vec3 rayPos) {
	vec2 density = exp2(abs(VF_HEIGHT - rayPos.y) * falloffScale);

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

	density.x *= sqr(noise) * (2.0 + biomeSandstorm + biomeSnowstorm);
	return density;
}

#ifndef CLOUD_SHADOWS
	#undef VF_CLOUD_SHADOWS
#endif

mat2x3 RaymarchAtmosphericFog(in vec3 worldPos, in float dither) {
	#if defined DISTANT_HORIZONS
		#define far float(dhRenderDistance)
		uint steps = VF_MAX_SAMPLES << 1u;
	#else
		uint steps = VF_MAX_SAMPLES;
	#endif

	vec3 rayStart = gbufferModelViewInverse[3].xyz;

	float rayLength = sdot(worldPos);
	float norm = inversesqrt(rayLength);
	rayLength = min(rayLength * norm, far);

	vec3 worldDir = worldPos * norm;

	// Adaptive step count
	steps = min(steps, uint(float(steps) * 0.4 + rayLength * 0.1));

	float stepLength = rayLength * rcp(float(steps));

	vec3 rayStep = worldDir * stepLength;
	vec3 rayPos = rayStart + rayStep * dither + cameraPosition;

	vec3 shadowViewStart = transMAD(shadowModelView, rayStart);
	vec3 shadowStart = projMAD(shadowProjection, shadowViewStart);

	vec3 shadowViewStep = mat3(shadowModelView) * rayStep;
	vec3 shadowStep = diagonal3(shadowProjection) * shadowViewStep;
	vec3 shadowPos = shadowStart + shadowStep * dither;

	#ifdef VF_CLOUD_SHADOWS
		const vec2 projectionScale = diagonal2(cloudShadowProj);

		shadowViewStart.xy *= projectionScale;
		shadowViewStep.xy *= projectionScale;
		vec2 cloudShadowPos = shadowViewStart.xy + shadowViewStep.xy * dither;
	#endif

	float LdotV = dot(worldLightVector, worldDir);
	vec2 phase = vec2(HenyeyGreensteinPhase(LdotV, 0.65) * 0.75 + HenyeyGreensteinPhase(LdotV, -0.25) * 0.25, RayleighPhase(LdotV));
	phase.x = mix(uniformPhase, phase.x, 0.75); // Trick to fit the multi-scattering

	float uniformFog = 8.0 / far;

	vec3 scatteringSun = vec3(0.0);
	vec3 scatteringSky = vec3(0.0);
	vec3 transmittance = vec3(1.0);

	float mieDensityMult = VF_MIE_DENSITY * (1.0 + wetness * VF_MIE_DENSITY_RAIN_MULT);

	mat2x3 fogExtinctionCoeff = mat2x3(
		fogMieExtinction * mieDensityMult,
		fogRayleighExtinction * VF_RAYLEIGH_DENSITY
	);

	mat2x3 fogScatteringCoeff = mat2x3(
		fogMieScattering * mieDensityMult,
		fogRayleighScattering * VF_RAYLEIGH_DENSITY
	);

	for (uint i = 0u; i < steps; ++i, rayPos += rayStep, shadowPos += shadowStep) {
		vec2 stepFogmass = CalculateFogDensity(rayPos) + uniformFog;
		stepFogmass *= stepLength;

		if (dot(stepFogmass, vec2(1.0)) < 1e-5) continue; // Faster than maxOf()

    #if defined PASS_SKY_VIEW
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

		#ifdef VF_CLOUD_SHADOWS
			cloudShadowPos += shadowViewStep.xy;
			sampleShadow *= texture(cloudShadowTex, DistortCloudShadowPos(cloudShadowPos)).x;
		#endif
    #endif

		vec3 opticalDepth = fogExtinctionCoeff * stepFogmass;
		vec3 stepTransmittance = fastExp(-opticalDepth);

		vec3 stepScattering = transmittance * oms(stepTransmittance) / maxEps(opticalDepth);

		scatteringSun += fogScatteringCoeff * (stepFogmass * phase) * sampleShadow * stepScattering;
		scatteringSky += fogScatteringCoeff * stepFogmass * stepScattering;

		transmittance *= stepTransmittance;

		if (dot(transmittance, vec3(1.0)) < 1e-3) break; // Faster than maxOf()
	}

	#ifndef VF_CLOUD_SHADOWS
		scatteringSun *= 1.0 - wetness * 0.75;
	#endif

	vec3 directIlluminance = global.light.directIlluminance;
	vec3 skyIlluminance = global.light.skyIlluminance;

	vec3 scattering = scatteringSun * directIlluminance;
	scattering += scatteringSky * uniformPhase * skyIlluminance;
	scattering *= eyeSkylightSmooth;

	return mat2x3(scattering, transmittance);
}