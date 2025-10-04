#include "/lib/surface/SSRT.glsl"

vec4 CalculateSpecularReflections(Material material, in vec3 worldNormal, in vec3 screenPos, in vec3 worldDir, in vec3 viewPos, in float skylight, in float dither) {
#ifdef ROUGH_REFLECTIONS
	if (material.isRough) {
		mat3 tbnMatrix = ConstructTBN(worldNormal);

        vec2 noise = SampleStbnVec2(ivec2(gl_FragCoord.xy), frameCounter + 3);
		vec3 halfway = tbnMatrix * SampleGGXVNDF(-worldDir * tbnMatrix, material.roughness, noise);

		vec3 lightDir = reflect(worldDir, halfway);

		float NdotL = dot(worldNormal, lightDir);
		if (NdotL < EPS) return vec4(0.0);

		bool hit = ScreenSpaceRaytrace(viewPos, mat3(gbufferModelView) * lightDir, dither, uint(SSRT_MAX_SAMPLES * oms(material.roughness)), screenPos);

		vec4 reflection = vec4(0.0);
		if (hit) {
			reflection.rgb = texelFetch(colortex4, ivec2(screenPos.xy) >> 1, 0).rgb;

			vec3 reflectViewPos = ScreenToViewSpace(vec3(screenPos.xy * viewPixelSize, loadDepth0(ivec2(screenPos.xy))));
			reflection.a = distance(reflectViewPos, viewPos);
		} else if (skylight > 1e-3) {
			vec3 skyRadiance = textureBicubic(skyViewTex, FromSkyViewLutParams(lightDir) + vec2(0.0, 0.5)).rgb;

			reflection = vec4(skyRadiance * skylight, far);
		}
		// float LdotH = dot(lightDir, halfway);
		// float NdotV = abs(dot(worldNormal, worldDir));

		return satU16f(reflection);
	} else
#endif
	{
		float NdotV = abs(dot(worldNormal, worldDir));
		// Unroll the reflect function manually
		vec3 lightDir = worldDir + worldNormal * NdotV * 2.0;

		float NdotL = dot(worldNormal, lightDir);
		if (NdotL < EPS) return vec4(0.0);

		vec3 reflection = vec3(0.0);
		if (skylight > 1e-3) {
			vec3 skyRadiance = textureBicubic(skyViewTex, FromSkyViewLutParams(lightDir) + vec2(0.0, 0.5)).rgb;

			reflection = skyRadiance * skylight;
		}

		bool hit = ScreenSpaceRaytrace(viewPos, mat3(gbufferModelView) * lightDir, dither, SSRT_MAX_SAMPLES, screenPos);
		if (hit) {
			screenPos.xy *= viewPixelSize;
			float edgeFade = screenPos.x * screenPos.y * oms(screenPos.x) * oms(screenPos.y);
			edgeFade *= 1e2 + cube(saturate(1.0 - gbufferModelViewInverse[2].y)) * 3e3;
			reflection += (texture(colortex4, screenPos.xy * 0.5).rgb - reflection) * saturate(edgeFade);
		}

		return vec4(satU16f(reflection), 0.0);
	}
}