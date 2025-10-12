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
			https://blog.selfshadow.com/publications/s2016-shading-course/
			https://www.ea.com/frostbite/news/physically-based-sky-atmosphere-and-cloud-rendering
        [Högfeldt, 2016] Rurik Högfeldt. "Convincing Cloud Rendering: An Implementation of Real-Time Dynamic Volumetric Clouds in Frostbite". Department of Computer Science and Engineering, Gothenburg, Sweden, 2016.
            https://publications.lib.chalmers.se/records/fulltext/241770/241770.pdf
		[Bauer, 2019] Fabian Bauer. "Creating the Atmospheric World of Red Dead Redemption 2: A Complete and Integrated Solution". SIGGRAPH 2019.
			https://www.advances.realtimerendering.com/s2019/slides_public_release.pptx
        [Wrenninge et al., 2013] Magnus Wrenninge, Chris Kulla, Viktor Lundqvist. “Oz: The Great and Volumetric”. SIGGRAPH 2013 Talks.
            https://dl.acm.org/doi/10.1145/2504459.2504518

--------------------------------------------------------------------------------
*/

#if !defined INCLUDE_CLOUDS_SHAPE
#define INCLUDE_CLOUDS_SHAPE

#include "/lib/atmosphere/clouds/Common.glsl"

//================================================================================================//

float GetSmoothNoise(in vec2 coord) {
    vec2 whole = floor(coord);
    vec2 part = curve(coord - whole);

	ivec2 texel = ivec2(whole);

	float s0 = texelFetch(noisetex, texel % 256, 0).x;
	float s1 = texelFetch(noisetex, (texel + ivec2(1, 0)) % 256, 0).x;
	float s2 = texelFetch(noisetex, (texel + ivec2(0, 1)) % 256, 0).x;
	float s3 = texelFetch(noisetex, (texel + ivec2(1, 1)) % 256, 0).x;

    return mix(mix(s0, s1, part.x), mix(s2, s3, part.x), part.y);
}

// [Schneider, 2023]
float ValueErosion(in float value, in float oldMin) {
    return saturate((value - oldMin) / (1.0 - oldMin));
}

//================================================================================================//

float CloudMidDensity(in vec2 rayPos) {
	// Wind field
	const float windAngle = radians(10.0);
	const vec2 windVelocity = vec2(cos(windAngle), sin(windAngle)) * CLOUD_MID_WIND_SPEED;
	vec2 windOffset = windVelocity * worldTimeCounter;

	rayPos -= windOffset;

	float localCoverage = GetSmoothNoise(rayPos * 3e-5 + 32.0);
	localCoverage += texture(noisetex, rayPos * 7e-6).z;

	/* Altostratus clouds */
	if (localCoverage > 0.25) {
		// Curl noise to simulate wind, makes the positioning of the clouds more natural
		vec2 curlNoise = texture(curlNoiseTex, rayPos * 5e-5).xy * 5e-4;

		vec2 position = (rayPos - windOffset * 0.5) * 1e-6 + curlNoise;
		curlNoise *= 0.5;

		float altostratus = texture(noisetex, position * 32.0).z, weight = 0.7;
		position += altostratus * 2e-3;

		// Altostratus FBM
		for (uint i = 0u; i < 5u; ++i, weight *= 0.55) {
			position = position * 2.5 + curlNoise - windOffset * 1e-6;
			altostratus += weight * texture(noisetex, position).x;
		}
		altostratus *= 0.5;

		localCoverage = saturate(localCoverage - 0.8) * (1.5 + 1.5 * CLOUD_AS_COVERAGE);
		float density = saturate(altostratus + localCoverage - 1.25);
		return curve(density);
	}
}

// Adapted from [Schneider, 2022]
float CloudHighDensity(in vec2 rayPos) {
	// Wind field
	const float windAngle = radians(30.0);
	const vec2 windVelocity = vec2(cos(windAngle), sin(windAngle)) * CLOUD_HIGH_WIND_SPEED;
	vec2 windOffset = windVelocity * worldTimeCounter;

	// Curl noise to simulate wind, makes the positioning of the clouds more natural
	vec2 curlNoise = texture(curlNoiseTex, rayPos * 1e-4).xy * 0.02;
	vec2 position = (rayPos - windOffset) * 1e-4 + curlNoise;

	float density = 0.0;

	#ifdef CLOUD_CIRRUS
	/* Cirrus clouds */
	{
		float coverage = CLOUD_CI_COVERAGE - 1.25 + texture(cloudMapTex, position * 0.01).x;
		coverage = saturate(coverage + texture(noisetex, position * 0.02).z);
		position -= coverage * 0.25;

		if (coverage > cloudEpsilon) {
			float cirrus = textureTiling(nubisCirroTex, (position - windOffset * 1e-4) * 0.3).x;
			cirrus *= cirrus * saturate(cirrus + coverage) * 2.0;
			cirrus *= smoothstep(0.1, 0.9, coverage);

			density += cirrus;
		}
	}
	#endif
	#ifdef CLOUD_CIRROCUMULUS
	/* Cirrocumulus clouds */
	{
		float coverage = CLOUD_CC_COVERAGE - saturate(texture(noisetex, position * 0.01).z * 1.75);
		coverage = saturate(texture(noisetex, position * 0.05).z + coverage);

		if (coverage > cloudEpsilon) {
			float cirrocumulus = textureTiling(nubisCirroTex, (position - windOffset * 1e-4) * 0.3).z;
			cirrocumulus += texture(noisetex, position).z * 0.7 - 0.25;

			cirrocumulus *= cirrocumulus * saturate(cirrocumulus + coverage) * 2.0;
			cirrocumulus *= smoothstep(0.2, 0.8, coverage);

			density += sqr(saturate(cirrocumulus));
		}
	}
	#endif

	return density * 4.0;
}

