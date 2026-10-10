in_out vec2 texcoord;



#ifdef FSH

#if DOF_ENABLED == 1
	#include "/lib/depth_of_field.glsl"
#endif
#if REFLECTIONS_ENABLED == 1
	#include "/utils/depth.glsl"
	#include "/utils/projections.glsl"
	#include "/utils/getSkyColor.glsl"
	#include "/lib/reflections.glsl"
#endif
#if BORDER_FOG_ENABLED == 1
	#include "/utils/borderFogAmount.glsl"
#endif
#if COLORED_LIGHTING_ENABLED == 1
	uniform sampler2D clOutlineSampler; // [enchant outline] see gbuffers_hand
	uniform usampler2D clOutlineDepthSampler;
	uniform sampler2D clTransColorSampler; // [translucent overlay] see lib/translucent_overlay.glsl
	uniform usampler2D clTransDepthSampler;
	uniform usampler2D clTransAlphaSampler;
#endif



#if REFLECTIONS_ENABLED == 1
	void doReflections(inout vec3 color, float depth, float dhDepth, vec3 normal, vec3 viewPos, vec2 lmcoord, float reflectionStrength) {
		
		if (depthIsHand(depth)) return;
		#ifdef DISTANT_HORIZONS
			if (depth == 1.0 && dhDepth == 1.0) return;
		#else
			if (depth == 1.0) return;
		#endif
		
		#ifdef DISTANT_HORIZONS
			if (depth == 1.0) viewPos = screenToViewDh(vec3(texcoord, dhDepth));
		#endif
		
		addReflection(color, viewPos, normal, lmcoord, MAIN_TEXTURE, reflectionStrength);
		
	}
#endif

