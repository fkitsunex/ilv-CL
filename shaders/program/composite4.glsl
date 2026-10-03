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
		if (reflectiveness > 0.01) {
			#ifdef DISTANT_HORIZONS
				doReflections(color, depth0, dhDepth0, normal, viewPos, lmcoord, reflectiveness);
			#else
				doReflections(color, depth0, 0.0, normal, viewPos, lmcoord, reflectiveness);
			#endif
		}
		
	#endif
	
	
	
	#if COLORED_LIGHTING_ENABLED == 1
		// [enchant outline] first-person outline texels stashed by gbuffers_hand (they write no depth), blended
		// over the FINAL scene here — after water, stained glass, translucent items/entities, reflections and
		// fog — so translucents behind the outline show through it correctly. Skipped where something is in
		// front of the outline (the item body, a translucent held item).
		uint outlineDepthCode = texelFetch(clOutlineDepthSampler, ivec2(gl_FragCoord.xy), 0).r;
		if (outlineDepthCode > 0u) {
			float outlineZ = 1.0 - float(outlineDepthCode - 1u) / 1073741823.0; // nearest outline fragment
			if (texelFetch(DEPTH_BUFFER_ALL, ivec2(gl_FragCoord.xy), 0).r >= outlineZ - 0.000001) {
				vec3 outlineRgb = texelFetch(clOutlineSampler, ivec2(gl_FragCoord.xy), 0).rgb;
				color = mix(color, outlineRgb * ENCHANT_OUTLINE_BRIGHTNESS, ENCHANT_OUTLINE_OPACITY);
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
