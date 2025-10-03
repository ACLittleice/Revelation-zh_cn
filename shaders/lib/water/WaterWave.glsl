#if !defined INCLUDE_WATER_WATERWAVE
#define INCLUDE_WATER_WATERWAVE

#if WATER_WAVE_STYLE == 0

float FetchNoise(in vec2 coord, in float t) {
	coord.y *= 0.5;
	return sqr(1.0 - texture(noisetex, coord + t).z);
}

// fBm water wave
float CalculateWaterHeight(in vec2 position, in bool detail) {
	const vec2 angle = 2.0 * cossin(goldenAngle);
	const mat2 rot = mat2(angle, -angle.y, angle.x);

	float waveTime = 0.01 * WATER_WAVE_SPEED * frameTimeCounter;
	vec2 pos = 0.015 * position + waveTime;
	float waves = FetchNoise(pos, waveTime);

	pos = rot * pos + waves * 0.05;
	waves += FetchNoise(pos, waveTime) * 0.75;

	if (detail) {
		pos = pos * rot + waves * 0.05;
		waves += FetchNoise(pos, waveTime) * 0.15;

		pos = rot * pos;
		waves += FetchNoise(pos, waveTime) * 0.05;

		pos = pos * rot;
		waves += FetchNoise(pos, waveTime) * 0.03;
	}

	#if !defined PASS_SHADOW
		float localHeight = texture(noisetex, position * 2e-3 + waveTime * 0.125).z;
		waves *= saturate(localHeight * 3.0 - 1.5) * 4.0 + 1.0;
	#endif

	return waves * 0.5;
}

#else

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

	float x = dot(direction, position) * frequency + time * c;
	float wave = exp(sin(x));
	float dx = wave * cos(x);
	return vec2(wave, dx);
}

float CalculateWaterHeight(in vec2 position, in bool detail) {
	const vec2 angle = cossin(radians(36.46));
	const mat2 rot = mat2(angle, -angle.y, angle.x);

	vec3 noise = FetchSmoothNoise((position + frameTimeCounter) * 2e-3);
	vec2 dir = sincos(noise.z * 0.1);

	float frequency = 1.5;
	float weight = 1.0;
	float sum = 0.0;
	float sumWeight = 0.0;

	float waveTime = 0.5 * WATER_WAVE_SPEED * frameTimeCounter;
	uint steps = detail ? 12u : 4u;

	for (uint i = 0u; i < steps; ++i, dir *= rot) {
		vec2 res = wavedx(position + dir * noise.xy * 2.0, dir, frequency, waveTime);
		position -= dir * res.y * weight * 0.125;

		sum += res.x * weight;
		sumWeight += weight;

		weight *= 0.8;
		frequency *= 1.22;
	}

	#if !defined PASS_SHADOW
		sum *= saturate(noise.z * 3.0 - 1.5) * 4.0 + 1.0;
	#endif

	return sum / sumWeight * 0.05;
}

#endif

//================================================================================================//

vec3 CalculateWaterNormal(in vec2 position) {
	const float delta = 0.05;

	float heightCenter = CalculateWaterHeight(position, true);
	float heightLeft   = CalculateWaterHeight(position + vec2(delta, 0.0), true);
	float heightUp     = CalculateWaterHeight(position + vec2(0.0, delta), true);

	vec2 waveNormal    = vec2(heightCenter - heightLeft, heightCenter - heightUp);
	return normalize(vec3(waveNormal * WATER_WAVE_HEIGHT, delta));
}

vec3 CalculateWaterNormal(in vec2 position, in vec3 tangentViewDir, in float dither) {
	const uint steps = 32u;
	const float rSteps = rcp(float(steps));

	vec3 rayStep = vec3(tangentViewDir.xy * WATER_WAVE_HEIGHT, rSteps);
	rayStep.xy *= rSteps / tangentViewDir.z;

    vec3 samplePos = vec3(position, 1.0) - rayStep * dither;
	float sampleHeight = CalculateWaterHeight(samplePos.xy, false);

	while (sampleHeight < samplePos.z) {
        samplePos -= rayStep;
		sampleHeight = CalculateWaterHeight(samplePos.xy, false);
	}

	return CalculateWaterNormal(samplePos.xy);
}

#endif