//================================================================================================//

#if 0
	float GetVerticalProfile(in float heightFraction, in float cloudType) {
		return texture(verticalLut, vec2(cloudType, heightFraction)).x;
	}
#else
	float GetVerticalProfile(in float heightFraction, in float cloudType) {
		float stratus = sqr(remap(0.25, 0.1, heightFraction));
		float stratocumulus = saturate(heightFraction * 6.0) * remap(0.7, 0.2, heightFraction);
		float cumulus = saturate(heightFraction * 8.0) * remap(1.0, 0.6, heightFraction);

		float verticalProfile = mix(stratus, stratocumulus, saturate(cloudType * 2.0));
		return mix(verticalProfile, cumulus, saturate(cloudType * 2.0 - 1.0));
	}
#endif

float CloudVolumeDensity(in vec3 rayPos, out float heightFraction, out float dimensionalProfile, in bool detail) {
	// Remap the height of the clouds to the range of [0, 1]
	float rayRadius = sdot(rayPos); rayRadius *= inversesqrt(rayRadius);
	heightFraction = saturate((rayRadius - cumulusBottomRadius) * rcp(CLOUD_CU_THICKNESS));

	// Wind field
	const float windAngle = radians(45.0);
	const vec3 windDir = vec3(cos(windAngle), 0.5, sin(windAngle));
	const vec3 windVelocity = windDir * CLOUD_LOW_WIND_SPEED;
	vec3 windOffset = windVelocity * worldTimeCounter;

	rayPos -= windOffset;
	rayPos -= windDir * cumulusTopOffset * heightFraction;
	rayPos.xz += cameraPosition.xz;

	// Sample cloud map
	vec2 cloudMap = texture(cloudMapTex, rayPos.xz * rcp(cloudMapCovDist)).xy;

	// Coveage profile
	float coverage = saturate(mix(cloudMap.x, cloudMap.y + 0.2, sqr(wetness) * 0.75) * (4.0 * CLOUD_CU_COVERAGE));
	// coverage = pow(coverage, remap(heightFraction, 0.7, 0.8, 1.0, 1.0 - 0.5 * anvilBias));
	if (coverage < 0.25) return 0.0;

	// Vertical profile
	float cloudType = smoothstep(0.0, 1.25, cloudMap.y * coverage);
	float verticalProfile = GetVerticalProfile(heightFraction, cloudType);

	dimensionalProfile = saturate(verticalProfile * coverage);
	// if (dimensionalProfile < cloudEpsilon) return 0.0;

	vec3 position = rayPos * 3e-4;

	// Perlin-worley + fBm worley noise for base shape
	float baseNoise = curve(texture(baseNoiseTex, position).x);

	float cloudDensity = ValueErosion(dimensionalProfile, 1.0 - baseNoise);
	if (cloudDensity < cloudEpsilon) return 0.0;

	// Detail erosion
	float detailNoise = 0.5;
	#if !defined PASS_SKY_VIEW
	if (detail) {
		// vec3 curlNoise = texture(curlNoiseTex, position.xz * 2.0).xyz;
		position += /* curlNoise * 0.05 * oms(heightFraction) -  */windOffset * 1e-4;

		// fBm worley noise for detail shape
		detailNoise = texture(detailNoiseTex, position * 8.0).x;

		// Transition from wispy shapes to billowy shapes over height
		// detailNoise = mix(detailNoise, 1.0 - detailNoise, saturate(heightFraction * 8.0));
	}
	#endif
	cloudDensity = remap(detailNoise * 0.25, 1.0, cloudDensity);

	// Density profile
	float densityProfile = saturate(heightFraction * 2.5) * saturate(5.0 - heightFraction * 5.0);
	return approxSqrt(cloudDensity) * densityProfile;
}

#endif