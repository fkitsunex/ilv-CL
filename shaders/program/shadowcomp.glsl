#include "/lib/colored_lighting/coloredLightingUtils.glsl"



// workgroup size (always 8x8x8)
layout(local_size_x = 8, local_size_y = 8, local_size_z = 8) in;

// number of workgroups
#if COLORED_LIGHTING_DIST == 32
	const ivec3 workGroups = ivec3(4, 2, 4);
#elif COLORED_LIGHTING_DIST == 48
	const ivec3 workGroups = ivec3(6, 3, 6);
#elif COLORED_LIGHTING_DIST == 64
	const ivec3 workGroups = ivec3(8, 4, 8);
#elif COLORED_LIGHTING_DIST == 96
	const ivec3 workGroups = ivec3(12, 6, 12);
#elif COLORED_LIGHTING_DIST == 128
	const ivec3 workGroups = ivec3(16, 8, 16);
#elif COLORED_LIGHTING_DIST == 192
	const ivec3 workGroups = ivec3(24, 12, 24);
#elif COLORED_LIGHTING_DIST == 256
	const ivec3 workGroups = ivec3(32, 16, 32);
#elif COLORED_LIGHTING_DIST == 384
	const ivec3 workGroups = ivec3(48, 24, 48);
#elif COLORED_LIGHTING_DIST == 512
	const ivec3 workGroups = ivec3(64, 32, 64);
#else
	const ivec3 workGroups = ivec3(8, 4, 8);
#endif

#extension GL_ARB_shader_image_load_store : enable

// double-buffered floodfill volume (ping-pong by frame parity to avoid read/write races):
// each frame we read the previous frame's result from one buffer and write the new result to the other.
layout(rgba16f) writeonly uniform image3D clFloodA;
layout(rgba16f) writeonly uniform image3D clFloodB;
uniform sampler3D clFloodASampler;
uniform sampler3D clFloodBSampler;
uniform usampler3D voxelIdsSampler;
uniform usampler3D voxelPartialSampler;

// [dyn-light split] vanilla-style LIGHT LEVEL of the coloured sources (0..15, -1 = solid cell), ping-ponged
// with the floodfill. Surface lighting compares it with the fragment's actual blocklight: whatever the
// lightmap has ABOVE this level comes from LambDynLights (burning mobs, dropped torches...) and keeps its
// default warm colour instead of amplifying the coloured source. The -1 marks also let the surface
// sampler skip solid cells (no colour bleeding through walls / onto particles).
layout(r16f) writeonly uniform image3D clLevelA;
layout(r16f) writeonly uniform image3D clLevelB;
uniform sampler3D clLevelASampler;
uniform sampler3D clLevelBSampler;

// on even frames we read the previous result from buffer 1 and write the new one to buffer 2
// (and the reverse on odd frames) — this ping-pong avoids reading a buffer we're writing.
bool readFromBuffer1() {
	return (frameCounter % 2) == 0;
}

// how far (in cells) the camera moved since last frame. With LINEAR addressing the grid is
// camera-relative, so we shift the previous-frame buffer by this when reading it, to keep light
// locked to the world as the camera moves (instead of wrapping toroidally).
ivec3 clPosOffset() {
	return ivec3(floor(previousCameraPosition) - floor(cameraPosition));
}

// floodfill cells are vec4: rgb = colour (chroma/reach/dominance), a = "artificial light"
// (an artificial-light alpha — extra brightness a source casts even where the vanilla blocklight is
// too dim to reach). Both channels propagate together through the diffusion.

// read a cell of the previous frame's floodfill result (re-aligned for camera movement)
vec4 samplePrev(ivec3 pos) {
	pos = clamp(pos - clPosOffset(), ivec3(0), coloredLightingSize - 1);
	return readFromBuffer1() ? texelFetch(clFloodASampler, pos, 0)
	                         : texelFetch(clFloodBSampler, pos, 0);
}

