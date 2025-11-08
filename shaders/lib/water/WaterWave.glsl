#if !defined INCLUDE_WATER_WATERWAVE
#define INCLUDE_WATER_WATERWAVE

vec3 FetchSmoothNoise(in vec2 coord) {
	coord *= 256.0;

    vec2 whole = floor(coord);
    vec2 part = curve(coord - whole);

	coord = (whole + 1.0) * rcp(256.0);
	vec4 sx = textureGather(noisetex, coord, 0);
	vec4 sy = textureGather(noisetex, coord, 1);
	vec4 sz = textureGather(noisetex, coord, 2);

    vec3 s0 = mix(vec3(sx.w, sy.w, sz.w), vec3(sx.z, sy.z, sz.z), part.x);
    vec3 s1 = mix(vec3(sx.x, sy.x, sz.x), vec3(sx.y, sy.y, sz.y), part.x);
    return mix(s0, s1, part.y);
}

// Based on https://www.shadertoy.com/view/MdXyzX
// afl_ext 2017-2024
// MIT License
vec2 wavedx(vec2 position, vec2 direction, float frequency, float time) {
	float c = approxSqrt(9.8 * frequency);

	#if WATER_WAVE_STYLE == 0
		float x = time * c - dot(direction, position) * frequency;
	#else
		float x = time * c + dot(direction, position) * frequency;
	#endif

	float wave = sqr(sin(x) * 0.5 + 0.5);
	float dx = wave * cos(x);

	return vec2(wave, dx);
}

float CalculateWaterHeight(in vec2 position, in bool detail) {
	const vec2 angle = cossin(goldenAngle);
	const mat2 rot = mat2(angle, -angle.y, angle.x);

	vec3 noise = FetchSmoothNoise((position + frameTimeCounter) * 2e-3);
	vec2 dir = sincos(32.0 * noise.z * inversesqrt(sdot(position)));

	float frequency = 1.5;
	float weight = 1.0;
	float sum = 0.0;
	float sumWeight = 0.0;

	float waveTime = 0.5 * WATER_WAVE_SPEED * frameTimeCounter;
	uint steps = detail ? 12u : 6u;

	for (uint i = 0u; i < steps; ++i, dir *= rot) {
		vec2 res = wavedx(position + dir * noise.xy * (8.0 * weight), dir, frequency, waveTime);
		position -= dir * res.y * weight * 0.25;

		sum += res.x * weight;
		sumWeight += weight;

		weight *= 0.8;
		frequency *= 1.22;
	}

	#if !defined PASS_SHADOW
		sum *= saturate(noise.z * 2.0 - 1.0) * 3.0 + 1.0;
	#endif

	return sum / sumWeight * 0.125;
}

//================================================================================================//

vec3 CalculateWaterNormal(in vec2 position) {
	const float delta = 0.1;

	float height0 = CalculateWaterHeight(position, true);
	float height1 = CalculateWaterHeight(position + vec2(delta, 0.0), true);
	float height2 = CalculateWaterHeight(position + vec2(0.0, delta), true);

	vec2 waveNormal = vec2(height0 - height1, height0 - height2);
	waveNormal *= WATER_WAVE_HEIGHT / (1.0 + dot(fwidth(position), vec2(0.15)));
	return normalize(vec3(waveNormal, delta));
}

vec3 CalculateWaterNormal(in vec3 position, in vec3 direction) {
	const uint steps = 16u;
	const float rSteps = rcp(float(steps));

	vec3 rayStep = vec3(direction.xy * WATER_WAVE_HEIGHT, rSteps);
	rayStep.xy *= rSteps / direction.z;

    vec3 rayPos = vec3(position.xz, 1.0) - rayStep * 0.5;
	float sampleHeight = CalculateWaterHeight(rayPos.xy, false);

	while (sampleHeight < rayPos.z) {
        rayPos -= rayStep;
		sampleHeight = CalculateWaterHeight(rayPos.xy, false);
	}

    // Refinement (binary search)
	rayPos += rayStep;
	rayStep *= 0.5;

	for (uint i = 0u; i < 8u; ++i) {
		sampleHeight = CalculateWaterHeight(rayPos.xy, false);

		rayPos -= rayStep * (step(sampleHeight, rayPos.z) * 2.0 - 1.0);
		rayStep *= 0.5;
	}

	rayPos -= rayStep * 2.0;

	return CalculateWaterNormal(rayPos.xy);
}

#endif