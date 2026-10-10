in_out vec2 texcoord;
in_out vec4 glcolor;
flat in_out float darkGlintBoost;



#ifdef FSH

void main() {
	
	vec4 color = texture2D(MAIN_TEXTURE, texcoord) * glcolor;
	color.rgb *= ENCHANTMENT_GLINT_STRENGTH;
	// The glint is ADDED to whatever is in the colour buffer. Before deferred that's albedo (later multiplied by
	// the lighting, hence the boost in the dark); after deferred (e.g. items rendered as part of the player model
	// by mods like Better Combat's extended grip, drawn in the separate translucent-entity pass) it's the lit
	// colour stored *0.5 — so there the glint gets the 0.5 encoding and no dark boost, or it came out ~3x too
	// strong and washed the item into flat lavender (especially in the skylight-less End).
	float isAfterDeferred = texelFetch(colortex10, ivec2(0), 0).r;
	color.rgb *= isAfterDeferred > 0.5 ? 0.5 : darkGlintBoost;
	
	/* DRAWBUFFERS:0 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(1.0, 0.0, 0.5, 1.0);
	#endif
	//color.rgb *= 0.5;
	gl_FragData[0] = vec4(color);
	
}

#endif



#ifdef VSH

#define PROJECTION_MATRIX gl_ProjectionMatrix
#include "/utils/projections.glsl"

#if TAA_ENABLED == 1
	#include "/lib/taa_jitter.glsl"
#endif

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	glcolor = gl_Color;
	
	vec2 brightnesses = eyeBrightnessSmooth / 240.0;
	darkGlintBoost = 1.5 - 0.5 * max(brightnesses.x, brightnesses.y);
	glcolor.rgb -= vec3(0.05, 0.0, 0.0) * glcolor.rgb; // (slight warm cut, was folded into the boost)
	
	
	gl_Position = viewToNdc(transform(gl_ModelViewMatrix, gl_Vertex.xyz));
	
	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
	
	
}

#endif