// [leak fix] a cell blocks light if it's a registered solid (id 1) or an UNREGISTERED block (255) that
// got no "partial" vote this frame, i.e. a plain full cube (stone, dirt, planks...). See updateVoxelIds.
bool isSolidCell(ivec3 pos) {
	uint id = texelFetch(voxelIdsSampler, pos, 0).r;
	return id == 1u || (id == 255u && texelFetch(voxelPartialSampler, pos, 0).r == 0u); // any vote bit (partial / copycat light) = open
}

// previous frame's light level of a neighbour (solid cells store -1 -> treated as 0).
// The level images aren't cleared, so their initial contents can be garbage/NaN — and a NaN here would
// spread through the whole volume forever (max() with NaN). Anything outside 0..15 reads as 0.
float prevLevel(ivec3 npos) {
	ivec3 fpos = clamp(npos - clPosOffset(), ivec3(0), coloredLightingSize - 1);
	float v = readFromBuffer1() ? texelFetch(clLevelASampler, fpos, 0).r
	                            : texelFetch(clLevelBSampler, fpos, 0).r;
	return (isnan(v) || !(v >= 0.0 && v <= 15.0)) ? 0.0 : v;
}

// vanilla light level of a coloured source, keyed by its ORIGINAL emission value (like the recolour
// chain below, so it's regen-safe). Unknown emitters default to 15 (= never split, old behaviour).
float clEmitterLevel(vec3 e) {
	if (max(e.r, max(e.g, e.b)) < 0.001) return 0.0;
	if (length(e - vec3(0, 0.42, 2.1)) < 0.05) return 10.0;      // soul torch / lantern / campfire / fire
	if (length(e - vec3(1.98, 0, 0)) < 0.05) return 7.0;         // redstone torch
	if (length(e - vec3(0.1, 0, 0)) < 0.05) return 9.0;          // lit redstone ore
	if (length(e - vec3(0.05, 0, 0)) < 0.02) return 0.0;         // powered wire / repeater / comparator / Create redstone (no vanilla light)
	if (length(e - vec3(2.5, 2.05, 1.38)) < 0.05) return 14.0;   // torch
	if (length(e - vec3(0.2, 0.4, 0.3)) < 0.05) return 15.0;     // sea pickle (6-15 by count; unknown -> never split)
	if (length(e - vec3(0.3, 0.5, 0.4)) < 0.05) return 7.0;      // glow lichen
	if (length(e - vec3(0.7, 0.5, 0.3)) < 0.05) return 14.0;     // cave vines
	if (length(e - vec3(0.15, 0.08, 0.25)) < 0.05) return 1.0;   // small amethyst bud
	if (length(e - vec3(0.3, 0.17, 0.5)) < 0.05) return 2.0;     // medium amethyst bud
	if (length(e - vec3(0.45, 0.26, 0.7)) < 0.05) return 4.0;    // large amethyst bud
	if (length(e - vec3(1.32, 0.77, 2.09)) < 0.05) return 5.0;   // amethyst cluster
	if (length(e - vec3(1, 0.3, 0.08)) < 0.05) return 3.0;       // magma block
	if (length(e - vec3(0.5, 0.22, 0.9)) < 0.05) return 10.0;    // crying obsidian
	if (length(e - vec3(2.7, 2.85, 3)) < 0.05) return 14.0;      // end rod
	if (length(e - vec3(1.4, 0.5, 2.1)) < 0.05) return 11.0;     // nether portal
	if (length(e - vec3(0.3, 0.3, 0.3)) < 0.05) return 6.0;      // sculk catalyst
	if (length(e - vec3(0.1, 0.9, 1.1)) < 0.05) return 1.0;      // sculk sensor
	if (e.r == e.g && e.g == e.b && e.r <= 1.0) return floor(e.r * 15.0 + 0.5); // generic grey = level/15
	return 15.0;
}

