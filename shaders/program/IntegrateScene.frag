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

/* RENDERTARGETS: 0,8 */
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
	uvec4 gbufferData0 = loadGbufferData0(screenTexel);

	uint materialID = gbufferData0.y;

	float depth = loadDepth0(screenTexel);
	float sDepth = loadDepth1(screenTexel);

    vec2 screenCoord = gl_FragCoord.xy * viewPixelSize;

	vec3 screenPos = vec3(screenCoord, depth);
	vec3 viewPos = ScreenToViewSpace(screenPos);
	vec3 sViewPos = ScreenToViewSpace(vec3(screenCoord, sDepth));
	#if defined DISTANT_HORIZONS
		if (depth > 0.999999) {
			depth = screenPos.z = loadDepth0DH(screenTexel);
			viewPos = ScreenToViewSpaceDH(screenPos);
		}
		if (sDepth > 0.999999) {
			sDepth = loadDepth1DH(screenTexel);
			sViewPos = ScreenToViewSpaceDH(vec3(screenCoord, sDepth));
		}
	#endif

	float viewDistance = length(viewPos);
	float transparentDepth = distance(viewPos, sViewPos);

	vec2 refractedCoord = screenCoord;
	ivec2 refractedTexel = screenTexel;
	bool waterMask = materialID == 3u;

	// Process refraction
	if (materialID == 2u || waterMask) {
		vec3 viewNormal = mat3(gbufferModelView) * FetchWorldNormal(gbufferData0.w);

		#ifdef RAYTRACED_REFRACTION
			refractedCoord = CalculateRefractedCoord(waterMask, viewPos, viewNormal, screenPos);
		#else
			vec3 viewFlatNormal = mat3(gbufferModelView) * FetchFlatNormal(gbufferData0);
			viewNormal -= float(waterMask) * viewFlatNormal; // Fix water refraction artifacts
			refractedCoord = CalculateRefractedCoord(waterMask, viewPos, viewNormal, screenPos, transparentDepth);
		#endif
		refractedTexel = uvToTexel(refractedCoord);

		depth = loadDepth0(refractedTexel);
		sDepth = loadDepth1(refractedTexel);

		// gbufferData0 = loadGbufferData0(refractedTexel);
		viewPos = ScreenToViewSpace(vec3(refractedCoord, depth));
		sViewPos = ScreenToViewSpace(vec3(refractedCoord, sDepth));
		#if defined DISTANT_HORIZONS
			if (depth > 0.999999) {
				depth = loadDepth0DH(refractedTexel);
				viewPos = ScreenToViewSpaceDH(vec3(refractedCoord, depth));
			}
			if (sDepth > 0.999999) {
				sDepth = loadDepth1DH(refractedTexel);
				sViewPos = ScreenToViewSpaceDH(vec3(refractedCoord, sDepth));
			}
		#endif
	}

    sceneOut = loadSceneColor(refractedTexel);
	vec3 worldNormal = FetchWorldNormal(gbufferData0);

	vec3 worldPos = mat3(gbufferModelViewInverse) * viewPos;
	vec3 worldDir = normalize(worldPos);
	float LdotV = dot(worldLightVector, worldDir);

	if (depth < 1.0 || waterMask) {
		worldPos += gbufferModelViewInverse[3].xyz;
		float skyLightmap = Unpack2x8UY(gbufferData0.x);

		vec4 gbufferData1 = loadGbufferData1(screenTexel);

		#if defined SPECULAR_MAPPING && defined MC_SPECULAR_MAP
			Material material = GetMaterialData(gbufferData1.xy);
		#endif

		// Water fog
		if (waterMask && isEyeInWater == 0) {
			float waterDepth = distance(viewPos, sViewPos);
			mat2x3 waterFog = AnalyticWaterFog(skyLightmap, max(transparentDepth, waterDepth), LdotV);
			sceneOut = ApplyFog(sceneOut, waterFog);
		}

		if (waterMask) { // Water
			// Specular lighting of water
			vec4 blendedData = texelFetch(colortex1, screenTexel, 0);
			#if 1
				blendedData.rgb -= sceneOut * blendedData.a;
			#else
				blendedData.rgb = waterMask && isEyeInWater == 1 ? blendedData.rgb - sceneOut * blendedData.a : blendedData.rgb;
			#endif

			sceneOut += blendedData.rgb;
		} else if (materialID == 2u) { // Glass
			// Glass absorption
			sceneOut *= exp2(5.0 * (gbufferData1.rgb - 1.0) * approxSqrt(approxSqrt(gbufferData1.a)));

			// Specular lighting of glass
			vec4 blendedData = texelFetch(colortex1, screenTexel, 0);
			#if 1
				blendedData.rgb -= sceneOut * blendedData.a;
			#endif

			sceneOut += blendedData.rgb;
		}
		#if defined SPECULAR_MAPPING && defined MC_SPECULAR_MAP
			else if (material.specularMask) {
				// Specular reflections of other materials
				vec3 reflectionData = texelFetch(colortex1, refractedTexel, 0).rgb;
				vec3 albedo = sRGBtoLinear(loadAlbedo(refractedTexel));

				float NdotV = abs(dot(worldNormal, worldDir));
				vec2 brdf = texture(brdfLutTex, vec2(material.roughness, NdotV)).xy;

				vec3 f0 = GetMaterialF0(material.metalness, albedo);
				vec3 specular = f0 * brdf.x + brdf.y;
				sceneOut += reflectionData * specular;
			}
		#endif

		// Border fog
		#ifdef BORDER_FOG
			#if defined DISTANT_HORIZONS
				#define far float(dhRenderDistance)
			#endif

			if (isEyeInWater == 0) {
				float density = saturate(1.0 - exp2(-pow8(sdot(worldPos.xz) * rcp(far * far)) * BORDER_FOG_FALLOFF));
				density *= exp2(-5.0 * curve(saturate(worldDir.y * 3.0)));

				vec3 skyRadiance = textureBicubic(skyViewTex, FromSkyViewLutParams(worldDir)).rgb;
				sceneOut = mix(sceneOut, skyRadiance, density);
			}
		#endif
	}

	// Initialize bloomyFogMask
	bloomyFogMask = 1.0;

	// Volumetric fog
	#ifdef VOLUMETRIC_FOG
		if (isEyeInWater == 0) {
			mat2x3 volFogData = VolumetricFogSpatialUpscale(screenTexel >> 1, -viewPos.z);
			sceneOut = ApplyFog(sceneOut, volFogData);
			bloomyFogMask = mean(volFogData[1]);
		}
	#endif

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

	// sceneOut = texelFetch(brdfLutTex, screenTexel, 0).xyz;
}