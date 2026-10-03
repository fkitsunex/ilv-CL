#ifndef APPLY_COLORED_LIGHT
#define APPLY_COLORED_LIGHT

#if COLORED_LIGHTING_ENABLED == 1

#include "/lib/colored_lighting/coloredLightingUtils.glsl"

uniform sampler3D clFloodASampler;
uniform sampler3D clFloodBSampler;
uniform usampler3D voxelIdsSampler;
uniform sampler3D clLevelASampler;
uniform sampler3D clLevelBSampler;
uniform usampler2D clEnchantSampler;

// light level of the coloured sources at the last sampled point (set by clSampleSmooth), see clDynShare
float clStaticLevel = 0.0;
// [particles] set to 1 before lighting a particle: the floodfill is sampled at 8 points around it and the
// colour is applied by the fraction of them that see coloured light (clCoverage), so a particle drifting
// behind a block loses its colour gradually instead of in one frame
float clSoftSample = 0.0;
float clCoverage = 1.0;
// [hand] set to 1 when lighting the first-person hand / held item: sample the volume at the CAMERA (like
// Complementary) — the hand's own position + normal offset lands in the wall/ceiling the player stands at
float clIsHand = 0.0;

// floodfill cells are vec4: rgb = colour (chroma / reach / dominance), a = "artificial
// light" (an artificial-light alpha — extra brightness strong sources cast even where the vanilla
// blocklight is too dim to reach).
// the floodfill compute ping-pongs by frame parity; on even frames the fresh result is in buffer B
vec4 clSampleCell(ivec3 pos) {
#ifdef CL_FRESH_READ
	// composite1 (fog glow) runs AFTER composite.csh, so THIS frame's floodfill is ready in the
	// current-parity buffer — read it fresh (no delay, no camera-shift correction needed below).
	return (frameCounter % 2 == 0) ? texelFetch(clFloodBSampler, pos, 0)
	                               : texelFetch(clFloodASampler, pos, 0);
#else
	// Surface lighting (gbuffers stage) runs BEFORE composite.csh, so this frame's floodfill isn't ready.
	// The freshest COMPLETED result is last frame's, in the buffer this frame is NOT writing (opposite
	// parity). Reading the current-parity buffer here would return the result from 2 frames ago, which
	// flickers badly when moving. Read the opposite buffer for a clean, single-frame delay instead.
	return (frameCounter % 2 == 0) ? texelFetch(clFloodASampler, pos, 0)
	                               : texelFetch(clFloodBSampler, pos, 0);
#endif
}

// same parity rule for the light-level volume (-1 = solid cell)
float clSampleLevelCell(ivec3 pos) {
#ifdef CL_FRESH_READ
	return (frameCounter % 2 == 0) ? texelFetch(clLevelBSampler, pos, 0).r
	                               : texelFetch(clLevelASampler, pos, 0).r;
#else
	return (frameCounter % 2 == 0) ? texelFetch(clLevelASampler, pos, 0).r
	                               : texelFetch(clLevelBSampler, pos, 0).r;
#endif
}