void main() {
	vec3 color = texelFetch(MAIN_TEXTURE, texelcoord, 0).rgb * 2.0;
	
	
	
	// ======== DEPTH OF FIELD ======== //
	
	#if DOF_ENABLED == 1
		doDOF(color);
	#endif
	
	
	
	// ======== REFLECTIONS ======== //
	
	#if REFLECTIONS_ENABLED == 1
		
		vec4 data;
		float depth0 = texelFetch(DEPTH_BUFFER_ALL, texelcoord, 0).r;
		float depth1 = texelFetch(DEPTH_BUFFER_WO_TRANS, texelcoord, 0).r;
		bool useTransparentData = depth0 < depth1; // if transparents depth is less than non-transparents depth then use transparents data tex
		#ifdef DISTANT_HORIZONS
			float dhDepth0 = texelFetch(DH_DEPTH_BUFFER_ALL, texelcoord, 0).r;
			float dhDepth1 = texelFetch(DH_DEPTH_BUFFER_WO_TRANS, texelcoord, 0).r;
			useTransparentData = useTransparentData || dhDepth0 < dhDepth1;
		#endif
		vec3 screenPos = vec3(texcoord, depth0);
		vec3 viewPos = screenToView(screenPos);
		#ifdef VOXY
			float vxDepth0 = texelFetch(VX_DEPTH_BUFFER_TRANS, texelcoord, 0).r;
			float vxDepth1 = texelFetch(VX_DEPTH_BUFFER_OPAQUE, texelcoord, 0).r;
			vec3 viewPosVx = screenToViewVx(vec3(texcoord, vxDepth0));
			useTransparentData = useTransparentData || (vxDepth0 < vxDepth1 && viewPosVx.z > viewPos.z - 0.5);
		#endif
		if (useTransparentData) {
			data = texelFetch(TRANSPARENT_DATA_TEXTURE, texelcoord, 0);
		} else {
			data = texelFetch(OPAQUE_DATA_TEXTURE, texelcoord, 0);
		}
		vec3 normal = decodeNormal(data.zw);
		#ifndef MODERN_BACKEND
			vec3 xDir = normalize(dFdx(viewPos));
			vec3 yDir = normalize(dFdy(viewPos));
			normal = cross(xDir, yDir);
		#endif
		vec2 lmcoord = unpack_2x8(data.x);
		
		#if REFLECTIVE_EVERYTHING == 1
			float reflectiveness = 1.0;
		#else
			vec2 refPlusSpec = unpack_2x8(data.y);
			float reflectiveness = refPlusSpec.x;
			float specularness = refPlusSpec.y;
			if (abs(specularness - 254.0 / 255.0) < 0.001) {
				reflectiveness = 0.0;
				specularness = 0.0;
			}
			// 253/255 = "no-reflect overlay" flag (crumbling on block entities via hand_water, particles,
			// nametags, mod UI): such a pixel must never run reflections itself, whichever data buffer
			// the depth test picked. This is what kills the chest-breaking "mirror" at its root.
			if (abs(specularness - 253.0 / 255.0) < 0.002) {
				reflectiveness = 0.0;
			}
		#endif
		#if REALISTIC_CLOUDS_ENABLED == 1 || NETHER_CLOUDS_ENABLED == 1 || END_CLOUDS_ENABLED == 1
			float invCloudsThickness = unpack_2x8(texelFetch(NOISY_RENDERS_TEXTURE, texelcoord, 0).g).x;
			reflectiveness *= sqrt(invCloudsThickness);
		#endif
		#if BORDER_FOG_ENABLED == 1
			// Only the NEAR terrain's border fog should cut reflections. For DH pixels (depth0 == 1.0) the
			// viewPos here is the near FAR-PLANE, so getBorderFogAmount reads ~1 and kills DH-water
			// reflections entirely (why DH water reflected nothing). DH has its own distance fade, so skip
			// the reduction for those pixels.
			#ifdef DISTANT_HORIZONS
				bool clNearGeo = depth0 != 1.0;
			#else
				const bool clNearGeo = true;
			#endif
			if (clNearGeo) {
				vec3 playerPos = mat3(gbufferModelViewInverse) * viewPos;
				float _fogDistance;
				float fogAmount = getBorderFogAmount(playerPos, _fogDistance);
				reflectiveness *= 1.0 - fogAmount;
			}
		#endif
		#if COLORED_LIGHTING_ENABLED == 1
			// no reflections over a visible enchant outline (its pixel carries the BACKGROUND's gbuffer data)
			uint reflOutlineCode = texelFetch(clOutlineDepthSampler, texelcoord, 0).r;
			if (reflOutlineCode > 0u && depth0 >= 1.0 - float(reflOutlineCode - 1u) / 1073741823.0 - 0.000001) reflectiveness = 0.0;
		#endif
		if (reflectiveness > 0.01) {
			#ifdef DISTANT_HORIZONS
				doReflections(color, depth0, dhDepth0, normal, viewPos, lmcoord, reflectiveness);
			#else
				doReflections(color, depth0, 0.0, normal, viewPos, lmcoord, reflectiveness);
			#endif
		}
		
	#endif
	
	
	
	#if COLORED_LIGHTING_ENABLED == 1
		// [translucent overlay] translucent block-entity geometry drawn before deferred (mod beams), lit and
		// stashed by gbuffers_block: blend it over the finished scene where nothing opaque is in front of it
		uint transDepthCode = texelFetch(clTransDepthSampler, ivec2(gl_FragCoord.xy), 0).r;
		if (transDepthCode > 0u) {
			float transZ = 1.0 - float(transDepthCode - 1u) / 1073741823.0;
			if (texelFetch(DEPTH_BUFFER_ALL, ivec2(gl_FragCoord.xy), 0).r >= transZ - 0.000001) {
				vec3 transColor = texelFetch(clTransColorSampler, ivec2(gl_FragCoord.xy), 0).rgb;
				float transAlpha = 1.0 - exp(-float(texelFetch(clTransAlphaSampler, ivec2(gl_FragCoord.xy), 0).r) / 1024.0);
				color = mix(color, transColor, transAlpha);
			}
		}
	#endif
	
	/* DRAWBUFFERS:0 */
	color *= 0.5;
	gl_FragData[0] = vec4(color, 1.0);
	
}

#endif



#ifdef VSH

void main() {
	gl_Position = ftransform();
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
}

#endif
