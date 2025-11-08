//================================================================================================//

mat2x3 AnalyticWaterFog(in float skylight, in float waterDepth, in float LdotV) {
	vec3 transmittance = exp2(-rLOG2 * waterExtinction * waterDepth);

	// float phase = clamp(FournierForandPhase(LdotV, 1.2, 3.3225), 0.0, 1e3);
	float phase = HenyeyGreensteinPhase(LdotV, 0.9) * 0.75 + uniformPhase * 0.25;
	const vec3 sunTransmittance = exp2(-rLOG2 * waterExtinction * 4.0);

	vec3 directIlluminance = global.light.directIlluminance;
	vec3 skyIlluminance = global.light.skyIlluminance;

	vec3 scattering = oms(wetnessCustom * 0.8) * phase * directIlluminance * sunTransmittance;
	scattering += uniformPhase * skyIlluminance;
	scattering *= oms(transmittance) * skylight;

	return mat2x3(scattering * (waterScattering / waterExtinction), transmittance);
}

//================================================================================================//

#if defined PASS_VOLUMETRIC_FOG
	#include "/lib/water/WaterWave.glsl"
	vec3 CalculateWaterCaustics(in vec3 shadowScreenPos, in float waterDepth) {
		vec3 waveNormal = OctDecodeUnorm(texture(shadowcolor1, shadowScreenPos.xy).xy);
		vec3 refractDir = refract(vec3(0.0, 1.0, 0.0), waveNormal, 1.0 / WATER_IOR);

		vec3 projectPos = vec3(0.0, 1.0, 0.0) - refractDir * rcp(refractDir.y);
		return saturate(1.0 - 8.0 * length(projectPos)) * exp2(-rLOG2 * waterExtinction * waterDepth);
	}

	mat2x3 RaymarchWaterFog(in vec3 worldPos, in float dither) {
		float rayLength = sdot(worldPos);
		float norm = inversesqrt(rayLength);
		rayLength = min(rayLength * norm, far);

		vec3 worldDir = worldPos * norm;

		const float rSteps = 1.0 / float(UW_VF_MAX_SAMPLES);

		float stepLength = min(rayLength, 32.0) * rSteps;

		vec3 shadowStep = mat3(shadowModelView) * worldDir * stepLength;
			 shadowStep = diagonal3(shadowProjection) * shadowStep;

		vec3 shadowStart = transMAD(shadowModelView, gbufferModelViewInverse[3].xyz);
			 shadowStart = projMAD(shadowProjection, shadowStart);
		vec3 shadowPos = shadowStart + shadowStep * dither;

		vec3 stepTransmittance = exp2(-rLOG2 * waterExtinction * stepLength);
		// vec3 lightVector = refract(worldLightVector, vec3(0.0, -1.0, 0.0), 1.0 / WATER_IOR);

		vec3 scatteringSun = vec3(0.0);
		vec3 transmittance = vec3(1.0);

		for (uint i = 0u; i < UW_VF_MAX_SAMPLES; ++i, shadowPos += shadowStep) {
			vec3 shadowScreenPos = DistortShadowSpace(shadowPos) * 0.5 + 0.5;
			if (saturate(shadowScreenPos) != shadowScreenPos) continue;

			ivec2 shadowTexel = ivec2(shadowScreenPos.xy * realShadowMapRes);
			vec3 sampleSunlight = vec3(step(shadowScreenPos.z, texelFetch(shadowtex1, shadowTexel, 0).x));

			float sampleDepth0 = texelFetch(shadowtex0, shadowTexel, 0).x;
			if (sampleSunlight.x != step(shadowScreenPos.z, sampleDepth0)) {
				float waterMask = texelFetch(shadowcolor1, shadowTexel, 0).w;
				if (waterMask > EPS) {
					float waterDepth = (sampleDepth0 - shadowScreenPos.z) * shadowProjectionInverse[2].z * 5.0;
					sampleSunlight = CalculateWaterCaustics(shadowScreenPos, waterDepth);
				}
			}

			scatteringSun += sampleSunlight * transmittance;
			transmittance *= stepTransmittance;
		}

		float LdotV = dot(worldLightVector, worldDir);
		// float phase = clamp(FournierForandPhase(LdotV, 1.2, 3.3225), 0.0, 1e3);
		float phase = HenyeyGreensteinPhase(LdotV, 0.9) * 0.75 + uniformPhase * 0.25;

		vec3 directIlluminance = global.light.directIlluminance;
		vec3 skyIlluminance = global.light.skyIlluminance;

		scatteringSun *= oms(wetnessCustom * 0.8) * phase * directIlluminance;
		vec3 scatteringSky = uniformPhase * skyIlluminance;

		transmittance = exp2(-rLOG2 * waterExtinction * rayLength);
		vec3 scattering = scatteringSun * oms(stepTransmittance) + scatteringSky * oms(transmittance);
		scattering *= waterScattering / waterExtinction;

		return mat2x3(scattering, transmittance);
	}
#endif