// trilinearly interpolated sample of the floodfill volume (smooths the blocky cell edges).
// done by hand (8 corner fetches) so it works with the wrapped/clamped addressing.
// [leak fix] SOLID corner cells are skipped and the remaining weights renormalised, so a surface or a
// particle never blends in the light from the far side of a wall (the old plain trilinear filter
// reached one cell into/through walls and corners, bleeding colour onto the dark side).
// one masked trilinear fetch at grid point p (see clSampleSmooth). ok = false when nothing usable is found.
// Filter after Complementary's ACT corner-leak fix: relative to the cell that CONTAINS the sample point
// ("own"), the 2x2x2 corners are taken only if light could actually travel there — the far diagonal corner
// never, an edge-diagonal corner only if one of the two axial cells between is open, and solid cells never.
// So neither surfaces nor particles pick up light from the far side of a block.
vec4 clSampleMasked(vec3 p, out bool ok, out vec4 unmasked) {
	vec3 base = floor(p);
	vec3 f = p - base;
	ivec3 ib = ivec3(base);
	ivec3 ownO = ivec3(greaterThanEqual(f, vec3(0.5))); // which corner of the box contains the sample point
	vec4 cell[8];
	float lv[8];
	unmasked = vec4(0.0);
	for (int i = 0; i < 8; i++) {
		ivec3 o = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
		ivec3 storage = clamp(ib + o, ivec3(0), coloredLightingSize - 1);
		vec3 w3 = mix(1.0 - f, f, vec3(o));
		cell[i] = clSampleCell(storage);
		unmasked += w3.x * w3.y * w3.z * cell[i];
		float l = clSampleLevelCell(storage);
		lv[i] = (isnan(l) || !(l <= 15.0)) ? 0.0 : l; // uninitialised / garbage cell -> 0
	}
	int own = ownO.x + ownO.y * 2 + ownO.z * 4;
	ok = false;
	if (lv[own] < -0.5) return unmasked; // sample point inside a solid block -> caller steps further out
	// the 3 axial neighbours of "own" inside the box: open?
	bool openX = lv[own ^ 1] > -0.5;
	bool openY = lv[own ^ 2] > -0.5;
	bool openZ = lv[own ^ 4] > -0.5;
	vec4 result = vec4(0.0);
	float wsum = 0.0;
	float levelPow = 0.0;
	for (int i = 0; i < 8; i++) {
		if (lv[i] < -0.5) continue; // solid
		int d = i ^ own;
		int dist = (d & 1) + ((d >> 1) & 1) + ((d >> 2) & 1);
		if (dist == 3) continue; // far diagonal corner: never reachable around a block edge
		if (dist == 2) {
			bool reachable = ((d & 1) != 0 && openX) || ((d & 2) != 0 && openY) || ((d & 4) != 0 && openZ);
			if (!reachable) continue;
		}
		ivec3 o = ivec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
		vec3 w3 = mix(1.0 - f, f, vec3(o));
		float w = w3.x * w3.y * w3.z;
		result += w * cell[i];
		// soft maximum of the coloured sources' level (power mean): as generous as the brightest open cell —
		// the volume only holds what the camera saw, so a plain average under-reads corners — but continuous,
		// so the colour / dynamic-light boundary stays smooth instead of following block edges
		float ln = lv[i] / 15.0;
		ln *= ln; ln *= ln; ln *= ln; // ^8
		levelPow += w * ln;
		wsum += w;
	}
	if (wsum < 0.0001) return unmasked;
	ok = true;
	clStaticLevel = 15.0 * sqrt(sqrt(sqrt(levelPow / wsum)));
	return result / wsum;
}

