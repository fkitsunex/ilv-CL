in_out vec2 lmcoord;
flat in_out vec4 glcolor;
flat in_out vec2 encodedNormal;



#ifdef FSH

void main() {
	vec4 color = glcolor;
	if (color.a < 0.01) discard;

	// In-world overlay BACKGROUNDS — vanilla entity nametags, MobPlaques (mob HP), WATUT activity
	// bubbles, pingnametags, etc. all draw their backing plate as a near-black translucent quad
	// (vanilla RenderType.textBackground, alpha ~0.25). These were written to the world gbuffer, so
	// looking THROUGH them broke the shading/shadows behind, and they reflected in water. Discard
	// them so they never touch the deferred world (the overlay's text/icons are drawn on top in a
	// later pass and stay visible). The block selection outline is also a dark quad here but has its
	// own render stage (MC_RENDER_STAGE_OUTLINE), so it's preserved.
	// (nametag bg alpha ~0.25; the block outline is ~0.4, so the a<0.35 cap also protects it)
	if (renderStage != MC_RENDER_STAGE_OUTLINE && color.a < 0.35 && dot(color.rgb, color.rgb) < 0.0025) discard;

	/* DRAWBUFFERS:02 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(0.0, 0.0, 0.0, 1.0);
	#endif
	color.rgb *= 0.5;
	gl_FragData[0] = vec4(color);
	gl_FragData[1] = vec4(
		pack_2x8(lmcoord),
		pack_2x8(0.0, 0.3),
		encodedNormal
	);
}

#endif



#ifdef VSH

#include "/utils/projections.glsl"

#if TAA_ENABLED == 1
	#include "/lib/taa_jitter.glsl"
#endif

void main() {
	lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	adjustLmcoord(lmcoord);
	glcolor = gl_Color;
	encodedNormal = encodeNormal(gbufferModelView[1].xyz);
	
	gl_Position = viewToNdc(transform(gl_ModelViewMatrix, gl_Vertex.xyz));
	
	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
	
}

#endif
