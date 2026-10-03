in_out vec2 texcoord;
in_out vec2 lmcoord;
in_out vec4 glcolor;
in_out vec3 viewPos;
#if PBR_TYPE == 0
	flat in_out vec3 normal;
	flat in_out vec2 encodedNormal;
#elif PBR_TYPE == 1
	flat in_out mat3 tbn;
#endif



#ifdef FSH

#include "/lib/lighting/fsh_lighting.glsl"
#define ENCHANT_VOXELIZE
#include "/lib/enchant_outlines.glsl"

void main() {
	
	// Nametag detection: entity.properties maps the floating name labels to id 10001.
	// They are flat translucent overlays — lighting/reflecting them shades the dark background quad
	// and lets it corrupt the gbuffer normal/reflection of whatever is behind. Render them flat.
	bool isNametag = (entityId == 10001);

	vec4 color = texture2D(MAIN_TEXTURE, texcoord);
	color *= glcolor;

	// [entity fire] the flames on a burning entity are separate quads that vanilla draws with the FULL_BRIGHT
	// lightmap and a straight-up normal (EntityRenderDispatcher.renderFlame). Recognise them by exactly that
	// (+ a fire-coloured texel) and draw them like vanilla: raw texture, unlit at full brightness — they were
	// darkened by the entity colour curve below and lit by the scene like any mob surface.
	bool isEntityFire = false;
	#if PBR_TYPE == 1
		vec3 fireNormal = tbn[2];
	#else
		vec3 fireNormal = normal;
	#endif
	if (!isNametag && lmcoord.x > 0.99 && lmcoord.y > 0.99 && (mat3(gbufferModelViewInverse) * fireNormal).y > 0.95) {
		vec3 fireHsv = rgbToHsv(color.rgb);
		isEntityFire = (fireHsv.x < 0.17 || fireHsv.x > 0.97) && (fireHsv.y > 0.3 || fireHsv.z > 0.85);
	}
	vec3 fireColor = color.rgb;

	// [enchant fullbright] enchanted item held by another player / a mob (Enchantment Outlines marks the
	// whole third-person texture with alpha 252): render it unlit, and drop a purple light voxel at it so
	// it lights its surroundings like the player's own enchanted item.
	bool isEnchanted = !isNametag && isEnchantTexel(texcoord, false);
	#if COLORED_LIGHTING_ENABLED == 1
		if (isEnchanted && CL_ENCHANT_STRENGTH > 0.0) voxelizeEnchant(transform(gbufferModelViewInverse, viewPos));
	#endif

	// [skin transparency] The dedicated translucent-entity pass is disabled (enabling it makes ALL
	// entities translucent+reflective), so the player's translucent OUTER skin layer falls back to this
	// opaque pass and renders see-through onto the inner layer. Treat it as CUTOUT for the near-opaque
	// texels: force the outer layer's solid detail (alpha ~1) fully opaque so it occludes the inner, and
	// discard the fully-transparent texels — while leaving GENUINE mid-alpha (slimes/ghasts ~0.4-0.6) to
	// keep blending, and never touching nametags (their own handling is below).
	if (!isNametag) {
		if (color.a < 0.1) discard;
		else if (color.a > 0.7) color.a = 1.0;
	}

	color.rgb = color.rgb - (4.0 / 27.0) * color.rgb * color.rgb * color.rgb;
	
	float m = getLum(color.rgb);
	m = m * m * (3.0 - 2.0 * m);
	color.rgb *= 1.0 - TEXTURE_CONTRAST * 0.125 + m * TEXTURE_CONTRAST * 0.25;
	
	
	// hurt flash, creeper flash, etc
	color.rgb = mix(color.rgb, entityColor.rgb, min(entityColor.a * 1.5, 1.0));
	if (isEntityFire) color.rgb = fireColor; // flames: raw texture (no colour curve / hurt flash)
	//color.rgb *= 1.0 + (1.0 - max(lmcoord.x, lmcoord.y)) * entityColor.a;

	// Nametag background is a dark translucent quad that WRITES DEPTH, so it occludes the water (and
	// other translucents) drawn behind it — a visible hole, especially when the tag fades while
	// sneaking. Discard the near-black background fragments so water renders behind; the text stays.
	if (isNametag && getLum(color.rgb) < 0.025) discard;


	#if PBR_TYPE == 0
		float reflectiveness = 0.0;
		float specularness = 0.3;
	#elif PBR_TYPE == 1
		vec2 pbrData = texture2D(specular, texcoord).rg;
		float reflectiveness = pbrData.g;
		// [upstream I-Like-Vanilla v1.4.5] labPBR metal fix: F0 values 230-255 are a metal-type
		// index, not a reflectance, so using pbrData.g raw made metals near-mirror ("too reflective").
		if (int(reflectiveness * 255.0 + 0.5) > 229) reflectiveness -= 175.0 / 255.0;
		reflectiveness *= 0.5;
		float specularness = sqrt(pbrData.r);
		vec3 normal = texture2D(normals, texcoord).rgb;
		normal.xy -= 0.5;
		normal.xy *= PBR_NORMALS_AMOUNT * 0.75;
		normal.xy += 0.5;
		normal = normalize(normal * 2.0 - 1.0);
		normal = tbn * normal;
		vec2 encodedNormal = encodeNormal(normal);
	#endif

	// Nametags: no reflection, and tag with the 253/255 no-reflect flag so they're kept out of water
	// reflections (the flag is read back by the reflection pass at the ray hit).
	if (isNametag) {
		reflectiveness = 0.0;
		specularness = 253.0 / 255.0;
	}
	// enchanted texels: 252/255 = fullbright flag (read by deferred1), or unlit right here after deferred
	if (isEnchanted) {
		reflectiveness = 0.0;
		specularness = 252.0 / 255.0;
		fshFullbright = 1.0;
	}
	if (isEntityFire) {
		reflectiveness = 0.0;
		specularness = 251.0 / 255.0; // entity-fire flag, read by deferred1
		fshFullbright = 1.0;
		fshFullbrightLevel = 1.0;
	}


	// main lighting (skipped for nametags so they stay flat/unlit, like vanilla)
	float isAfterDeferred = texelFetch(colortex10, ivec2(0), 0).r;
	if (isAfterDeferred > 0.5 && !isNametag) {
		float _inSunlightAmount;
		doFshLighting(color.rgb, _inSunlightAmount, lmcoord.x, lmcoord.y, (isEnchanted || isEntityFire) ? 0.3 : specularness, 0.0, viewPos, normal, gl_FragCoord.z);
	}
	
	
	/* DRAWBUFFERS:02 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(0.5, 1.0, 0.0, 1.0);
	#endif
	color.rgb *= 0.5;
	gl_FragData[0] = vec4(color);
	gl_FragData[1] = vec4(
		pack_2x8(lmcoord),
		pack_2x8(reflectiveness, specularness),
		encodedNormal
	);
	
}

#endif



#ifdef VSH

#include "/utils/projections.glsl"
#include "/lib/lighting/vsh_lighting.glsl"

#if TAA_ENABLED == 1
	#include "/lib/taa_jitter.glsl"
#endif

// [dynamic lighting] voxelise light-emitting items rendered here (dropped items, and items held/worn by
// mobs & players) so the colour floodfill lights the world around them, like LambDynLights but coloured.
#if COLORED_LIGHTING_ENABLED == 1
	#include "/lib/colored_lighting/dynamicLight.glsl"
#endif

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	adjustLmcoord(lmcoord);
	glcolor = gl_Color;
	#ifdef NETHER
		// remove entity shadows, may cause other problems
		if (glcolor.a < 1.0) {
			gl_Position = vec4(1.0);
			return;
		}
	#endif
	
	#if PBR_TYPE != 0
		vec3 normal;
	#endif
	normal = gl_NormalMatrix * gl_Normal;

	// [entity shadow blob fix] With real-time shadows OFF, MC draws the vanilla entity shadow (a flat
	// translucent ground decal under mobs). Our deferred pipeline can't multiply it onto the ground, so
	// it comes out as a bright lit oval (e.g. a green blob on grass at night) instead of a shadow. Cull
	// it: a translucent, flat upward-facing quad. Gated to shadows-OFF only, so translucent mobs stay
	// intact when shadows are on (and with shadows on the blob isn't drawn anyway). The upward-normal
	// test keeps slime/ghast side faces safe — only near-horizontal translucent decals are removed.
	#if (defined(OVERWORLD) && OVERWORLD_SHADOWS_TYPE != 2) || (defined(END) && END_SHADOWS_TYPE != 2)
		if (glcolor.a < 1.0 && dot(normalize(normal), normalize(gbufferModelView[1].xyz)) > 0.9) {
			gl_Position = vec4(1.0);
			return;
		}
	#endif
	// Mobs' many small angled faces catch the directional side-shading from every direction and read
	// noticeably darker than the terrain around them (same family as the old too-dark cross-plants,
	// which got fully upward normals). Bias entity lighting normals toward "up" to soften that —
	// they keep some directionality but stop being uniformly dim.
	normal = normalize(mix(normal, normalize(gbufferModelView[1].xyz), 0.35));
	#if PBR_TYPE == 0
		encodedNormal = encodeNormal(normal);
	#endif
	#if PBR_TYPE == 1
		vec3 tangent = normalize(gl_NormalMatrix * at_tangent.xyz);
		vec3 bitangent = normalize(cross(normal, tangent) * at_tangent.w);
		tbn = mat3(tangent, bitangent, normal);
	#endif
	
	viewPos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);

	// [dynamic lighting] if this fragment belongs to a light-emitting item (dropped, or held/worn by an
	// entity), drop an emissive voxel at its position so the floodfill colours the surroundings.
	#if COLORED_LIGHTING_ENABLED == 1
		vec3 clDynPos = transform(gbufferModelViewInverse, viewPos);
		// (a) DROPPED BLOCK items render as block models -> try the block materialId (mc_Entity), like
		// terrain, so froglight/glowstone reuse their real emission colour automatically.
		uint clEnc = uint(mc_Entity.x + 0.5);
		clEnc *= uint((clEnc & (1u << 14u)) > 0u && clEnc != 65535u);
		voxelizeDynamicBlock(clDynPos, clEnc & ((1u << 10u) - 1u));
		// (b) held / sprite items -> item id.
		voxelizeDynamicLight(clDynPos, dynamicLightItemVoxelId(currentRenderedItemId));
		// (c) light-emitting MOBS themselves (glow squid, magma cube) -> entity id.
		voxelizeDynamicLight(clDynPos, dynamicLightEntityVoxelId(entityId));
	#endif


	gl_Position = viewToNdc(viewPos);
	
	
	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
	
	
	doVshLighting(lmcoord, viewPos, normal);
	
}

#endif