// light contribution of a neighbour cell for diffusion. A SOLID neighbour (voxelId 1) doesn't
// drain light into itself — it returns this cell's own value instead — so light spreads along
// walls and floors (the surfaces we actually see lit) like vanilla blocklight, rather than being
// absorbed a block away from any surface, which was capping the coloured-light reach.
vec4 neighbourLight(ivec3 npos, vec4 self) {
	ivec3 vpos = clamp(npos, ivec3(0), coloredLightingSize - 1);
	if (isSolidCell(vpos)) return self * 0.98; // reflect: corners keep their colour (0.92 starved them once stone became solid); the >6 divisor still stops pile-up
	ivec3 fpos = clamp(npos - clPosOffset(), ivec3(0), coloredLightingSize - 1);
	return readFromBuffer1() ? texelFetch(clFloodASampler, fpos, 0)
	                         : texelFetch(clFloodBSampler, fpos, 0);
}



void main() {

	ivec3 pos = ivec3(gl_GlobalInvocationID);

	// this cell's light data (emission = light it casts, translucency = light it lets through)
	uint voxelId = texelFetch(voxelIdsSampler, pos, 0).r;
	uint voteBits = texelFetch(voxelPartialSampler, pos, 0).r;
	// [copycat light] a copycat holding a light-source material -> that source's reserved emitter id
	uint copycatBits = voteBits >> 1u;
	if (voxelId == 255u && copycatBits != 0u) voxelId = CL_VOXEL_COPYCAT_BASE + uint(findLSB(copycatBits));
	vec3 emission = vec3(0.0);
	vec3 translucency = vec3(0.0);
	#define GET_EMISSION
	#define GET_TRANSLUCENCY
	#include "/generated/voxelDatas.glsl"

	// reserved DYNAMIC ids (never produced by the block-datas generator, which stays far below 250):
	// written by gbuffers_entities for glowing mobs and enchanted items held by players/mobs.
	float emitLevel = clEmitterLevel(emission);
	if (voxelId == CL_VOXEL_GLOW_SQUID) {
		emission = vec3(0.1, 0.9, 1.1); translucency = vec3(1.0); emitLevel = 15.0;   // -> sculk-sensor cyan
	} else if (voxelId == CL_VOXEL_MAGMA_CUBE) {
		emission = vec3(1, 0.3, 0.08); translucency = vec3(1.0); emitLevel = 15.0;    // -> magma orange
	} else if (voxelId == CL_VOXEL_ENCHANT) {
		translucency = vec3(1.0); emitLevel = 0.0;                                    // purple, set below
	} else if (voxelId >= CL_VOXEL_COPYCAT_BASE && voxelId <= CL_VOXEL_COPYCAT_BASE + 10u) {
		// copycat with a light-source material: the ORIGINAL emission of that block, so the recolour chain
		// below applies the same per-source HUE/SAT sliders as the real block
		const vec3 copycatEmission[11] = vec3[11](
			vec3(3.5, 3.15, 1.05), vec3(2.7, 3, 3), vec3(2.8, 2.52, 1.4),     // glowstone, sea lantern, shroomlight
			vec3(3.5, 2.52, 1.05), vec3(1.75, 3.15, 1.57), vec3(3.5, 2.1, 2.98), // ochre, verdant, pearlescent froglight
			vec3(3, 3, 2.7), vec3(0.5, 0.22, 0.9), vec3(1, 0.3, 0.08),         // redstone lamp, crying obsidian, magma
			vec3(0.1, 0.0, 0.0), vec3(2.5, 2.5, 2.25));                        // lit redstone ore, jack o'lantern
		emission = copycatEmission[voxelId - CL_VOXEL_COPYCAT_BASE];
		translucency = vec3(1.0);
		emitLevel = clEmitterLevel(emission);
	}

	// [CL source colors] override each source's emission colour from the per-source HUE+saturation
	// settings, keeping its original brightness. Matched by the ORIGINAL emission colour (not voxelId),
	// so every voxel of that source is recoloured regardless of which voxelId it got — this also groups
	// variants (soul torch/lantern/campfire/fire all share one colour). Defaults reproduce the original
	// colours (no change until a slider is moved).
	if (length(emission - vec3(0, 0.42, 2.1)) < 0.05) emission = hsvToRgb(vec3(CL_SOUL_HUE / 360.0, CL_SOUL_SAT, 1.0)) * 2.1;
	else if (length(emission - vec3(1.98, 0, 0)) < 0.05) emission = hsvToRgb(vec3(CL_REDSTONE_HUE / 360.0, CL_REDSTONE_SAT, 1.0)) * 1.98;
	else if (length(emission - vec3(0.1, 0, 0)) < 0.05) emission = hsvToRgb(vec3(CL_REDSTONE_HUE / 360.0, CL_REDSTONE_SAT, 1.0)) * 1.78;
	else if (length(emission - vec3(0.05, 0, 0)) < 0.02) emission = hsvToRgb(vec3(CL_REDSTONE_HUE / 360.0, CL_REDSTONE_SAT, 1.0)) * 3.5; // activated redstone wire: red. Strength >2 so it gets an artificial-light alpha below and CASTS light (wire has no vanilla blocklight to re-hue, like CR's alpha "extra light").
	else if (length(emission - vec3(2.5, 2.05, 1.38)) < 0.05) emission = hsvToRgb(vec3(CL_TORCH_HUE / 360.0, CL_TORCH_SAT, 1.0)) * 2.5;
	else if (length(emission - vec3(2.5, 2.5, 2.25)) < 0.05) emission = hsvToRgb(vec3(CL_LANTERN_HUE / 360.0, CL_LANTERN_SAT, 1.0)) * 2.5;
	else if (length(emission - vec3(3, 3, 2.7)) < 0.05) emission = hsvToRgb(vec3(CL_LANTERN_HUE / 360.0, CL_LANTERN_SAT, 1.0)) * 3;
	else if (length(emission - vec3(1, 1, 0.9)) < 0.05) emission = hsvToRgb(vec3(CL_CAMPFIRE_HUE / 360.0, CL_CAMPFIRE_SAT, 1.0)) * 1;
	else if (length(emission - vec3(4, 1.6, 0)) < 0.05) emission = hsvToRgb(vec3(CL_LAVA_HUE / 360.0, CL_LAVA_SAT, 1.0)) * 2.0;
	else if (length(emission - vec3(1, 0.9, 0.8)) < 0.05) emission = hsvToRgb(vec3(CL_LAVACAULDRON_HUE / 360.0, CL_LAVACAULDRON_SAT, 1.0)) * 1;
	else if (length(emission - vec3(2.7, 3, 3)) < 0.05) emission = hsvToRgb(vec3(CL_SEALANTERN_HUE / 360.0, CL_SEALANTERN_SAT, 1.0)) * 3;
	else if (length(emission - vec3(3.5, 3.5, 3.5)) < 0.05) emission = hsvToRgb(vec3(CL_BEACON_HUE / 360.0, CL_BEACON_SAT, 1.0)) * 3.5;
	// glow lichen: a big DIM decal whose body isn't emissive-flagged, so (unlike compact sources whose
	// bright face is CL-excluded) its whole surface goes through the re-hue. Blend a WARM vanilla-blocklight
	// chroma -> the chosen pure hue by saturation, so at CL_LICHEN_SAT=0 its floodfill is warm (reads as
	// vanilla, like the light off) instead of grey/white. Done here at the source so it needs no per-fragment
	// gate in applyColoredLight (a gate desaturated soul-light edges + warmed stone around torches).
	else if (length(emission - vec3(0.3, 0.5, 0.4)) < 0.05) emission = mix(vec3(1.0, 0.8, 0.6), hsvToRgb(vec3(CL_LICHEN_HUE / 360.0, 1.0, 1.0)), CL_LICHEN_SAT) * 0.5;
	else if (length(emission - vec3(0.2, 0.4, 0.3)) < 0.05) emission = mix(vec3(1.0, 0.8, 0.6), hsvToRgb(vec3(CL_LICHEN_HUE / 360.0, 1.0, 1.0)), CL_LICHEN_SAT) * 0.4;
	else if (length(emission - vec3(0.7, 0.5, 0.3)) < 0.05) emission = hsvToRgb(vec3(CL_CAVEVINE_HUE / 360.0, CL_CAVEVINE_SAT, 1.0)) * 0.7;
	else if (length(emission - vec3(0.15, 0.08, 0.25)) < 0.05) emission = hsvToRgb(vec3(CL_AMETHYST_HUE / 360.0, CL_AMETHYST_SAT, 1.0)) * 0.25;
	else if (length(emission - vec3(0.3, 0.17, 0.5)) < 0.05) emission = hsvToRgb(vec3(CL_AMETHYST_HUE / 360.0, CL_AMETHYST_SAT, 1.0)) * 0.5;
	else if (length(emission - vec3(0.45, 0.26, 0.7)) < 0.05) emission = hsvToRgb(vec3(CL_AMETHYST_HUE / 360.0, CL_AMETHYST_SAT, 1.0)) * 0.7;
	else if (length(emission - vec3(1.32, 0.77, 2.09)) < 0.05) emission = hsvToRgb(vec3(CL_AMETHYST_HUE / 360.0, CL_AMETHYST_SAT, 1.0)) * 2.09;
	else if (length(emission - vec3(3.5, 2.52, 1.05)) < 0.05) emission = hsvToRgb(vec3(CL_OCHRE_HUE / 360.0, CL_OCHRE_SAT, 1.0)) * 3.5;
	else if (length(emission - vec3(1.75, 3.15, 1.57)) < 0.05) emission = hsvToRgb(vec3(CL_VERDANT_HUE / 360.0, CL_VERDANT_SAT, 1.0)) * 3.15;
	else if (length(emission - vec3(3.5, 2.1, 2.98)) < 0.05) emission = hsvToRgb(vec3(CL_PEARLESCENT_HUE / 360.0, CL_PEARLESCENT_SAT, 1.0)) * 3.5;
	else if (length(emission - vec3(0.4, 0.5, 0.5)) < 0.05) emission = hsvToRgb(vec3(CL_CONDUIT_HUE / 360.0, CL_CONDUIT_SAT, 1.0)) * 0.5;
	else if (length(emission - vec3(3.5, 3.15, 1.05)) < 0.05) emission = hsvToRgb(vec3(CL_GLOWSTONE_HUE / 360.0, CL_GLOWSTONE_SAT, 1.0)) * 3.5;
	else if (length(emission - vec3(2.8, 2.52, 1.4)) < 0.05) emission = hsvToRgb(vec3(CL_SHROOMLIGHT_HUE / 360.0, CL_SHROOMLIGHT_SAT, 1.0)) * 2.8;
	else if (length(emission - vec3(1, 0.3, 0.08)) < 0.05) emission = hsvToRgb(vec3(CL_MAGMA_HUE / 360.0, CL_MAGMA_SAT, 1.0)) * 1;
	else if (length(emission - vec3(0.5, 0.22, 0.9)) < 0.05) emission = hsvToRgb(vec3(CL_CRYING_HUE / 360.0, CL_CRYING_SAT, 1.0)) * 0.9;
	else if (length(emission - vec3(2.7, 2.85, 3)) < 0.05) emission = hsvToRgb(vec3(CL_ENDROD_HUE / 360.0, CL_ENDROD_SAT, 1.0)) * 3;
	else if (length(emission - vec3(1.4, 0.5, 2.1)) < 0.05) emission = hsvToRgb(vec3(CL_PORTAL_HUE / 360.0, CL_PORTAL_SAT, 1.0)) * 2.1;
	else if (length(emission - vec3(0.3, 0.3, 0.3)) < 0.05) emission = hsvToRgb(vec3(CL_SCULK_HUE / 360.0, CL_SCULK_SAT, 1.0)) * 0.3;
	else if (length(emission - vec3(0.1, 0.9, 1.1)) < 0.05) emission = hsvToRgb(vec3(CL_SCULKSENSOR_HUE / 360.0, CL_SCULKSENSOR_SAT, 1.0)) * 1.1;
	// enchanted item held by a player / mob: a small purple glow (strength from CL_ENCHANT_STRENGTH;
	// crosses the artificial-light threshold so it glows even with no vanilla light around).
	if (voxelId == CL_VOXEL_ENCHANT) emission = CL_ENCHANT_COLOR * (1.5 + 4.0 * CL_ENCHANT_STRENGTH) * step(0.001, CL_ENCHANT_STRENGTH);

	// diffuse light in from the 6 face neighbours (averaging — dividing by slightly
	// more than 6 makes the light gently attenuate as it fills the open space over many cells).
	// solid neighbours feed back this cell's own value so they don't absorb the light (see above).
	vec4 self = samplePrev(pos);
	vec4 diffuse =
		( neighbourLight(pos + ivec3( 1,  0,  0), self)
		+ neighbourLight(pos + ivec3(-1,  0,  0), self)
		+ neighbourLight(pos + ivec3( 0,  1,  0), self)
		+ neighbourLight(pos + ivec3( 0, -1,  0), self)
		+ neighbourLight(pos + ivec3( 0,  0,  1), self)
		+ neighbourLight(pos + ivec3( 0,  0, -1), self) )
		// divisor approaches 6.0 (almost no attenuation) as REACH goes up -> colour fills further
		/ (6.0 + 0.6 / float(COLORED_LIGHTING_REACH));

	// classify by voxel id: 0 = air, 1 = generic solid (occluder), 255 = unknown modded block,
	// 2..254 = registered blocks (only those carry real emission/translucency data).
	bool solid = voxelId == 1u || (voxelId == 255u && voteBits == 0u);
	vec4 light;
	if (solid) {
		light = vec4(0.0);                              // solid: blocks light
	} else if (voxelId == 0u) {
		light = diffuse;                                // air: spread light through it
	} else if (voxelId == 255u) {
		// unknown (unregistered modded) block: pass the light's COLOUR through, slightly damped, but
		// no artificial brightness — modded partial blocks (FD cutting boards, Create gear...) stop
		// blocking colored light, while full modded walls don't visibly leak (vanilla light doesn't
		// pass walls, and tint without light is invisible).
		light = vec4(diffuse.rgb * 0.75, 0.0);
	} else if (any(greaterThan(emission, vec3(0.001)))) {
		// light source: emit its colour. Derive an "artificial light" amount (the alpha) from the
		// source's emission strength — only genuinely strong emitters (lava, glowstone, sea lantern,
		// froglights) glow with colour beyond the vanilla blocklight; torches/weak sources (alpha ~0)
		// lean entirely on the vanilla lightmap. Use the brightest channel (not
		// luminance) so red-dominant sources like lava/redstone aren't under-weighted.
		float emissionStrength = max(emission.r, max(emission.g, emission.b));
		float artificial = smoothstep(2.0, 5.5, emissionStrength) * 0.7;
		light = vec4(emission, artificial);             // colour + artificial-light alpha
	} else {
		// translucent block: pass tinted light. The alpha (artificial light) is attenuated by the
		// tint's luminance: light.a *= dot(tint, vec3(0.333)).
		light = vec4(diffuse.rgb * translucency, diffuse.a * getLum(translucency));
	}

	// temporal easing: ease toward the freshly computed value so flicker from per-frame
	// voxelisation is smoothed out, and light fades gently when a source is removed
	light = mix(self, light, 0.5);

	light = clamp(light, vec4(0.0), vec4(100.0)); // guard against a stray NaN eating the volume

	// light level: vanilla-style max(neighbour - 1) propagation, blocked by solid cells (-1 = solid mark)
	float level = -1.0;
	if (!solid) {
		float n = max(max(max(prevLevel(pos + ivec3(1, 0, 0)), prevLevel(pos + ivec3(-1, 0, 0))),
		                  max(prevLevel(pos + ivec3(0, 1, 0)), prevLevel(pos + ivec3(0, -1, 0)))),
		              max(prevLevel(pos + ivec3(0, 0, 1)), prevLevel(pos + ivec3(0, 0, -1))));
		level = max(n - 1.0, any(greaterThan(emission, vec3(0.001))) ? emitLevel : 0.0);
	}

	if (readFromBuffer1()) {
		imageStore(clFloodB, pos, light);
		imageStore(clLevelB, pos, vec4(level));
	} else {
		imageStore(clFloodA, pos, light);
		imageStore(clLevelA, pos, vec4(level));
	}

}
