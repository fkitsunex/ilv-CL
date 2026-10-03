#ifndef DYNAMIC_LIGHT_VOXEL
#define DYNAMIC_LIGHT_VOXEL

#if COLORED_LIGHTING_ENABLED == 1

// [dynamic lighting] Voxelise moving light SOURCES (dropped items, items held/worn by mobs & players,
// glowing mobs) that render in gbuffers_entities, so the colour-light floodfill lights the world around
// them — the coloured equivalent of LambDynLights. Unlike updateVoxelIds (terrain, keyed by block
// materialId) this writes a chosen voxelId directly, so it carries NO blockDatas include and never
// leaks GET_VOXEL_ID into the caller.

#include "/lib/colored_lighting/coloredLightingUtils.glsl"

#extension GL_ARB_shader_image_load_store : enable
layout(r8ui) uniform writeonly uimage3D voxelIds;

// Map a light-emitting ITEM (item.properties id in currentRenderedItemId / heldItemId) to the voxelId
// of the matching registered emitter block, so the floodfill reuses that block's real emission colour.
uint dynamicLightItemVoxelId(int id) {
	if (id == 4101) return 83u; // soul torch / lantern / campfire  -> blue
	if (id == 4102) return 90u; // redstone torch                   -> red
	if (id == 4103) return 15u; // sea lantern                      -> white
	if (id == 4104) return 47u; // verdant froglight                -> green
	if (id == 4105) return 14u; // ochre froglight                  -> warm amber
	if (id == 4106) return 48u; // pearlescent froglight            -> pink
	if (id == 4107) return 38u; // amethyst cluster / shard         -> purple
	if (id == 4108) return 102u; // lantern                          -> warm
	if (id == 4109) return 59u; // glowstone                        -> warm gold
	if (id == 4110) return 77u; // shroomlight                      -> orange
	if (id == 4111) return 43u; // magma block                      -> deep orange
	if (id == 4112) return 12u; // end rod                          -> white
	if (id == 4113) return 75u; // torch                            -> warm fire
	if (id == 4114) return 100u; // campfire                         -> warm fire
	if (id == 4115) return 75u; // jack o'lantern                   -> warm fire
	if (id == 4116) return 103u; // crying obsidian                  -> purple
	if (id == 4117) return 16u; // beacon                           -> white
	if (id == 4118) return 31u; // conduit                          -> teal
	if (id == 4119) return 88u; // glow berries                     -> warm amber
	return 0u;                  // not a mapped light item -> no voxel
}

// Map a light-emitting MOB (entity.properties id in entityId) to a reserved dynamic voxelId; shadowcomp
// gives it the matching block's emission, so it follows the same per-source HUE sliders.
uint dynamicLightEntityVoxelId(int id) {
	// reserved dynamic ids (handled explicitly in shadowcomp): full vanilla level 15, so the LambDynLights
	// light around them keeps THEIR colour; not remapped by apply_ids.py (macros, not numbers).
	if (id == 10010) return CL_VOXEL_GLOW_SQUID; // glow squid -> cyan  (CL_SCULKSENSOR_HUE)
	if (id == 10011) return CL_VOXEL_MAGMA_CUBE; // magma cube -> orange (CL_MAGMA_HUE)
	return 0u;                    // not a mapped light mob -> no voxel
}

// Write an emissive voxel at this dynamic source's position (camera-relative playerPos). No terrain
// render-stage gate and no at_midBlock offset (entities aren't block-aligned) — just drop the voxel in
// the cell the source occupies. voxelId 0 = skip.
void voxelizeDynamicLight(vec3 playerPos, uint voxelId) {
	if (voxelId == 0u) return;
	bool outsideRange;
	ivec3 voxelPos = getVoxelPos(playerPos, vec3(0.0), outsideRange);
	if (outsideRange) return;
	imageStore(voxelIds, ivec3(voxelPos), uvec4(voxelId, 0u, 0u, 0u));
}

// For a DROPPED BLOCK item (froglight, glowstone…) rendered as a block model: derive the voxelId from
// the block materialId (mc_Entity) via blockDatas, exactly like terrain, so its real emission colour is
// reused automatically. Only registered emitter blocks (id 2..254) are written; air/solid/unknown and
// non-block entities (materialId 0) are skipped, so mobs don't turn into occluders.
void voxelizeDynamicBlock(vec3 playerPos, uint materialId) {
	bool outsideRange;
	ivec3 voxelPos = getVoxelPos(playerPos, vec3(0.0), outsideRange);
	if (outsideRange) return;
	uint voxelId;
	#define GET_VOXEL_ID
	#include "/generated/blockDatas.glsl"
	#undef GET_VOXEL_ID
	if (voxelId < 2u || voxelId == 255u) return;
	imageStore(voxelIds, ivec3(voxelPos), uvec4(voxelId, 0u, 0u, 0u));
}

#endif

#endif
