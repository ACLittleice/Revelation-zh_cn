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

#include "/lib/atmosphere/clouds/Common.glsl"

//================================================================================================//

const float cloudShadowDistortion = 0.75;

const mat4 cloudShadowProj = mat4(
	1.0 / CLOUD_SHADOW_DISTANCE, 0.0, 0.0, 0.0,
	0.0, 1.0 / CLOUD_SHADOW_DISTANCE, 0.0, 0.0,
	0.0, 0.0, -1.0 / CLOUD_SHADOW_DISTANCE, 0.0,
	0.0, 0.0, 0.0, 1.0
);

const mat4 cloudShadowProjInv = inverse(cloudShadowProj);

vec3 SetupCloudShadowPos(in vec2 coord) {
	// To NDC space
	vec3 shadowPos = vec3(coord * 2.0 - 1.0, 1.0);
	// Distortion
	shadowPos.xy *= oms(cloudShadowDistortion) / oms(length(shadowPos.xy) * cloudShadowDistortion);
	// To view space
	shadowPos = projMAD(cloudShadowProjInv, shadowPos);
	// To world space
	return transMAD(shadowModelViewInverse, shadowPos);
}

vec3 WorldToCloudShadowScreenPos(in vec3 worldPos) {
	// To view space
	vec3 shadowPos = transMAD(shadowModelView, worldPos);
	// To NDC space
	shadowPos = projMAD(cloudShadowProj, shadowPos);
	// Distortion
	shadowPos.xy *= rcp(length(shadowPos.xy) * cloudShadowDistortion + oms(cloudShadowDistortion));
	// To screen space
	return shadowPos * 0.5 + 0.5;
}

vec2 DistortCloudShadowPos(in vec2 shadowPos) {
	// Distortion
	shadowPos *= rcp(length(shadowPos) * cloudShadowDistortion + oms(cloudShadowDistortion));
	// To screen space
	return shadowPos * 0.5 + 0.5;
}

//================================================================================================//

#if defined PASS_CLOUD_SM
#include "/lib/atmosphere/clouds/Shape.glsl"

float CalculateCloudShadows(in vec3 rayPos) {
	const uint steps = CLOUD_SHADOW_SAMPLES;

	rayPos += vec3(0.0, viewerHeight, 0.0);

	vec2 intersection = RaySphericalShellIntersection(rayPos, worldLightVector, cumulusBottomRadius, cumulusTopRadius);
	float stepLength = (intersection.y - intersection.x) * rcp(float(steps));
	vec3 rayStep = worldLightVector * stepLength;

	rayPos += worldLightVector * intersection.x;
	// rayPos += rayStep * InterleavedGradientNoiseTemporal(gl_GlobalInvocationID.xy);

	float opticalDepth = 0.0;

	// Raymarch along the light vector
	for (uint i = 0u; i < steps; ++i, rayPos += rayStep) {
		float temp;
		opticalDepth += CloudVolumeDensity(rayPos, temp, temp, false);
		if (opticalDepth > float(steps) * 0.25) break;
	}

	float cloudShadow = exp2(-rLOG2 * cumulusExtinction * opticalDepth * stepLength);

	float timeFade = remap(0.05, 0.1, worldLightVector.y);
	return oms(timeFade) + cloudShadow * timeFade;
}
#endif