vec4 clSampleSmooth(vec3 playerPos, vec3 offset) {
	// When we read a 1-frame-old floodfill (surface lighting, see clSampleCell), it was computed aligned to
	// LAST frame's camera. Shift the sample by the integer camera movement since then so the light stays
	// locked to the world as the camera moves — without this it jumps a whole cell every time
	// floor(cameraPosition) changes (flicker while moving, worse the stronger the colour). The fresh read
	// (fog glow) is already aligned to THIS frame's camera, so no shift there.
#ifdef CL_FRESH_READ
	// fog glow: plain trilinear filter (no wall masking — rays from a camera hugging a wall start in/at
	// blocks, and renormalising there made the fog glow clip)
	vec3 p = playerPos + cameraPositionFract + offset + vec3(halfColoredLightingSize) - 0.5;
	vec3 base = floor(p);
	vec3 f = p - base;
	vec4 result = vec4(0.0);
	for (int i = 0; i < 8; i++) {
		vec3 o = vec3(i & 1, (i >> 1) & 1, (i >> 2) & 1);
		ivec3 storage = clamp(ivec3(base + o), ivec3(0), coloredLightingSize - 1);
		vec3 w = mix(1.0 - f, f, o);
		result += w.x * w.y * w.z * clSampleCell(storage);
	}
	return result;
#else
	vec3 camShift = floor(cameraPosition) - floor(previousCameraPosition);
	vec3 p = playerPos + cameraPositionFract + offset + vec3(halfColoredLightingSize) - 0.5 + camShift;
	if (clSoftSample > 0.5) {
		// centred on the particle itself (its normal is just "towards the camera"); points that land inside
		// blocks are IGNORED, not counted as dark — break particles hugging a wall half-overlap it
		vec3 pc = p - offset;
		vec4 acc = vec4(0.0);
		float levelAcc = 0.0;
		float nOk = 0.0;
		float cov = 0.0;
		for (int i = 0; i < 9; i++) {
			vec3 jitter = i == 8 ? vec3(0.0) : (vec3(i & 1, (i >> 1) & 1, (i >> 2) & 1) - 0.5) * 0.7; // 8 corners + centre
			bool okS;
			vec4 unmaskedS;
			vec4 r = clSampleMasked(pc + jitter, okS, unmaskedS);
			if (!okS) continue;
			acc += r;
			levelAcc += clStaticLevel;
			nOk += 1.0;
			cov += smoothstep(0.0, 0.004, max(r.r, max(r.g, r.b)));
		}
		if (nOk > 0.5) {
			clCoverage = cov / nOk; // fraction of the OPEN points that see coloured light
			clStaticLevel = levelAcc / nOk;
			return acc / nOk;
		}
		// every point inside blocks: fall through to the regular sample + fallbacks below
	}
	bool ok;
	vec4 unmasked;
	vec4 result = clSampleMasked(p, ok, unmasked);
	if (ok) return result;
	// every corner solid: inner corners, or a depth-reconstructed normal at a grazing angle pointing into the
	// wall. Step one block further out along the offset and try again before giving up.
	if (dot(offset, offset) > 0.0001) {
		vec4 unmasked2;
		// entities / dropped items / particles beside a wall: the offset along the normal points into the
		// wall, but the object itself sits in open air -> try its own position first
		result = clSampleMasked(p - offset, ok, unmasked2);
		if (ok) return result;
		// terrain (own position is inside the block): one block further out
		result = clSampleMasked(p + normalize(offset), ok, unmasked2);
		if (ok) return result;
	}
	clStaticLevel = 15.0; // unknown here -> don't apply the dynamic-light split
	return unmasked;
#endif
}

