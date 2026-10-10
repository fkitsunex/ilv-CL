// [emissive entities] Iris routes the "emissive" entity render types here: spider / enderman eyes and
// entityTranslucentEmissive (e.g. the beams of Create Gadgets & Gizmos thrusters). They used to fall back to
// gbuffers_textured with blending forced OFF, so translucent beams came out as opaque black columns.
// Blending now follows each render type (additive eyes, alpha-blended beams; colortex2 = off).
//  - drawn after deferred (separateEntityDraws): composited straight onto the lit scene at full brightness,
//    so beams blend correctly over the sky, water and Distant Horizons terrain
//  - drawn before deferred: written to the gbuffers with the 254/255 "glowing" flag (lit as emissive)

in_out vec2 texcoord;
in_out vec4 glcolor;
flat in_out vec2 encodedNormal;



#ifdef FSH

void main() {
	vec4 color = texture2D(MAIN_TEXTURE, texcoord) * glcolor;
	if (color.a < 0.004) discard;

	float isAfterDeferred = texelFetch(colortex10, ivec2(0), 0).r;

	/* DRAWBUFFERS:02 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(1.0, 0.0, 1.0, 1.0);
	#endif
	if (isAfterDeferred > 0.5) {
		// emissive: shown as-is (the colour buffer holds lit colour * 0.5 at this point)
		gl_FragData[0] = vec4(color.rgb * 0.5, color.a);
		gl_FragData[1] = vec4(pack_2x8(vec2(1.0)), pack_2x8(0.0, 253.0 / 255.0), encodedNormal); // no reflections
	} else {
		gl_FragData[0] = vec4(color.rgb * 0.5, color.a);
		// 254/255 = glowing flag; reflectiveness 0.5 -> glowingAmount 1.0 in deferred1
		gl_FragData[1] = vec4(pack_2x8(vec2(1.0)), pack_2x8(0.5, 254.0 / 255.0), encodedNormal);
	}

}

#endif



#ifdef VSH

#include "/utils/projections.glsl"

#if TAA_ENABLED == 1
	#include "/lib/taa_jitter.glsl"
#endif

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	glcolor = gl_Color;
	encodedNormal = encodeNormal(gl_NormalMatrix * gl_Normal);

	vec3 viewPos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);
	gl_Position = viewToNdc(viewPos);

	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
}

#endif
