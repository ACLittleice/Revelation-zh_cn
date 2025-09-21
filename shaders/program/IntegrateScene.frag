/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

	Pass: Compute refraction, combine translucent, reflections and fog

--------------------------------------------------------------------------------
*/

#define PASS_COMPOSITE

//======// Utility //=============================================================================//

#include "/lib/Utility.glsl"

//======// Output //==============================================================================//

/* RENDERTARGETS: 0,12 */
layout (location = 0) out vec3 sceneOut;
layout (location = 1) out float bloomyFogMask;

//======// Uniform //=============================================================================//

uniform usampler2D colortex11; // Volumetric Fog, linear depth
uniform sampler2D brdfLutTex;

#if defined DEPTH_OF_FIELD && CAMERA_FOCUS_MODE == 0
    uniform float centerDepthSmooth;
#endif

#include "/lib/universal/Uniform.glsl"

//======// SSBO //================================================================================//

#include "/lib/universal/SSBO.glsl"

//======// Struct //==============================================================================//

#include "/lib/universal/Material.glsl"

//======// Function //============================================================================//

#include "/lib/universal/Transform.glsl"
#include "/lib/universal/Fetch.glsl"
#include "/lib/universal/Random.glsl"

#include "/lib/atmosphere/Common.glsl"
#include "/lib/atmosphere/Rainbow.glsl"
#include "/lib/atmosphere/CommonFog.glsl"

#include "/lib/SpatialUpscale.glsl"

#include "/lib/water/WaterFog.glsl"

#include "/lib/surface/BRDF.glsl"
#include "/lib/surface/Refraction.glsl"

