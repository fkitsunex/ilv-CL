#if SHADOWS_ON_TRANSPARENTS == 0
	#undef SHADOWS_TYPE
	#define SHADOWS_TYPE 0
#endif

in_out vec2 texcoord;
in_out vec2 lmcoord;
in_out vec3 glcolor;
in_out vec3 viewPos;
#if PBR_TYPE == 0
	flat in_out vec3 normal;
	flat in_out vec2 encodedNormal;
#elif PBR_TYPE == 1
	flat in_out mat3 tbn;
#endif



#ifdef FSH

#include "/lib/lighting/fsh_lighting.glsl"
#include "/lib/enchant_outlines.glsl"

void main() {
	
	vec4 color = texture2D(MAIN_TEXTURE, texcoord) * vec4(glcolor, 1.0);
	if (color.a == 0.0) discard;
	color.rgb = mix(vec3(getLum(color.rgb)), color.rgb, 1.05);
	
	
	// make yellow colors brighter
	float brightnessIncrease = dot(color.rgb, vec3(0.2, 0.7, 0.1));
	color.rgb *= 1.0 + 0.25 * brightnessIncrease;
	
	
	#if PBR_TYPE == 1
		vec3 normal = texture2D(normals, texcoord).rgb;
		normal.xy -= 0.5;
		normal.xy *= PBR_NORMALS_AMOUNT * 0.75;
		normal.xy += 0.5;
		normal = normalize(normal * 2.0 - 1.0);
		normal = tbn * normal;
		vec2 encodedNormal = encodeNormal(normal);
	#endif
	
	
	// [block-entity crumbling] Iris routes chest/sign breaking through THIS program, which alpha-blends
	// and lights its output — so the grey crack texture was painted ON TOP of the chest = white cracks.
	// Regular blocks' crumbling (gbuffers_damagedblock) instead MULTIPLIES the block (DST_COLOR ZERO).
	// Emulate that multiply under this pass's normal alpha blend: black with alpha = 1 - lum(multiplier)
	// gives dst * multiplier, exactly matching damagedblock (incl. BLOCK_BREAKING_CONTRAST). Held
	// translucent items render at hand depth, world crumbling doesn't — so they're left untouched.
	if (!depthIsHand(gl_FragCoord.z)) {
		vec4 crack = texture2D(MAIN_TEXTURE, texcoord);
		if (crack.a < 0.1) discard; // only the crack texels contribute (as in damagedblock)
		vec3 crackMul = mix(vec3(1.0), crack.rgb, BLOCK_BREAKING_CONTRAST);
		gl_FragData[0] = vec4(0.0, 0.0, 0.0, 1.0 - getLum(crackMul));
		gl_FragData[1] = vec4(pack_2x8(lmcoord), pack_2x8(0.0, 253.0 / 255.0), encodedNormal); // keep no-reflect flag
		return;
	}


	// enchanted item texels (Enchantment Outlines): unlit + purple hand light (see gbuffers_hand)
	if (isEnchantTexel(texcoord, true)) {
		#if COLORED_LIGHTING_ENABLED == 1
			stampEnchantHand();
		#endif
		if (isEnchantTexel(texcoord, false)) {
			fshFullbright = 1.0;
		} else {
			// outline (alpha 200): raw texture colour, unlit, at ENCHANT_OUTLINE_OPACITY (forward pass, so
			// blending happens after lighting here and needs no deferred1 trick)
			vec3 outlineRgb = texture2DLod(MAIN_TEXTURE, texcoord, 0.0).rgb * ENCHANT_OUTLINE_TINT * ENCHANT_OUTLINE_BRIGHTNESS;
			gl_FragData[0] = vec4(outlineRgb * 0.5, ENCHANT_OUTLINE_OPACITY);
			gl_FragData[1] = vec4(pack_2x8(lmcoord), pack_2x8(0.0, 253.0 / 255.0), encodedNormal);
			return;
		}
	}

	#if COLORED_LIGHTING_ENABLED == 1
		clIsHand = 1.0; // colour light for the hand is sampled at the camera
	#endif
	float _inSunlightAmount;
	doFshLighting(color.rgb, _inSunlightAmount, lmcoord.x, lmcoord.y, 0.0, 0.0, viewPos, normal, gl_FragCoord.z);
	
	
	/* DRAWBUFFERS:03 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(1.0, 0.5, 0.5, 1.0);
	#endif
	color.rgb *= 0.5;
	gl_FragData[0] = vec4(color);
	gl_FragData[1] = vec4(
		pack_2x8(lmcoord),
		// 253/255 no-reflect flag: block-entity crumbling (chest breaking) renders through this
		// program; the flag makes composite4 skip reflections on these pixels entirely (the "mirror").
		// Needs blend.gbuffers_hand_water.colortex3 = off so the flag overwrites instead of alpha-blending.
		pack_2x8(0.0, 253.0 / 255.0),
		encodedNormal
	);
	
}

#endif



#ifdef VSH

#define PROJECTION_MATRIX gl_ProjectionMatrix
#include "/utils/projections.glsl"
#include "/lib/lighting/vsh_lighting.glsl"

#if TAA_ENABLED == 1
	#include "/lib/taa_jitter.glsl"
#endif

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	adjustLmcoord(lmcoord);
	glcolor = gl_Color.rgb;
	
	#if PBR_TYPE != 0
		vec3 normal;
	#endif
	normal = gl_NormalMatrix * gl_Normal;
	#if PBR_TYPE == 0
		encodedNormal = encodeNormal(normal);
	#endif
	#if PBR_TYPE == 1
		vec3 tangent = normalize(gl_NormalMatrix * at_tangent.xyz);
		vec3 bitangent = normalize(cross(normal, tangent) * at_tangent.w);
		tbn = mat3(tangent, bitangent, normal);
	#endif
	
	
	gl_Position = viewToNdc(transform(gl_ModelViewMatrix, gl_Vertex.xyz));
	#if PROJECTION_TYPE == 1
		//gl_Position.xy *= 1.5;
	#endif
	
	
	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
	
	
	vec3 screenPos = vec3((gl_Position.xy / gl_Position.w) * 0.5 + 0.5, HAND_DEPTH);
	viewPos = screenToView(screenPos);
	doVshLighting(lmcoord, viewPos, normal);
	
}

#endif
