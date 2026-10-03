#include "/lib/colored_lighting/coloredLightingUtils.glsl"

#extension GL_ARB_shader_image_load_store : enable
layout(r8ui) uniform writeonly uimage3D voxelIds;
// [leak fix] "partial" votes for UNREGISTERED blocks (cleared every frame): a vertex that isn't a corner
// of the full cube, or any non-SOLID render stage, marks its cell as a partial/see-through block.
// shadowcomp treats an unregistered cell WITHOUT a vote as a full opaque cube (stone, dirt, planks...).
// R32UI, written with atomic OR: bit 0 = "partial" vote, bits 1..11 = copycat light-material votes.
layout(r32ui) uniform uimage3D voxelPartial;

// [copycat light] Iris only sees the COPYCAT block's id, not the material inside it, so recognise the material
// by the texture the copycat model draws with: average the quad's texels and match them against the average
// colour of each light-source block texture (vanilla). A match only counts when the block light around the
// vertex is about as high as that source gives — so a sand copycat is never mistaken for an ochre froglight.
// Returns the material index (0..10, see CL_VOXEL_COPYCAT_BASE in shadowcomp) or -1.
// Only compiled where the programs define CL_COPYCAT (terrain + shadow: they have the atlas + mc_midTexCoord).
#ifdef CL_COPYCAT
int copycatLightMaterial() {
	vec2 uv  = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	vec2 mid = mat2(gl_TextureMatrix[0]) * mc_midTexCoord;
	vec2 ext = abs(uv - mid);
	vec3 avg = vec3(0.0);
	float n = 0.0;
	for (int y = 0; y < 4; y++) {
		for (int x = 0; x < 4; x++) {
			vec4 t = texture2DLod(MAIN_TEXTURE, mid + ext * (vec2(x, y) * 0.5 - 0.75), 0.0);
			avg += t.rgb * step(0.1, t.a);
			n += step(0.1, t.a);
		}
	}
	if (n < 0.5) return -1;
	avg /= n;
	// Average texture colours (alpha-weighted, all animation frames; vanilla / Create / Copycats+): light
	// sources map to a material index, the rest are LOOKALIKES (-1) — empty copycats, quartz, sand, oak planks…
	// The nearest reference wins, so a quartz copycat is quartz, not a pearlescent froglight.
	// (Magma, redstone ore and jack o'lanterns are left out: too dim / too ambiguous to tell from the texture.)
	const int REFS = 51;
	const vec3 refColor[REFS] = vec3[REFS](
		vec3(0.674, 0.514, 0.331) /* glowstone */,
		vec3(0.676, 0.784, 0.745) /* sea lantern */,
		vec3(0.945, 0.575, 0.278) /* shroomlight */,
		vec3(0.963, 0.915, 0.713) /* ochre froglight side */,
		vec3(0.983, 0.961, 0.81) /* ochre froglight top */,
		vec3(0.828, 0.92, 0.817) /* verdant froglight side */,
		vec3(0.899, 0.959, 0.895) /* verdant froglight top */,
		vec3(0.924, 0.882, 0.896) /* pearlescent froglight side */,
		vec3(0.964, 0.941, 0.94) /* pearlescent froglight top */,
		vec3(0.56, 0.399, 0.238) /* redstone lamp (lit) */,
		vec3(0.128, 0.04, 0.237) /* crying obsidian */,
		vec3(0.45, 0.475, 0.427) /* copycat base (empty) */,
		vec3(0.624, 0.435, 0.278) /* copycat base 1 */,
		vec3(0.829, 0.514, 0.379) /* copycat base 2 */,
		vec3(0.408, 0.428, 0.391) /* copycat slope */,
		vec3(0.925, 0.902, 0.874) /* quartz */,
		vec3(0.876, 0.88, 0.865) /* calcite */,
		vec3(0.74, 0.739, 0.741) /* diorite */,
		vec3(0.757, 0.757, 0.763) /* polished diorite */,
		vec3(0.859, 0.813, 0.64) /* sand */,
		vec3(0.849, 0.797, 0.611) /* sandstone */,
		vec3(0.878, 0.84, 0.668) /* sandstone top */,
		vec3(0.861, 0.874, 0.621) /* end stone */,
		vec3(0.755, 0.687, 0.475) /* birch planks */,
		vec3(0.9, 0.886, 0.815) /* bone block */,
		vec3(0.916, 0.927, 0.929) /* white wool */,
		vec3(0.812, 0.836, 0.84) /* white concrete */,
		vec3(0.622, 0.622, 0.622) /* smooth stone */,
		vec3(0.059, 0.042, 0.096) /* obsidian */,
		vec3(0.155, 0.094, 0.246) /* respawn anchor */,
		vec3(0.863, 0.863, 0.863) /* iron block */,
		vec3(0.977, 0.997, 0.997) /* snow */,
		vec3(0.797, 0.771, 0.728) /* mushroom stem */,
		vec3(0.822, 0.698, 0.633) /* white terracotta */,
		vec3(0.758, 0.679, 0.316) /* bamboo planks */,
		vec3(0.636, 0.513, 0.308) /* oak planks */,
		vec3(0.586, 0.405, 0.337) /* granite */,
		vec3(0.634, 0.329, 0.148) /* orange terracotta */,
		vec3(0.899, 0.582, 0.116) /* honeycomb */,
		vec3(0.966, 0.817, 0.242) /* gold block */,
		vec3(0.73, 0.522, 0.139) /* yellow terracotta */,
		vec3(0.773, 0.69, 0.464) /* stripped birch log */,
		vec3(0.63, 0.653, 0.704) /* clay */,
		vec3(0.389, 0.673, 0.621) /* prismarine bricks */,
		vec3(0.666, 0.494, 0.665) /* purpur */,
		vec3(0.525, 0.384, 0.75) /* amethyst block */,
		vec3(0.933, 0.554, 0.676) /* pink wool */,
		vec3(0.888, 0.701, 0.677) /* cherry planks */,
		vec3(0.767, 0.45, 0.095) /* pumpkin side */,
		vec3(0.492, 0.492, 0.492) /* stone */,
		vec3(0.383, 0.151, 0.151) /* netherrack */
	);
	const int refMaterial[REFS] = int[REFS](0, 1, 2, 3, 3, 4, 4, 5, 5, 6, 7, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1, -1);
	const float refLevel[REFS] = float[REFS](15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 15.0, 10.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0);
	int best = -1;
	float bestDist = 0.12; // max colour distance to count as a match at all
	for (int i = 0; i < REFS; i++) {
		float d = distance(avg, refColor[i]);
		if (d < bestDist) { bestDist = d; best = i; }
	}
	if (best < 0 || refMaterial[best] < 0) return -1;
	// block light at this vertex (raw lightmap: level = x*16 - 0.5). The copycat's OWN light reaches the air in
	// front of its faces at level-1, so demand that (Iris's per-block light value is 0 for copycats — they
	// emit through the world-aware light method — so the lightmap is the only evidence available)
	float vertexLevel = (gl_TextureMatrix[1] * gl_MultiTexCoord1).x * 16.0 - 0.5;
	float need = refLevel[best] - 1.5;
	return vertexLevel >= need ? refMaterial[best] : -1;
}
#endif



