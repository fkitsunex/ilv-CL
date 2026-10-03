in_out vec2 texcoord;
in_out vec2 lmcoord;
in_out vec4 glcolor;
#if PBR_TYPE == 0
	flat in_out vec3 normal;
	flat in_out vec2 encodedNormal;
#elif PBR_TYPE == 1
	flat in_out mat3 tbn;
#endif
in_out float blockDepth;

in_out vec3 viewPos;



#ifdef FSH

#include "/lib/lighting/simple_fsh_lighting.glsl"

void main() {
	vec4 rawColor = texture2D(MAIN_TEXTURE, texcoord);
	vec4 color = rawColor * glcolor;

	// "Hide nearby / fade colored particles" should only soften SOFT particles (smoke, etc.). Solid
	// particles like block-breaking fragments use a fully-opaque block texel (alpha 1) — keep them
	// opaque, otherwise they look see-through against DH terrain / water (the alpha<1 blends the
	// background through them). softParticle = 1 for soft particles, 0 for solid fragments.
	float softParticle = 1.0 - step(0.99, rawColor.a);

	// hide nearby particles
	float transparency = percentThrough(blockDepth, 0.5, 1.2);
	color.a *= mix(1.0, (transparency - 1.0) * NEARBY_PARTICLE_TRANSPARENCY + 1.0, softParticle);
	color.a *= 1.0 - COLORED_PARTICLE_TRANSPARENCY * getSaturation(glcolor.rgb) * softParticle;
	
	
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
	
	
	float isAfterDeferred = texelFetch(colortex10, ivec2(0), 0).r;
	if (isAfterDeferred > 0.5) {
		#if COLORED_LIGHTING_ENABLED == 1
			clSoftSample = 1.0; // soft colour edges for particles (see applyColoredLight)
		#endif
		simpleParticleSun = 1.0; // undirected sun/moon light like the surfaces around (see simple_fsh_lighting)
		float particleBlock = lmcoord.x;
		#if COLORED_LIGHTING_ENABLED == 1
			particleBlock = clParticleBlockLight(viewPos, normal, particleBlock); // no in-wall blackout
		#endif
		doSimpleFshLighting(color.rgb, particleBlock, lmcoord.y, specularness, viewPos, normal);
	}
	
	
	/* DRAWBUFFERS:02 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(0.5, 0.75, 0.75, 1.0);
	#endif
	color.rgb *= 0.5;
	gl_FragData[0] = vec4(color);
	gl_FragData[1] = vec4(
		pack_2x8(lmcoord),
		pack_2x8(reflectiveness, 253.0 / 255.0), // 253/255 = "no-reflect" flag → kept out of water reflections
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

void main() {
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	adjustLmcoord(lmcoord);
	lmcoord = min(lmcoord + 0.05, 1.0);
	glcolor = gl_Color;
	glcolor.rgb *= 1.25;
	glcolor.a = sqrt(glcolor.a);
	
	#if PBR_TYPE != 0
		vec3 normal;
	#endif
	normal = gl_NormalMatrix * gl_Normal;
	#if PBR_TYPE == 0
		encodedNormal = encodeNormal(normal);
	#elif PBR_TYPE == 1
		vec3 tangent = normalize(gl_NormalMatrix * at_tangent.xyz);
		vec3 bitangent = normalize(cross(normal, tangent) * at_tangent.w);
		tbn = mat3(tangent, bitangent, normal);
	#endif
	
	viewPos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);
	blockDepth = length(viewPos);
	
	
	gl_Position = viewToNdc(viewPos);
	
	
	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
	
	
	doVshLighting(lmcoord, viewPos, normal);
	
}

#endif
