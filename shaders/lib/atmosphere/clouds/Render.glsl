/*
--------------------------------------------------------------------------------

	References:
		[Schneider, 2015] Andrew Schneider. “The Real-Time Volumetric Cloudscapes Of Horizon: Zero Dawn”. SIGGRAPH 2015.
			https://www.slideshare.net/guerrillagames/the-realtime-volumetric-cloudscapes-of-horizon-zero-dawn
		[Schneider, 2016] Andrew Schneider. "GPU Pro 7: Real Time Volumetric Cloudscapes". p.p. (97-128) CRC Press, 2016.
			https://www.taylorfrancis.com/chapters/edit/10.1201/b21261-11/real-time-volumetric-cloudscapes-andrew-schneider
		[Schneider, 2017] Andrew Schneider. "Nubis: Authoring Realtime Volumetric Cloudscapes with the Decima Engine". SIGGRAPH 2017.
			https://advances.realtimerendering.com/s2017/Nubis%20-%20Authoring%20Realtime%20Volumetric%20Cloudscapes%20with%20the%20Decima%20Engine%20-%20Final.pptx
		[Schneider, 2022] Andrew Schneider. "Nubis, Evolved: Real-Time Volumetric Clouds for Skies, Environments, and VFX". SIGGRAPH 2022.
			https://advances.realtimerendering.com/s2022/SIGGRAPH2022-Advances-NubisEvolved-NoVideos.pdf
		[Schneider, 2023] Andrew Schneider. "Nubis Cubed: Methods (and madness) to model and render immersive real-time voxel-based clouds". SIGGRAPH 2023.
			https://advances.realtimerendering.com/s2023/Nubis%20Cubed%20(Advances%202023).pdf
		[Hillaire, 2016] Sebastien Hillaire. “Physically based Sky, Atmosphere and Cloud Rendering”. SIGGRAPH 2016.
			https://www.ea.com/frostbite/news/physically-based-sky-atmosphere-and-cloud-rendering
		[Bauer, 2019] Fabian Bauer. "Creating the Atmospheric World of Red Dead Redemption 2: A Complete and Integrated Solution". SIGGRAPH 2019.
			https://www.advances.realtimerendering.com/s2019/slides_public_release.pptx

--------------------------------------------------------------------------------
*/

#include "/lib/atmosphere/clouds/Shape.glsl"

//================================================================================================//

float CloudVolumeSunlightOD(in vec3 rayPos, in float lightNoise) {
    const float stepSize = 256.0 / float(CLOUD_CU_SUNLIGHT_SAMPLES);
	vec4 rayStep = vec4(cloudLightVector, 1.0) * stepSize;

    float opticalDepth = 0.0;

	for (uint i = 0u; i < CLOUD_CU_SUNLIGHT_SAMPLES; ++i, rayPos += rayStep.xyz) {
        rayStep *= 1.5;

		float density = CloudVolumeDensity(rayPos + rayStep.xyz * lightNoise, opticalDepth < 0.25 * rayStep.w);
        opticalDepth += density * rayStep.w;
    }

    return opticalDepth * cumulusExtinction;
}

float CloudVolumeSkylightOD(in vec3 rayPos, in float lightNoise) {
    const float stepSize = 256.0 / float(CLOUD_CU_SKYLIGHT_SAMPLES);
	vec4 rayStep = vec4(vec3(0.0, 1.0, 0.0), 1.0) * stepSize;

    float opticalDepth = 0.0;

	for (uint i = 0u; i < CLOUD_CU_SKYLIGHT_SAMPLES; ++i, rayPos += rayStep.xyz) {
        rayStep *= 1.5;

		float density = CloudVolumeDensity(rayPos + rayStep.xyz * lightNoise, false);
        opticalDepth += density * rayStep.w;
    }

    return opticalDepth * cumulusExtinction;
}