#if HANDHELD_LIGHT_ENABLED == 1
	// colour of a held light source (ids come from item.properties); warm by default
	// held-light colour, driven by the same per-source HUE+saturation sliders as the placed blocks, so
	// an item in hand matches its placed form. This is the ONLY held-light path (held items are not
	// voxelised), so it never enters the coloured fog / floodfill volume.
	vec3 clHeldLightColor(int id) {
		if (id == 4101) return hsvToRgb(vec3(CL_SOUL_HUE / 360.0, CL_SOUL_SAT, 1.0));               // soul
		if (id == 4102) return hsvToRgb(vec3(CL_REDSTONE_HUE / 360.0, CL_REDSTONE_SAT, 1.0));       // redstone
		if (id == 4103) return hsvToRgb(vec3(CL_SEALANTERN_HUE / 360.0, CL_SEALANTERN_SAT, 1.0));   // sea lantern
		if (id == 4104) return hsvToRgb(vec3(CL_VERDANT_HUE / 360.0, CL_VERDANT_SAT, 1.0));         // verdant froglight
		if (id == 4105) return hsvToRgb(vec3(CL_OCHRE_HUE / 360.0, CL_OCHRE_SAT, 1.0));             // ochre froglight
		if (id == 4106) return hsvToRgb(vec3(CL_PEARLESCENT_HUE / 360.0, CL_PEARLESCENT_SAT, 1.0)); // pearlescent
		if (id == 4107) return hsvToRgb(vec3(CL_AMETHYST_HUE / 360.0, CL_AMETHYST_SAT, 1.0));       // amethyst
		if (id == 4108) return hsvToRgb(vec3(CL_LANTERN_HUE / 360.0, CL_LANTERN_SAT, 1.0));         // (regular) lantern
		if (id == 4109) return hsvToRgb(vec3(CL_GLOWSTONE_HUE / 360.0, CL_GLOWSTONE_SAT, 1.0));     // glowstone
		if (id == 4110) return hsvToRgb(vec3(CL_SHROOMLIGHT_HUE / 360.0, CL_SHROOMLIGHT_SAT, 1.0)); // shroomlight
		if (id == 4111) return hsvToRgb(vec3(CL_MAGMA_HUE / 360.0, CL_MAGMA_SAT, 1.0));             // magma block
		if (id == 4112) return hsvToRgb(vec3(CL_ENDROD_HUE / 360.0, CL_ENDROD_SAT, 1.0));           // end rod
		if (id == 4113) return hsvToRgb(vec3(CL_TORCH_HUE / 360.0, CL_TORCH_SAT, 1.0));             // torch
		if (id == 4114) return hsvToRgb(vec3(CL_CAMPFIRE_HUE / 360.0, CL_CAMPFIRE_SAT, 1.0));       // campfire
		if (id == 4115) return hsvToRgb(vec3(CL_CAMPFIRE_HUE / 360.0, CL_CAMPFIRE_SAT, 1.0));       // jack o'lantern
		if (id == 4116) return hsvToRgb(vec3(CL_CRYING_HUE / 360.0, CL_CRYING_SAT, 1.0));           // crying obsidian
		if (id == 4117) return hsvToRgb(vec3(CL_BEACON_HUE / 360.0, CL_BEACON_SAT, 1.0));           // beacon
		if (id == 4118) return hsvToRgb(vec3(CL_CONDUIT_HUE / 360.0, CL_CONDUIT_SAT, 1.0));         // conduit
		if (id == 4119) return hsvToRgb(vec3(CL_CAVEVINE_HUE / 360.0, CL_CAVEVINE_SAT, 1.0));       // glow berries
		return hsvToRgb(vec3(CL_TORCH_HUE / 360.0, CL_TORCH_SAT, 1.0));                             // generic warm
	}
#endif

// [enchant light] gbuffers_hand stamps frameCounter into clEnchant (x=0 right hand, x=1 left hand) while
// drawing an enchanted item's texels. Surfaces lit in the following ~2 frames read it back, so the
// player's enchanted held item casts a small purple light on the hand and its surroundings.
float clEnchantHands() {
	float hands = 0.0;
	for (int i = 0; i < 2; i++) {
		int age = frameCounter - int(texelFetch(clEnchantSampler, ivec2(i, 0), 0).r);
		if (age < 0) age += 720720; // frameCounter wraps at 720720
		hands += (age <= 2) ? 1.0 : 0.0;
	}
	return hands;
}

// purple light from the player's own enchanted held item(s) reaching this surface (0 = none). ADDED to
// the lighting in fsh_lighting, so it mixes naturally with an offhand torch / the floodfill colour.
// (Float settings must not be compared in #if — the preprocessor truncates 0.35 to 0 — so runtime ifs.)
float clEnchantLightAt(vec3 viewPos, vec3 normal) {
	if (CL_ENCHANT_STRENGTH <= 0.0) return 0.0;
	float ench = clEnchantHands();
	if (ench <= 0.0) return 0.0;
	float eFall = max(1.0 - length(viewPos) / 7.0, 0.0);
	eFall *= eFall;
	float facing = 0.6 + 0.4 * max(dot(normal, -normalize(viewPos)), 0.0);
	return eFall * facing * CL_ENCHANT_STRENGTH * (0.8 + 0.2 * ench);
}

// [particles] vanilla lights a particle with the light of the block its CENTRE is in, so one sinking into a
// wall goes dark in a single frame (light 0 inside opaque blocks). Keep it at least at the (smooth, open-air)
// level of the coloured sources around it instead. Returns the adjusted lightmap blocklight value.
vec4 clColorAt4(vec3 viewPos, vec3 normal, out bool outside); // defined below
float clParticleBlockLight(vec3 viewPos, vec3 normal, float lm) {
	bool outside;
	clColorAt4(viewPos, normal, outside);
	if (outside) return lm;
	return max(lm, clamp((clStaticLevel - 0.5) / 12.0, 0.0, 1.0)); // inverse of adjustLmcoord
}