void updateVoxelIds(vec3 playerPos, uint materialId) {
	
	if (!any(equal(ivec4(renderStage), ivec4(
		MC_RENDER_STAGE_TERRAIN_SOLID,
		MC_RENDER_STAGE_TERRAIN_TRANSLUCENT,
		MC_RENDER_STAGE_TERRAIN_CUTOUT,
		MC_RENDER_STAGE_TERRAIN_CUTOUT_MIPPED
	)))) return;
	
	bool outsideRange;
	ivec3 voxelPos = getVoxelPos(playerPos, at_midBlock / 64.0, outsideRange);
	if (outsideRange) return;

	uint voxelId;
	#define GET_VOXEL_ID
	#include "/generated/blockDatas.glsl"

	// UNREGISTERED blocks (modded, materialId 0) default to "solid" via the axis-aligned-normal
	// heuristic in the generated code — which made every modded partial block (FD cutting boards,
	// Create gear...) wrongly BLOCK colored light. Remap them to the reserved "unknown" id 255:
	// the floodfill passes the light's COLOUR through but no artificial brightness, so nothing
	// glows through full modded walls (vanilla light doesn't pass walls, and tint without light
	// is invisible) while partial modded blocks stop eating the colored light.
	// copycats: same treatment as an unknown block (solid if a full cube, else passes colour) + light material
	bool isCopycat = materialId == BLOCK_ID_COPYCAT;
	if (isCopycat) {
		voxelId = 1u;
		#ifdef CL_COPYCAT
			if (gl_VertexID % 4 == 0) {
				int cm = copycatLightMaterial();
				if (cm >= 0) imageAtomicOr(voxelPartial, ivec3(voxelPos), 2u << uint(cm));
			}
		#endif
	}
	if ((materialId == 0u || isCopycat) && voxelId == 1u) {
		voxelId = 255u;
		// [leak fix] ...but the 255 "pass colour" treatment used to apply to EVERY unregistered block,
		// and most common full blocks (stone, dirt, deepslate, planks, logs, bricks...) are unregistered,
		// so coloured light seeped straight through walls. Vote "partial" when this vertex isn't on a
		// corner of the full cube (at_midBlock = offset to the block centre in 1/64ths -> +-32 on every
		// axis for a full cube) or the block isn't in the SOLID stage (glass-like / cutout). Every vertex
		// votes (not just the first of the quad), so one inset face is enough to mark the block partial.
		bool fullCorner = all(lessThan(abs(abs(at_midBlock.xyz) - 32.0), vec3(1.5)));
		if (!fullCorner || renderStage != MC_RENDER_STAGE_TERRAIN_SOLID) {
			imageAtomicOr(voxelPartial, ivec3(voxelPos), 1u);
		}
	}

	if (voxelId == 0u) return;
	if (gl_VertexID % 4 != 0) return; // the id itself only needs writing once per quad
	
	imageStore(voxelIds, ivec3(voxelPos), uvec4(voxelId, 0u, 0u, 0u));
	
}
