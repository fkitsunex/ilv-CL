#ifndef TRANSLUCENT_OVERLAY
#define TRANSLUCENT_OVERLAY

// [translucent overlay] Mod beams rendered by block-entity renderers (e.g. Create Gadgets & Gizmos thrusters,
// RenderType.entityTranslucentEmissive) are drawn by Iris in the OPAQUE block-entity group — BEFORE deferred
// lighting. In this deferred pack the sky, Distant Horizons terrain and water don't exist yet at that point,
// and the beam's depth write then hides them behind it (dark beams, missing water / DH behind them).
// So translucent fragments are lit right away, stashed here (nearest layer per pixel) and DISCARDED from the
// gbuffers; composite4 blends the stash over the finished scene with a depth test.
#if COLORED_LIGHTING_ENABLED == 1 && defined FSH
	#extension GL_ARB_shader_image_load_store : enable
	layout(rgba16f) uniform writeonly image2D clTransColor;
	layout(r32ui) uniform uimage2D clTransDepth;
	// accumulated optical depth of ALL layers at the pixel: sum of -ln(1 - alpha) (x1024, atomic add), so the
	// combined opacity is exactly 1 - prod(1 - alpha_i) — beams are several stacked translucent boxes (inner
	// beam + outer glow, front + back faces) and keeping only one layer made them nearly invisible
	layout(r32ui) uniform uimage2D clTransAlpha;
	void storeTranslucentOverlay(vec4 litColor) {
		ivec2 px = ivec2(gl_FragCoord.xy);
		uint code = uint(clamp(1.0 - gl_FragCoord.z, 0.0, 1.0) * 1073741823.0) + 1u; // larger = nearer, 0 = none
		uint prev = imageAtomicMax(clTransDepth, px, code);
		if (code >= prev) imageStore(clTransColor, px, litColor); // colour of the nearest layer
		imageAtomicAdd(clTransAlpha, px, uint(-log(1.0 - clamp(litColor.a, 0.0, 0.98)) * 1024.0 + 0.5));
	}
#endif

#endif
