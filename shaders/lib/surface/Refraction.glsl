#ifdef RAYTRACED_REFRACTION
#include "/lib/surface/ScreenSpaceRaytracer.glsl"

vec2 CalculateRefractedCoord(in bool waterMask, in vec3 viewPos, in vec3 viewNormal, in vec3 screenPos) {
	vec3 rayDir = refract(normalize(viewPos), viewNormal, mix(1.0 / GLASS_REFRACT_IOR, 1.0 / WATER_REFRACT_IOR, waterMask));

	vec3 rayPos = screenPos;
	float dither = InterleavedGradientNoiseTemporal(gl_FragCoord.xy);
	if (ScreenSpaceRaytrace(viewPos, rayDir, dither, 16, rayPos)) {
		rayPos.xy = saturate(rayPos.xy * viewPixelSize);

		float refractedDepth = loadDepth1(uvToTexel(rayPos.xy));
		return mix(rayPos.xy, screenPos.xy, step(refractedDepth, screenPos.z));
	}
	return screenPos.xy;
}

#else

vec2 CalculateRefractedCoord(in bool waterMask, in vec3 viewPos, in vec3 viewNormal, in vec3 screenPos, in float transparentDepth) {
	vec3 refractedOffset = refract(normalize(viewPos), viewNormal, mix(1.0 / GLASS_REFRACT_IOR, 1.0 / WATER_REFRACT_IOR, waterMask));
	refractedOffset *= min(transparentDepth, 8.0) * (REFRACTION_STRENGTH * 0.25);

	vec2 refractedCoord = ViewToScreenSpace(viewPos + refractedOffset).xy;
	vec2 edgeFade = saturate(abs(refractedCoord * 2.0 - 1.0) * 4.0 - 3.0);
	refractedCoord = mix(refractedCoord, screenPos.xy, curve(edgeFade));

	refractedCoord = saturate(refractedCoord);
	float refractedDepth = loadDepth1(uvToTexel(refractedCoord));
	return mix(refractedCoord, screenPos.xy, step(refractedDepth, screenPos.z));
}

#endif