float CloudVolumeGroundLightOD(in float density, in float height) {
	// Estimate the light optical depth of the ground from the cloud volume
    return density * height * (CLOUD_CU_ALTITUDE * cumulusExtinction);
}

float CloudMultiScatteringApproximation(in float opticalDepth, in float phases[cloudMsCount]) {
	float scatteringFalloff = cloudMsFalloffS;
	float extinctionFalloff = cloudMsFalloffE;

	// opticalDepth has already been multiplied by -rLOG2 so we can use exp2() directly
	float scattering = exp2(opticalDepth) * phases[0];

	for (uint ms = 1u; ms < cloudMsCount; ++ms) {
		scattering += exp2(opticalDepth * extinctionFalloff) * phases[ms] * scatteringFalloff;

		scatteringFalloff *= scatteringFalloff;
		extinctionFalloff *= extinctionFalloff;
	}

	return scattering;
}

//================================================================================================//

vec3 RenderCloudMid(in vec2 rayPos, in vec3 rayDir, in float lightNoise, in float phases[cloudMsCount]) {
	float density = CloudMidDensity(rayPos);
	if (density > EPS) {
		float opticalDepth = density * CLOUD_MID_THICKNESS / abs(rayDir.y);
		float absorption = oms(exp2(-rLOG2 * stratusExtinction * opticalDepth));

		float opticalDepthSun = 0.0; {
			const float stepSize = 64.0 / float(CLOUD_MID_SUNLIGHT_SAMPLES);
			vec3 rayStep = vec3(cloudLightVector.xz, 1.0) * stepSize;

			// Compute the optical depth of sunlight through clouds
			for (uint i = 0u; i < CLOUD_MID_SUNLIGHT_SAMPLES; ++i, rayPos += rayStep.xy) {
				rayStep *= 2.0;

				float density = CloudMidDensity(rayPos + rayStep.xy * lightNoise);

				opticalDepthSun += density * rayStep.z;
			}

			opticalDepthSun *= stratusExtinction * -rLOG2;
		}

		// Approximate sunlight multi-scattering
		float scatteringSun = CloudMultiScatteringApproximation(opticalDepthSun, phases);

		float opticalDepthSky = density * (CLOUD_MID_THICKNESS * stratusExtinction * -rLOG2);

		// Compute skylight multi-scattering
		// See slide 85 of [Schneider, 2017]
		// Original formula: Energy = max( exp( - density_along_light_ray ), (exp(-density_along_light_ray * 0.25) * 0.7) )
		float scatteringSky = exp2(max(opticalDepthSky, opticalDepthSky * 0.25 - 0.5));

		// Compute powder effect
		// Formula from [Schneider, 2015]
		// float powder = 2.0 * oms(exp2(-(density * 32.0 + 0.1)));

		// TODO: Better implementation
		float inScatterProbability = oms(exp2(-(density * 32.0 + 0.2)));

		scatteringSun *= absorption * inScatterProbability;
		scatteringSky *= absorption;
		return vec3(scatteringSun, scatteringSky, absorption);
	}
}

//================================================================================================//