// floodfill colour + artificial-light alpha reaching this surface (offset into the air in front so
// we don't read the opaque block itself). also blends in the held light's colour near the player.
vec4 clColorAt4(vec3 viewPos, vec3 normal, out bool outside) {
	vec3 clPlayerPos = transform(gbufferModelViewInverse, viewPos);
	vec3 clWorldNormal = mat3(gbufferModelViewInverse) * normal;
	if (clIsHand > 0.5) { clPlayerPos = vec3(0.0); clWorldNormal = vec3(0.0); } // hand: sample at the camera
	getVoxelPos(clPlayerPos, clWorldNormal * 0.5, outside);
	if (outside) return vec4(0.0);
	vec4 cl = clSampleSmooth(clPlayerPos, clWorldNormal * 0.5);
	#if HANDHELD_LIGHT_ENABLED == 1
		// the handheld light isn't voxelised (it moves with the player), so colour it here — PER HAND.
		// each hand contributes its own colour weighted by ITS OWN vanilla block-light value, so an
		// offhand torch can't paint the mainhand item's colour. (Old bug: a single heldItemId meant a
		// torch in one hand + amethyst in the other turned everything purple.) Squared distance
		// falloff keeps the colour in a tight, torch-like pool near the player.
		float distFall = max(1.0 - length(viewPos) / min(HANDHELD_LIGHT_DISTANCE, 14.0), 0.0);
		distFall *= distFall;
		float w1 = distFall * (float(heldBlockLightValue)  / 15.0); // mainhand coverage
		float w2 = distFall * (float(heldBlockLightValue2) / 15.0); // offhand coverage
		float wsum = w1 + w2;
		if (wsum > 0.0001) {
			vec3 heldCol = (clHeldLightColor(heldItemId) * w1 + clHeldLightColor(heldItemId2) * w2) / wsum;
			cl.rgb = mix(cl.rgb, heldCol, clamp(max(w1, w2), 0.0, 1.0));
		}
	#endif
	return cl;
}

// rgb-only wrapper (used by the debug view)
vec3 clColorAt(vec3 viewPos, vec3 normal, out bool outside) {
	return clColorAt4(viewPos, normal, outside).rgb;
}

// fade the effect out toward the edge of the voxel volume so its boundary isn't visible
// (a smooth distance fade toward the volume edge)
float clEdgeFade(vec3 viewPos) {
	vec3 rel = abs(transform(gbufferModelViewInverse, viewPos) + cameraPositionFract) / vec3(halfColoredLightingSize);
	return 1.0 - smoothstep(0.75, 1.0, max(rel.x, max(rel.y, rel.z)));
}

// extra "artificial" light cast by the very strongest sources (lava, glowstone, ...) so they glow
// with colour even where the vanilla blocklight is too dim to reach. This is now read straight from
// the floodfill alpha that propagates with the light, instead of being guessed
// per-fragment from the colour magnitude.
float clArtificialLight(vec3 viewPos, vec3 normal) {
	bool outside;
	vec4 cl = clColorAt4(viewPos, normal, outside);
	if (outside) return 0.0;
	return clamp(cl.a, 0.0, 1.0) * clEdgeFade(viewPos);
}

