// 3D parallax block-breaking. Iris replaces the resource pack's rendertype_crumbling CORE shader
// with this program, so the pack's 3D-breaking effect cannot run on its own — its logic is ported
// here instead. This is the pack's own robust rewrite (screen-space-derivative tangent frame +
// grazing-angle/offset clamps), so it renders the pack's destroy_stage textures in 3D with the shader.
// Only regular blocks reach this program; block-entity (chest) crumbling goes through hand_water.
// Pairs with: blend.gbuffers_damagedblock.colortex0 = DST_COLOR ZERO (multiplicative darkening).

#define POM_DEPTH 0.5      // groove depth, in texels (1/16 of a block)
#define MIN_NDOTV 0.15     // clamp grazing angles so the parallax can never explode
#define MAX_OFFS  0.5      // hard safety clamp on the parallax offset (in UV)

in_out vec2 texcoord;
in_out vec3 pos;           // camera-relative world position (matches the pack's `Pos`)



#ifdef FSH

void main() {
	// NOTE: no `* glcolor` here. The DST_COLOR/ZERO blend already multiplies the crack by the block's
	// (already-lit, already-AO'd) colour, so multiplying by the vertex colour too double-darkened the
	// cracks on shaded faces (grass sides went near-black). One shading pass = consistent on all faces.
	vec4 color = texture2D(MAIN_TEXTURE, texcoord);
	if (color.a < 0.1) discard; // only the crack texels contribute

#if BLOCK_BREAKING_3D == 1
	vec2 texSize = vec2(textureSize(MAIN_TEXTURE, 0));

	// Robust tangent frame reconstructed from screen-space derivatives — UV-aligned, correct on any
	// face orientation, no eye/world-space mixing (that was what caused the old flat-black smear).
	vec3 dPx = dFdx(pos);
	vec3 dPy = dFdy(pos);
	vec2 dUx = dFdx(texcoord);
	vec2 dUy = dFdy(texcoord);

	vec3 N = normalize(cross(dPx, dPy)); // geometric face normal (world space)
	vec3 V = normalize(pos);             // camera -> fragment direction
	if (dot(N, V) > 0.0) N = -N;         // orient toward the camera

	float det = dUx.x * dUy.y - dUy.x * dUx.y;
	if (abs(det) > 1e-9) {
		// Solve dPos = T*dU + B*dV for the UV-aligned tangent/bitangent.
		vec3 T = (dUy.y * dPx - dUx.y * dPy) / det;
		vec3 B = (dUx.x * dPy - dUy.x * dPx) / det;
		T = normalize(T - N * dot(N, T));
		B = normalize(B - N * dot(N, B));

		// View direction in tangent space; V points into the surface so its normal component is
		// negative — clamp its magnitude away from zero at grazing angles.
		vec3 Vt = vec3(dot(V, T), dot(V, B), dot(V, N));
		float ndotv = max(-Vt.z, MIN_NDOTV);

		vec2 offs = Vt.xy / ndotv / texSize.x * POM_DEPTH;
		offs = clamp(offs, vec2(-MAX_OFFS), vec2(MAX_OFFS));

		// Raymarch into the groove.
		float i;
		vec4 rayCol;
		for (i = 1.0; i <= 16.0; i++) {
			rayCol = texture2D(MAIN_TEXTURE, texcoord + offs / 16.0 * i);
			if (rayCol.a < 0.1) {
				color = vec4(0.2, 0.2, 0.2, 1.0); // shaded side wall
				break;
			}
		}
		if (i > 16.0) color = texture2D(MAIN_TEXTURE, texcoord + offs) * 2.0; // lit groove floor
	}
	// Degenerate det → keep the flat 2D crack above instead of a black smear.
#endif
	// BLOCK_BREAKING_3D == 0: `color` stays the flat crack texture → plain vanilla / resource-pack
	// crumbling with no parallax (use this when you don't have a 3D-breaking texture pack enabled).

	// Contrast: output is a multiplier (DST_COLOR/ZERO), so mixing toward white = lighter cracks.
	// 1.0 leaves the effect exactly as the pack renders it.
	color.rgb = mix(vec3(1.0), color.rgb, BLOCK_BREAKING_CONTRAST);

	/* DRAWBUFFERS:0 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(0.5, 0.0, 0.0, 1.0);
	#endif
	// NOTE: no *0.5 here — output is a multiplier for DST_COLOR/ZERO blending.
	gl_FragData[0] = vec4(color.rgb, 1.0);
}

#endif



#ifdef VSH

#include "/utils/projections.glsl"

#if TAA_ENABLED == 1
	#include "/lib/taa_jitter.glsl"
#endif

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;

	vec3 viewPos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);
	pos = mat3(gbufferModelViewInverse) * viewPos; // camera-relative world position

	gl_Position = viewToNdc(viewPos);

	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
}

#endif
