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