// re-hue a (monochrome, warm) blocklight colour toward the floodfill colour at this fragment,
// WITHOUT changing its brightness. The key trick: the floodfill supplies only chroma — it's
// luminance-normalised and re-applied at the original light's luminance, so
// the coloured light is exactly as bright as the vanilla warm blocklight. (The old code multiplied
// by a max-normalised tint whose non-peak channels were < 1, which DARKENED torches/campfires.)
// cached variant: takes a PRE-SAMPLED floodfill value + edge fade, so fsh_lighting can sample the volume
// ONCE and reuse it for both the re-hue here and the artificial-light boost (was two clColorAt4 fetches
// + two clEdgeFade per fragment).
// [dyn-light split] how much of this fragment's blocklight the coloured sources (+ the player's OWN held
// light) account for. LambDynLights raises the lightmap around burning mobs, dropped torches, other
// entities' held lights...; before, that extra light was re-hued with the local floodfill colour, so it
// AMPLIFIED the coloured source. Now light above the sources' own vanilla level stays default warm and
// mixes in. rawBlock = lmcoord.x (adjusted: level ~ x*12 + 0.5, levels 13-15 clamp to 12.5).
float clDynShare(float rawBlock, vec3 viewPos) {
	#if CL_DYN_SPLIT == 0
		return 1.0;
	#endif
	float L = rawBlock * 12.0 + 0.5;
	float dist = length(viewPos);
	float Lh = float(max(heldBlockLightValue, heldBlockLightValue2)) - dist * 0.9; // own held light (LambDynLights-style falloff)
	#if HANDHELD_LIGHT_ENABLED == 1
		Lh = max(Lh, (1.0 - dist / HANDHELD_LIGHT_DISTANCE) * float(max(heldBlockLightValue, heldBlockLightValue2)) / 15.0 * HANDHELD_LIGHT_BRIGHTNESS * 12.0 + 0.5);
	#endif
	float Ls = min(max(clStaticLevel, Lh), 12.5);
	return 1.0 - smoothstep(2.0, 6.0, L - Ls); // generous margin: vanilla smooth lighting wobbles by a level or two
}

vec3 applyColoredLight(vec3 blockLight, vec4 clSample, bool outside, float clEdge, float glowingAmount, float dynShare) {
	if (outside) return blockLight;
	vec3 cl = clSample.rgb;

	float lum = getLum(blockLight);
	float m = max(max(cl.r, cl.g), cl.b);
	vec3 floodChroma = cl / (getLum(cl) + 0.0001);          // floodfill colour at luminance 1
	vec3 baseChroma  = blockLight / (lum + 0.0001);         // original warm blocklight at luminance 1

	// how much of the floodfill hue to apply: scaled by the saturation slider,
	// and ramped in only where the floodfill has essentially no colour. The threshold is intentionally TINY
	// (0.004): the hue is luminance-normalised and re-applied at the vanilla blocklight's brightness
	// (colored = lum * chroma), so it must follow the blocklight out to its full range. A larger cutoff cut
	// the hue off where the floodfill dims — well BEFORE the vanilla blocklight ends — leaving a lit but
	// uncoloured ring around every source (worse the higher COLORED_LIGHTING_STRENGTH is). Because brightness
	// comes from the blocklight, applying the hue this far never tints unlit cells (lum ~ 0 there).
	float reach = smoothstep(0.0, 0.004, m) * COLORED_LIGHTING_SATURATION * dynShare * clCoverage;
	vec3 chroma = mix(baseChroma, floodChroma, reach);
	vec3 colored = lum * chroma;                            // re-hued at the SAME brightness

	// overall strength; faded out on a source's own emissive face (so its texture keeps its colours)
	// and toward the volume edge.
	float amt = COLORED_LIGHTING_STRENGTH * (1.0 - clamp(glowingAmount * 2.0, 0.0, 1.0)) * clEdge;
	return mix(blockLight, colored, amt);
}

// convenience overload that samples the volume itself — used where the sample isn't already shared
// (e.g. simple_fsh_lighting). fsh_lighting uses the cached variant above to avoid the double fetch.
vec3 applyColoredLight(vec3 blockLight, vec3 viewPos, vec3 normal, float glowingAmount, float rawBlock) {
	bool outside;
	vec4 clSample = clColorAt4(viewPos, normal, outside);
	return applyColoredLight(blockLight, clSample, outside, clEdgeFade(viewPos), glowingAmount, 1.0); // simple lighting (particles, weather): no dyn-light split
}

#endif

#endif