vec3 RenderCloudHigh(in vec2 rayPos, in vec3 rayDir, in float lightNoise, in float phases[cloudMsCount]) {
	float density = CloudHighDensity(rayPos);
	if (density > EPS) {
		float opticalDepth = density * CLOUD_HIGH_THICKNESS / abs(rayDir.y);
		float absorption = oms(exp2(-rLOG2 * cirrusExtinction * opticalDepth));

		float opticalDepthSun = 0.0; {
			const float stepSize = 64.0 / float(CLOUD_HIGH_SUNLIGHT_SAMPLES);
			vec3 rayStep = vec3(cloudLightVector.xz, 1.0) * stepSize;

			// Compute the optical depth of sunlight through clouds
			for (uint i = 0u; i < CLOUD_HIGH_SUNLIGHT_SAMPLES; ++i, rayPos += rayStep.xy) {
				rayStep *= 2.0;

				float density = CloudHighDensity(rayPos + rayStep.xy * lightNoise);

				opticalDepthSun += density * rayStep.z;
			}

			opticalDepthSun *= cirrusExtinction * -rLOG2;
		}

		// Approximate sunlight multi-scattering
		float scatteringSun = CloudMultiScatteringApproximation(opticalDepthSun, phases);

		float opticalDepthSky = density * (CLOUD_HIGH_THICKNESS * cirrusExtinction * -rLOG2);

		// Compute skylight multi-scattering
		// See slide 85 of [Schneider, 2017]
		// Original formula: Energy = max( exp( - density_along_light_ray ), (exp(-density_along_light_ray * 0.25) * 0.7) )
		float scatteringSky = exp2(max(opticalDepthSky, opticalDepthSky * 0.25 - 0.5));

		// Compute powder effect
		// Formula from [Schneider, 2015]
		// float powder = 2.0 * oms(exp2(-(density * 32.0 + 0.1)));

		// TODO: Better implementation
		float inScatterProbability = oms(exp2(-(density * 32.0 + 0.2)));

		scatteringSun *= absorption * inScatterProbability;
		scatteringSky *= absorption;
		return vec3(scatteringSun, scatteringSky, absorption);
	}
}

//================================================================================================//

// Referring to Unreal Engine
float[cloudMsCount] SetupParticipatingMediaPhases(in float primaryPhase, in float falloff) {
	float phases[cloudMsCount];
	phases[0] = primaryPhase;

	for (uint ms = 1u; ms < cloudMsCount; ++ms) {
		phases[ms] = mix(uniformPhase, primaryPhase, falloff);
		falloff *= falloff;
	}

	return phases;
}