//======// Main //================================================================================//
void main() {
    ivec2 screenTexel = ivec2(gl_FragCoord.xy);
    vec2 screenCoord = gl_FragCoord.xy * viewPixelSize;

	float depth = loadDepth0(screenTexel);

	vec3 screenPos = vec3(screenCoord, depth);
	vec3 viewPos = ScreenToViewSpace(screenPos);
	#if defined DISTANT_HORIZONS
		if (depth > 1.0 - EPS) {
			depth = screenPos.z = loadDepth0DH(screenTexel);
			viewPos = ScreenToViewSpaceDH(screenPos);
		}
	#endif

	uvec4 gbufferData0 = loadGbufferData0(screenTexel);

	uint materialID = gbufferData0.y;
	bool glassMask = materialID == 2u;
	bool waterMask = materialID == 3u;

	// Process refraction
	ivec2 refractedTexel = screenTexel;
	if (glassMask || waterMask) {
		vec3 viewNormal = mat3(gbufferModelView) * FetchWorldNormal(gbufferData0.w);

		#ifdef RAYTRACED_REFRACTION
			vec2 refractedCoord = CalculateRefractedCoord(waterMask, viewPos, viewNormal, screenPos);
		#else
			vec3 viewFlatNormal = mat3(gbufferModelView) * FetchFlatNormal(gbufferData0);
			viewNormal -= float(waterMask) * viewFlatNormal; // Fix water refraction artifacts

			float depth1 = loadDepth1(screenTexel);
			vec3 viewPos1 = ScreenToViewSpace(vec3(screenCoord, depth1));
			#if defined DISTANT_HORIZONS
				if (depth1 > 1.0 - EPS) {
					depth1 = loadDepth1DH(screenTexel);
					viewPos1 = ScreenToViewSpaceDH(vec3(screenCoord, depth1));
				}
			#endif
			vec2 refractedCoord = CalculateRefractedCoord(waterMask, viewPos, viewNormal, screenPos, distance(viewPos, viewPos1));
		#endif

		refractedTexel = uvToTexel(refractedCoord);
	}

    sceneOut = loadSceneColor(refractedTexel);
	vec3 worldNormal = FetchWorldNormal(gbufferData0);

	vec3 worldPos = mat3(gbufferModelViewInverse) * viewPos;
	vec3 worldDir = normalize(worldPos);

	if (depth < 1.0) {
		vec4 gbufferData1 = loadGbufferData1(screenTexel);

		#if defined SPECULAR_MAPPING && defined MC_SPECULAR_MAP
			Material material = GetMaterialData(gbufferData1.xy);

			if (material.specularMask) {
				// Specular reflections of other materials
				vec3 specularLight = texelFetch(colortex3, screenTexel, 0).rgb;
				vec3 albedo = sRGBtoLinear(loadAlbedo(screenTexel));

				float NdotV = abs(dot(worldNormal, worldDir));
				vec2 brdf = texture(brdfLutTex, vec2(material.roughness, NdotV)).xy;

				vec3 f0 = GetMaterialF0(material.metalness, albedo);
				vec3 specular = f0 * brdf.x + brdf.y;
				sceneOut = mix(sceneOut, specularLight, specular);
			}
		#endif

		// Particle translucent
		if (materialID == 1000u) {
			vec3 diffuseLight = texelFetch(colortex3, screenTexel, 0).rgb;
			vec3 albedo = sRGBtoLinear(gbufferData1.rgb);
			sceneOut = mix(sceneOut, albedo * diffuseLight, gbufferData1.a);
		}

		// Translucent
		if (glassMask || waterMask) {
			// Glass absorption
			if (glassMask) {
				vec3 absorption = log2(gbufferData1.rgb);
				absorption *= 2.0 * sqrt2(gbufferData1.a);
				sceneOut *= exp2(absorption);
			}

			// Apply specular lighting
			vec4 specularLight = texelFetch(colortex3, screenTexel, 0);
			sceneOut = mix(sceneOut, specularLight.rgb, specularLight.a);
		}

		// Border fog
		#ifdef BORDER_FOG
			#if defined DISTANT_HORIZONS
				#define far float(dhRenderDistance)
			#endif

			if (isEyeInWater == 0) {
				float density = saturate(1.0 - exp2(-pow8(sdot(worldPos.xz) * rcp(far * far)) * BORDER_FOG_FALLOFF));
				density *= exp2(-4.0 * curve(saturate(worldDir.y * 3.0)));

				vec3 skyRadiance = textureBicubic(skyViewTex, FromSkyViewLutParams(worldDir)).rgb;
				sceneOut = mix(sceneOut, skyRadiance, density);
			}
		#endif
	}

	// Initialize
	bloomyFogMask = 1.0;

	// Volumetric fog
	#ifdef VOLUMETRIC_FOG
		if (isEyeInWater == 0) {
			mat2x3 volFogData = VolumetricFogSpatialUpscale(screenTexel >> 1, -viewPos.z);
			sceneOut = ApplyFog(sceneOut, volFogData);
			bloomyFogMask = mean(volFogData[1]);
		}
	#endif

	float viewDistance = length(viewPos);
	float LdotV = dot(worldLightVector, worldDir);

	// Underwater fog
	if (isEyeInWater == 1) {
		#ifdef UW_VOLUMETRIC_FOG
			mat2x3 waterFog = VolumetricFogSpatialUpscale(screenTexel >> 1, -viewPos.z);
		#else
			mat2x3 waterFog = AnalyticWaterFog(eyeSkylightSmooth, viewDistance, LdotV);
		#endif
		sceneOut = ApplyFog(sceneOut, waterFog);
		bloomyFogMask = mean(waterFog[1]);
	}

	// Rainbows
	#ifdef RAINBOWS
		float rainbowVis = wetness * oms(rainStrength);
		if (rainbowVis > EPS) {
			sceneOut += RenderRainbows(LdotV, viewDistance) * global.light.directIlluminance * rainbowVis;
		}
	#endif

	// Vanilla fog
	RenderVanillaFog(sceneOut, bloomyFogMask, viewDistance);

	#if DEBUG_NORMALS == 1
		sceneOut = worldNormal * 0.5 + 0.5;
	#elif DEBUG_NORMALS == 2
		sceneOut = FetchFlatNormal(gbufferData0) * 0.5 + 0.5;
	#endif
}