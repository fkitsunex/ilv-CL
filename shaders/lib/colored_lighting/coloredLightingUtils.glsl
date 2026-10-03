#ifndef COLORED_LIGHTING_UTILS
#define COLORED_LIGHTING_UTILS

const ivec3 coloredLightingSize = ivec3(COLORED_LIGHTING_DIST, COLORED_LIGHTING_DIST / 2, COLORED_LIGHTING_DIST);
const ivec3 halfColoredLightingSize = coloredLightingSize / 2;

// LINEAR (camera-relative) voxel addressing. No modulo wrap -> no toroidal seam (the
// hard horizontal line in the colour at certain world heights). The compute re-aligns the
// previous-frame buffer for camera movement instead (clPosOffset in shadowcomp.glsl).
ivec3 getVoxelPos(vec3 playerPos, vec3 offset, out bool outsideRange) {
	vec3 playerBlockPos = playerPos + cameraPositionFract + offset;
	ivec3 voxelPos = ivec3(floor(playerBlockPos)) + halfColoredLightingSize;
	outsideRange = any(lessThan(voxelPos, ivec3(0))) || any(greaterThanEqual(voxelPos, coloredLightingSize));
	return clamp(voxelPos, ivec3(0), coloredLightingSize - 1);
}

// reserved floodfill voxelIds for DYNAMIC sources (the block-datas generator only uses ~2..110, 255 = unknown)
#define CL_VOXEL_COPYCAT_BASE 240u // 240..250: copycat blocks holding a light-source material (see updateVoxelIds)
#define CL_VOXEL_ENCHANT 252u    // enchanted item held by a player / mob (Enchantment Outlines texels)
#define CL_VOXEL_MAGMA_CUBE 253u
#define CL_VOXEL_GLOW_SQUID 254u
// purple of the enchantment outlines / glint
#define CL_ENCHANT_COLOR vec3(0.62, 0.3, 1.0)

#endif