vec4 RenderClouds(in vec3 rayDir/* , in vec3 skyRadiance */, in float dither, out float cloudDepth) {
	float LdotV = dot(cloudLightVector, rayDir);

	// Compute phases for clouds' sunlight multi-scattering
	float phase = TripleLobePhase(LdotV, cloudForwardG, cloudBackwardG, cloudLobeMixer, cloudSilverG, cloudSilverI);
	// float phase = HgDrainePhase(LdotV, 35.0);
	float phases[cloudMsCount] = SetupParticipatingMediaPhases(phase, cloudMsFalloffP);

	float r = viewerHeight; // length(camera)
	float mu = rayDir.y;	// dot(camera, rayDir) / r

	vec3 cloudViewerPos = vec3(cameraPosition.xz, r).xzy;

	// Initialize
	vec2 integralScattering = vec2(0.0);
	float cloudTransmittance = 1.0;
	cloudDepth = 128e3;

	//================================================================================================//

	// Low-level clouds
	#ifdef CLOUD_CUMULUS
		if (!((mu < 0.0 && r < cumulusBottomRadius) || (mu > 0.0 && r > cumulusTopRadius))) {

			// Compute cloud spherical shell intersection
			vec2 intersection = RaySphericalShellIntersection(r, mu, cumulusBottomRadius, cumulusTopRadius);

			// Intersect the volume
			if (intersection.y > 0.0) {
				float withinVolumeSmooth = remap(CLOUD_CU_THICKNESS + 32.0, CLOUD_CU_THICKNESS - 64.0, abs(r * 2.0 - (cumulusBottomRadius + cumulusTopRadius)));

				float rayLength = clamp(intersection.y - intersection.x, 0.0, 1e5 - withinVolumeSmooth * 6e4);

				#if defined PASS_SKY_VIEW
					uint raySteps = CLOUD_CU_SAMPLES >> 1u;
					// Reduce ray steps for vertical rays
					raySteps = uint(float(raySteps) * oms(abs(mu) * 0.5));
				#else
					uint raySteps = CLOUD_CU_SAMPLES;
					// Reduce ray steps for vertical rays
					raySteps = uint(float(raySteps) * mix(oms(abs(mu) * 0.5), 4.0, withinVolumeSmooth));
				#endif

				// From [Schneider, 2022]
				// const float nearStepSize = 3.0;
				// const float farStepSizeOffset = 60.0;
				// const float stepAdjustmentDistance = 16384.0;

				// float stepSize = nearStepSize + (farStepSizeOffset / stepAdjustmentDistance) * rayLength;

				float stepSize = rayLength * rcp(float(raySteps));

				float startLength = intersection.x + stepSize * dither;
				vec3 rayPos = startLength * rayDir + cloudViewerPos;
				vec3 rayStep = stepSize * rayDir;

				float rayLengthWeighted = 0.0;
				float raySumWeight = 0.0;

				vec2 stepScattering = vec2(0.0);
				float transmittance = 1.0;

				// float cloudTest = 0.0;
				// uint zeroDensityCounter = 0u;

				// Raymarch through the cloud volume
				for (uint i = 1u; i <= raySteps; ++i) {
					// Advance to the next sample position
					rayPos += rayStep;

					// Accumulate the weighted ray length
					rayLengthWeighted += stepSize * float(i) * transmittance;
					raySumWeight += transmittance;

					// if (cloudTest < EPS) {
					// 	cloudTest = CloudVolumeDensity(rayPos, false);
					// 	if (cloudTest < EPS) {
					// 		rayPos += rayStep;
					// 	}
					// 	continue;
					// }

					// Compute sample cloud density
					float heightFraction, dimensionalProfile;
					float stepDensity = CloudVolumeDensity(rayPos, heightFraction, dimensionalProfile);

					if (stepDensity < EPS) continue;

					// if (stepDensity < EPS) {
					// 	++zeroDensityCounter;
					// }

					// if (zeroDensityCounter > 5u) {
					// 	cloudTest = 0.0;
					// 	zeroDensityCounter = 0u;
					// 	continue;
					// }

					#if defined PASS_SKY_VIEW
						vec2 lightNoise = vec2(0.5);
					#else
						// Compute light noise
						vec2 lightNoise = hash2(fract(rayPos));
					#endif

					// Compute the optical depth of sunlight through clouds
					float opticalDepthSun = CloudVolumeSunlightOD(rayPos, lightNoise.x) * -rLOG2;

					// Nubis Multiscatter Approximation
					// float msVolume = remap(0.15, 0.85, dimensionalProfile);
					// float scatteredEnergy = msVolume;

					// Approximate sunlight multi-scattering
					float scatteringSun = CloudMultiScatteringApproximation(opticalDepthSun, phases);

					// Compute the optical depth of skylight through clouds
					float opticalDepthSky = CloudVolumeSkylightOD(rayPos, lightNoise.y) * -rLOG2;

					// See slide 85 of [Schneider, 2017]
					// Original formula: Energy = max( exp( - density_along_light_ray ), (exp(-density_along_light_ray * 0.25) * 0.7) )
					float scatteringSky = exp2(max(opticalDepthSky, opticalDepthSky * 0.25 - 0.5));

					// Compute the optical depth of ground light through clouds
					float opticalDepthGround = CloudVolumeGroundLightOD(stepDensity, heightFraction);
					float scatteringGround = fastExp(-opticalDepthGround) * rPI;

					// Compute In-Scatter Probability
					// See slide 92 of [Schneider, 2017]
					// float depthProbability = 0.05 + pow(saturate(stepDensity * 8.0), remap(heightFraction, 0.3, 0.85, 0.5, 2.0));
					// float verticalProbability = pow(remap(heightFraction, 0.07, 0.14, 0.1, 1.0), 0.75);
					// float inScatterProbability = depthProbability * verticalProbability;
					// scatteringSun *= inScatterProbability;
					float inScatterProbability = pow(stepDensity * 2.0 + dimensionalProfile, 1.0 + heightFraction * 2.0);
					scatteringSun *= inScatterProbability * 2.0;

					// Nubis Ambient Scattering Approximation
					// float ambientProbability = approxSqrt(1.0 - dimensionalProfile);
					// scatteringSky *= ambientProbability;
					// scatteringGround *= ambientProbability;

					vec2 scattering = vec2(scatteringSun + scatteringGround * uniformPhase * cloudLightVector.y, 
										   scatteringSky + scatteringGround);

					float stepOpticalDepth = stepDensity * (cumulusExtinction * -rLOG2) * stepSize;
					float stepTransmittance = exp2(stepOpticalDepth);

					// Compute the integral of the scattering over the step
					float stepIntegral = transmittance * oms(stepTransmittance);
					stepScattering += scattering * stepIntegral;
					transmittance *= stepTransmittance;	

					// Break if the cloud has reached the minimum transmittance
					if (transmittance < minCloudTransmittance) break;
				}

				// Remap to [0, 1]
				transmittance = remap(minCloudTransmittance, 1.0, transmittance);

				// Update integral data
				if (transmittance < 1.0 - EPS) {
					integralScattering = stepScattering;
					cloudTransmittance = transmittance;
					cloudDepth = startLength + rayLengthWeighted / raySumWeight;
				}
			}
		}
	#endif

	//================================================================================================//

	bool planetIntersection = RayIntersectsGround(r, mu);

	// Mid-level clouds
	#ifdef CLOUD_ALTOSTRATUS
		if ((mu > 0.0 && r < cloudMidRadius) // Below clouds
		 || (planetIntersection && r > cloudMidRadius)) { // Above clouds
			float rayLength = (cloudMidRadius - r) / mu;
			vec3 rayPos = rayDir * rayLength + cloudViewerPos;

			vec3 cloudTemp = RenderCloudMid(rayPos.xz, rayDir, dither, phases);

			// Update integral data
			if (cloudTemp.z > EPS) {
				float transmittanceTemp = 1.0 - cloudTemp.z;

				// Blend layers
				integralScattering = r < cloudMidRadius ?
									 integralScattering + cloudTemp.xy * cloudTransmittance : // Below clouds
									 integralScattering * transmittanceTemp + cloudTemp.xy;  // Above clouds

				// Update transmittance
				cloudTransmittance *= transmittanceTemp;

				// Update cloud depth
				cloudDepth = min(rayLength, cloudDepth);
			}
		}
	#endif

	// High-level clouds
	#if defined CLOUD_CIRROCUMULUS || defined CLOUD_CIRRUS
		if ((mu > 0.0 && r < cloudHighRadius) // Below clouds
		 || (planetIntersection && r > cloudHighRadius)) { // Above clouds
			float rayLength = (cloudHighRadius - r) / mu;
			vec3 rayPos = rayDir * rayLength + cloudViewerPos;

			vec3 cloudTemp = RenderCloudHigh(rayPos.xz, rayDir, dither, phases);

			// Update integral data
			if (cloudTemp.z > EPS) {
				float transmittanceTemp = 1.0 - cloudTemp.z;

				// Blend layers
				integralScattering = r < cloudHighRadius ?
									 integralScattering + cloudTemp.xy * cloudTransmittance : // Below clouds
									 integralScattering * transmittanceTemp + cloudTemp.xy;  // Above clouds

				// Update transmittance
				cloudTransmittance *= transmittanceTemp;

				// Update cloud depth
				cloudDepth = min(rayLength, cloudDepth);
			}
		}
	#endif

	//================================================================================================//

    vec3 cloudScattering = vec3(0.0);

	// Composite
	if (cloudTransmittance < 1.0 - EPS) {
		// Trick to strengthen the aerial perspective
		// const float depthScale = 4.0;

		vec3 cloudPos = rayDir * cloudDepth;

		// Compute irradiance
		vec3 sunIrradiance, moonIrradiance;
		vec3 camera = vec3(0.0, viewerHeight, 0.0);
		vec3 skyIlluminance = GetSunAndSkyIrradiance(camera + cloudPos, worldSunVector, sunIrradiance, moonIrradiance) * skyIntensity;
		vec3 directIlluminance = sunIntensity * (sunIrradiance + moonIrradiance);

		skyIlluminance += lightningShading * 4e-3;
		#ifdef AURORA
			skyIlluminance += auroraShading;
		#endif

		// Direct + Indirect
		cloudScattering  = integralScattering.x * 2.0 * directIlluminance;
		cloudScattering += integralScattering.y * uniformPhase * skyIlluminance;

		// Compute aerial perspective
		#ifdef CLOUD_AERIAL_PERSPECTIVE
			vec3 airTransmittance;
			vec3 aerialPerspective = GetSkyRadianceToPoint(cloudPos, worldSunVector, airTransmittance) * skyIntensity;

			cloudScattering *= airTransmittance;
			cloudScattering += aerialPerspective * oms(cloudTransmittance);
		#endif
	}

	#ifdef AURORA
		if (auroraAmount > 1e-2) cloudScattering += NightAurora(rayDir) * cloudTransmittance;
	#endif

    return vec4(cloudScattering, cloudTransmittance);
}

