/*
--------------------------------------------------------------------------------

	Revelation Shaders

	Copyright (C) 2024 HaringPro
	Apache License 2.0

--------------------------------------------------------------------------------
*/


#include "/settings.glsl"

#include "/lib/utility/Math.glsl"
#include "/lib/utility/Pack.glsl"
#include "/lib/utility/Color.glsl"
#include "/lib/utility/Interpolate.glsl"
#include "/lib/utility/Phase.glsl"
#include "/lib/utility/SH.glsl"
#include "/lib/utility/Load.glsl"
#include "/lib/utility/Offset.glsl"
#include "/lib/utility/SubgroupOps.glsl"

//================================================================================================//

#define ApplyFog(scene, fog) ((scene) * fog[1] + fog[0])

uvec2 QuadLayout8x8(uint idx) {
    return uvec2((((idx >> 2) & 0x7) & 0xfffe) | (idx & 0x1), ((idx >> 1) & 0x3) | (((idx >> 3) & 0x7) & 0xfffc));
}

uvec2 QuadLayout16x16(uint idx) {
    return QuadLayout8x8(idx & 0x3f) + uvec2(((idx >> 6) & 0x1) << 3, (idx >> 7) << 3);
}