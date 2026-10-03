#ifndef ENCHANT_OUTLINES
#define ENCHANT_OUTLINES

// [enchant fullbright] The Enchantment Outlines resource pack marks the texels of enchanted items by an
// exact alpha value, which its own core shader (ignored under Iris) renders unlit:
//   252 / 253 = enchanted item body (first-person textures + the whole third-person texture)
//   200       = the purple outline glow (first person only)
// Read at LOD 0 so mipmapping can't blend the marker away. Vanilla/mod item textures use alpha 0/255,
// so these exact values are safe to key on (the outline value only in the first-person hand passes).
// The outline texture itself is near-white (255,214,255); in vanilla it reads purple because the
// enchantment glint is drawn over it. The glint can't reach it here (the outline is composited without
// writing depth), so tint it with the glint purple instead.
#define ENCHANT_OUTLINE_TINT hsvToRgb(vec3(ENCHANT_OUTLINE_HUE / 360.0, ENCHANT_OUTLINE_SAT, 1.0))

bool isEnchantTexel(vec2 uv, bool allowOutline) {
	float a = texture2DLod(MAIN_TEXTURE, uv, 0.0).a * 255.0;
	return abs(a - 252.0) < 0.5 || abs(a - 253.0) < 0.5 || (allowOutline && abs(a - 200.0) < 0.5);
}

#if COLORED_LIGHTING_ENABLED == 1 && defined FSH
	#extension GL_ARB_shader_image_load_store : enable
	// per-hand frame stamps (x=0 right side of the screen, x=1 left), read back by clEnchantHands()
	layout(r32ui) uniform writeonly uimage2D clEnchant;
	void stampEnchantHand() {
		imageStore(clEnchant, ivec2(gl_FragCoord.x < viewWidth * 0.5 ? 1 : 0, 0), uvec4(uint(frameCounter), 0u, 0u, 0u));
	}
	// first-person outline texel: stash its raw texture colour + depth (+1, so the cleared 0 = "none");
	// deferred1 blends it over the LIT pixel. Done this way because in the deferred hand pass a translucent
	// fragment is blended with the background's albedo BEFORE lighting, so any fullbright on it would also
	// light up the world seen through it (the opaque white band).
	// The outline model is extruded (front/back/edge faces), so several of its fragments hit one pixel in
	// random order: storing the depth with a plain imageStore made the depth test against the item body
	// flicker (noise). Keep the NEAREST depth with an atomic max of the inverted, quantised depth instead.
	layout(rgba16f) uniform writeonly image2D clOutline;
	layout(r32ui) uniform uimage2D clOutlineDepth;
	void storeEnchantOutline(vec3 rgb) {
		ivec2 px = ivec2(gl_FragCoord.xy);
		imageStore(clOutline, px, vec4(rgb, 1.0));
		imageAtomicMax(clOutlineDepth, px, uint(clamp(1.0 - gl_FragCoord.z, 0.0, 1.0) * 1073741823.0) + 1u);
	}
	#ifdef ENCHANT_VOXELIZE
		#include "/lib/colored_lighting/coloredLightingUtils.glsl"
		layout(r8ui) uniform writeonly uimage3D voxelIds;
		// enchanted item on another player / a mob: drop a purple emitter voxel where it's drawn
		// (fragment-stage twin of voxelizeDynamicLight, which can't be included here: it pulls in
		// blockDatas, whose voxel-id code reads the vertex attribute gl_Normal)
		void voxelizeEnchant(vec3 playerPos) {
			bool outsideRange;
			ivec3 voxelPos = getVoxelPos(playerPos, vec3(0.0), outsideRange);
			if (!outsideRange) imageStore(voxelIds, voxelPos, uvec4(CL_VOXEL_ENCHANT, 0u, 0u, 0u));
		}
	#endif
#endif

#endif