//================================================================================================//

#include "/lib/atmosphere/clouds/Shadows.glsl"

uniform vec3 fmExtinction;
uniform vec3 fmScattering;
uniform vec3 frExtinction;
uniform vec3 frScattering;

vec4 RaymarchCrepuscular(in vec3 rayDir, in float dither) {
	uint steps = uint(float(CREPUSCULAR_RAYS_SAMPLES) * oms(abs(rayDir.y) * 0.5)); // Reduce ray steps for vertical rays

	// if (RayIntersectsGround(viewerHeight, rayDir.y) && viewerHeight < cumulusBottomRadius) return vec4(vec3(0.0), 1.0);

	// From planet to cumulus top
	vec2 intersection = RaySphericalShellIntersection(viewerHeight, rayDir.y, planetRadius, cumulusTopRadius);

	// Not intersecting the volume
	if (intersection.y < 0.0) return vec4(vec3(0.0), 1.0);

	float rayLength = clamp(intersection.y - intersection.x, 0.0, 8e3);
	float stepLength = rayLength * rcp(float(steps));

	// In shadow view space
	const float projectionScale = rcp(CLOUD_SHADOW_DISTANCE);

	vec3 rayStep = mat3(shadowModelView) * rayDir;
	vec3 rayPos = shadowModelView[3].xyz + rayStep * intersection.x;
	rayPos *= projectionScale;

	rayStep *= stepLength * projectionScale;
	rayPos += rayStep * dither;

	// Mie + Rayleigh
	float LdotV = dot(worldLightVector, rayDir);
	vec2 phase = vec2(CornetteShanksPhase(LdotV, 0.65), RayleighPhase(LdotV));

	vec3 extinctionCoeff = (fmExtinction * (1.0 + wetness * 2.0) + frExtinction) * (5e-7 * CREPUSCULAR_RAYS_INTENSITY);
	mat2x3 scatteringCoeff = mat2x3(fmScattering * (1.0 + wetness * 2.0), frScattering) * (5e-7 * CREPUSCULAR_RAYS_INTENSITY);

	vec3 stepTransmittance = exp2(-rLOG2 * extinctionCoeff * stepLength);

	vec3 scattering = vec3(0.0);
	vec3 transmittance = vec3(1.0);

	// Raymarch through the volume
	for (uint i = 0u; i < steps; ++i, rayPos += rayStep) {
		vec2 cloudShadowCoord = DistortCloudShadowPos(rayPos);
		float visibility = texture(colortex10, cloudShadowCoord).x;
		scattering += visibility * transmittance;

		transmittance *= stepTransmittance;
	}

	// Direct only
	scattering *= scatteringCoeff * phase * oms(stepTransmittance) / extinctionCoeff * loadDirectIllum();

	return vec4(scattering, approxSqrt(mean(transmittance)));
}