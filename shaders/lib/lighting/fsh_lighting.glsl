#if COLORED_LIGHTING_ENABLED == 1
	#include "/lib/colored_lighting/applyColoredLight.glsl"
#endif



vec3 getShadowPos(vec3 playerPos, vec3 normal) {
	vec3 shadowPos = transform(shadowProjection, transform(shadowModelView, playerPos));
	float distortFactor = getDistortFactor(shadowPos);
	shadowPos = distort(shadowPos, distortFactor);
	shadowPos = shadowPos * 0.5 + 0.5;
	return shadowPos;
}



#if SHADOWS_TYPE == 2

#if SHADOW_FILTERING == 0 && PIXELATED_SHADOWS == 0
	#define samplePosType ivec2
	#define rawSample(sampler, pos) texelFetch(sampler, pos, 0)
#else
	#define samplePosType vec2
	#define rawSample(sampler, pos) texture2D(sampler, pos)
#endif

vec3 sampleShadowAtPoint(samplePosType shadowmapPos, vec3 playerPos, float depth) {
	#if COLORED_SHADOWS_ENABLED == 0
		
		bool isLit = rawSample(shadowtex0, shadowmapPos).r >= depth;
		return vec3(float(isLit));
		
	#elif COLORED_SHADOWS_ENABLED == 1
		
		if (rawSample(shadowtex0, shadowmapPos).r >= depth) return vec3(1.0);
		if (rawSample(shadowtex1, shadowmapPos).r < depth) return vec3(0.0);
		vec4 shadowColor = texelFetch(shadowcolor0, ivec2(shadowmapPos * (shadowMapResolution - 1) + 0.5), 0);
		
		#if WATER_CAUSTICS_ENABLED == 1
			ivec3 shadowColorInt = ivec3(shadowColor.rgb * 255.0 + 0.5);
			if (shadowColorInt == ivec3(1, 2, 255)) shadowColor.rgb = (WATER_CAUSTICS_DARK_COLOR + 0.25) / 0.75;
			if (shadowColorInt == ivec3(1, 3, 255)) shadowColor.rgb = (WATER_CAUSTICS_BRIGHT_COLOR + 0.25) / 0.75;
		#endif
		
		shadowColor.rgb = 0.25 + 0.75 * shadowColor.rgb;
		return shadowColor.rgb * step(-0.99, -shadowColor.a);
		
	#endif
}



vec3 sampleShadow(vec3 viewPos, float lightDot, vec3 normal) {
	if (lightDot < 0.0) return vec3(0.0); // surface is facing away from shadowLightPosition
	float lViewPos = length(viewPos);
	
	#if PIXELATED_SHADOWS > 0
		// no filtering, world-aligned pixelated
		
		viewPos += normal * 0.0025 * (40.0 + lViewPos);
		
		vec3 tangent = cross(normal, gbufferModelView[1].xyz);
		if (abs(tangent.x) + abs(tangent.y) + abs(tangent.z) < 0.01) {
			tangent = cross(normal, gbufferModelView[0].xyz);
		}
		tangent = normalize(tangent);
		vec3 bitangent = cross(tangent, normal);
		
		vec3 playerPos = transform(gbufferModelViewInverse, viewPos);
		playerPos += cameraPosition;
		playerPos = floor(playerPos * PIXELATED_SHADOWS) / PIXELATED_SHADOWS;
		playerPos -= cameraPosition;
		
		vec3 shadowPos = getShadowPos(playerPos, normal);
		if (shadowPos.z > 1.0) return vec3(1.0);
		vec3 shadowPosStepX = normalize(mat3(shadowProjection) * mat3(shadowModelView) * mat3(gbufferModelViewInverse) * tangent);
		vec3 shadowPosStepY = normalize(mat3(shadowProjection) * mat3(shadowModelView) * mat3(gbufferModelViewInverse) * bitangent);
		float stepMult = length(shadowPos.xy - 0.5);
		stepMult = 1.0 - (1.0 - stepMult) * (1.0 - stepMult) * (1.0 - PIXELATED_SHADOWS_SOFTNESS);
		stepMult = stepMult * 0.0007;
		shadowPosStepX *= stepMult;
		shadowPosStepY *= stepMult;
		
		vec3 shadowSample = vec3(0.0);
		float bias = 0.0002 + lViewPos * 0.035 / shadowMapResolution;
		shadowSample += sampleShadowAtPoint(shadowPos.xy + shadowPosStepX.xy + shadowPosStepY.xy, playerPos, shadowPos.z - bias);
		shadowSample += sampleShadowAtPoint(shadowPos.xy + shadowPosStepX.xy - shadowPosStepY.xy, playerPos, shadowPos.z - bias);
		shadowSample += sampleShadowAtPoint(shadowPos.xy - shadowPosStepX.xy + shadowPosStepY.xy, playerPos, shadowPos.z - bias);
		shadowSample += sampleShadowAtPoint(shadowPos.xy - shadowPosStepX.xy - shadowPosStepY.xy, playerPos, shadowPos.z - bias);
		return shadowSample * 0.25;
		
	#elif SHADOW_FILTERING == 0
		
		// no filtering, pixelated edges
		viewPos += normal * 0.001 * (25.0 + lViewPos);
		vec3 playerPos = transform(gbufferModelViewInverse, viewPos);
		vec3 shadowPos = getShadowPos(playerPos, normal);
		if (shadowPos.z > 1.0) return vec3(1.0);
		return sampleShadowAtPoint(ivec2(shadowPos.xy * shadowMapResolution - 0.25), playerPos, shadowPos.z);
		
	#elif SHADOW_FILTERING == 1
		
		// no filtering, smooth edges
		viewPos += normal * 0.001 * (25.0 + lViewPos);
		vec3 playerPos = transform(gbufferModelViewInverse, viewPos);
		vec3 shadowPos = getShadowPos(playerPos, normal);
		if (shadowPos.z > 1.0) return vec3(1.0);
		return sampleShadowAtPoint(shadowPos.xy, playerPos, shadowPos.z);
		
	#else
		
		
		
		// strange filtering
		
		#if SHADOW_FILTERING == 2
			const int SHADOW_OFFSET_COUNT = 5;
			const float SHADOW_OFFSET_WEIGHTS_TOTAL = 3.584;
			const vec3[SHADOW_OFFSET_COUNT] SHADOW_OFFSETS = vec3[SHADOW_OFFSET_COUNT] (
				vec3(-0.200,  0.013, 0.967),
				vec3(-0.124, -0.380, 0.873),
				vec3(-0.383,  0.462, 0.736),
				vec3( 0.747, -0.285, 0.580),
				vec3( 0.613,  0.790, 0.427)
			);
		#elif SHADOW_FILTERING == 3
			const int SHADOW_OFFSET_COUNT = 10;
			const float SHADOW_OFFSET_WEIGHTS_TOTAL = 7.472;
			const vec3[SHADOW_OFFSET_COUNT] SHADOW_OFFSETS = vec3[SHADOW_OFFSET_COUNT] (
				vec3(-0.069,  0.072, 0.992),
				vec3( 0.161, -0.119, 0.967),
				vec3( 0.212,  0.212, 0.926),
				vec3(-0.261, -0.303, 0.873),
				vec3(-0.497, -0.058, 0.809),
				vec3( 0.027, -0.599, 0.736),
				vec3(-0.460,  0.528, 0.659),
				vec3( 0.702, -0.384, 0.580),
				vec3( 0.215,  0.874, 0.502),
				vec3( 0.917,  0.400, 0.427)
			);
		#elif SHADOW_FILTERING == 4
			const int SHADOW_OFFSET_COUNT = 20;
			const float SHADOW_OFFSET_WEIGHTS_TOTAL = 15.239;
			const vec3[SHADOW_OFFSET_COUNT] SHADOW_OFFSETS = vec3[SHADOW_OFFSET_COUNT] (
				vec3(-0.029,  0.040, 0.998),
				vec3( 0.094, -0.034, 0.992),
				vec3(-0.100, -0.112, 0.981),
				vec3( 0.101,  0.173, 0.967),
				vec3(-0.248,  0.033, 0.948),
				vec3( 0.028, -0.299, 0.926),
				vec3(-0.189,  0.295, 0.901),
				vec3( 0.353, -0.188, 0.873),
				vec3( 0.417,  0.170, 0.842),
				vec3( 0.159,  0.474, 0.809),
				vec3(-0.439, -0.331, 0.773),
				vec3(-0.593, -0.091, 0.736),
				vec3(-0.264, -0.594, 0.698),
				vec3( 0.169, -0.679, 0.659),
				vec3(-0.672,  0.333, 0.620),
				vec3(-0.315,  0.736, 0.580),
				vec3( 0.668, -0.526, 0.541),
				vec3( 0.900,  0.010, 0.502),
				vec3( 0.729,  0.609, 0.464),
				vec3( 0.233,  0.972, 0.427)
			);
		#endif
		
		viewPos += normal * 0.001 * (25.0 + lViewPos);
		vec3 playerPos = transform(gbufferModelViewInverse, viewPos);
		vec3 shadowPos = getShadowPos(playerPos, normal);
		if (shadowPos.z > 1.0) return vec3(1.0);
		
		float dither = bayer64(gl_FragCoord.xy);
		dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
		float randomAngle = dither * 2.0 * PI;
		float noiseMult = SHADOWS_NOISE / shadowMapResolution * 3.0 * (1.0 + 2.0 * length(shadowPos.xy - 0.5));
		mat2 rotationMatrix;
		rotationMatrix[1] = vec2(sin(randomAngle), cos(randomAngle)) * noiseMult;
		rotationMatrix[0] = vec2(-rotationMatrix[1].y, rotationMatrix[1].x);
		
		vec3 shadowSample = vec3(0.0);
		for (int i = 0; i < SHADOW_OFFSET_COUNT; i++) {
			vec2 samplePos = shadowPos.xy + rotationMatrix * SHADOW_OFFSETS[i].xy;
			shadowSample += sampleShadowAtPoint(samplePos, playerPos, shadowPos.z) * SHADOW_OFFSETS[i].z;
		}
		shadowSample /= SHADOW_OFFSET_WEIGHTS_TOTAL;
		float mult = min(getLum(shadowSample) * 2.5, 1.0);
		shadowSample = shadowSample / getLum(shadowSample + 0.1) * mult * mult;
		return shadowSample;
		
	#endif
}

#endif





// [enchant fullbright] set to 1 by a program before doFshLighting (or by deferred1 from the 252/255 flag)
float fshFullbright = 0.0;
// brightness the fullbright texels are held at (enchanted items: their slider; entity fire: 1.0 = vanilla)
float fshFullbrightLevel = ENCHANTED_ITEM_BRIGHTNESS;
// set by deferred1 for particles/overlays (253 flag): skip the dynamic-light split — emissive particles
// (flames, lava, portal sparks) always carry the max lightmap, which the split read as foreign light
float fshNoDynSplit = 0.0;
// set by deferred1 for particles: they're camera-facing billboards, so the sun term used their facing
// (dark when the sun is behind you, e.g. at dusk) — light them like an up-facing surface instead, as
// vanilla lights particles without direction, so they match the ground around them
float fshUpNormalSun = 0.0;

void doFshLighting(inout vec3 color, out float inSunlightAmount, float blockBrightness, float ambientBrightness, float specularness, float glowingAmount, vec3 viewPos, vec3 normal, float depth) {
	float rawBlockBrightness = blockBrightness; // lightmap value before the curves (for the dyn-light split)
	
	#if AMBIENT_CEL_AMOUNT != 0
		ambientBrightness = sqrt(ambientBrightness);
		ambientBrightness = mix(ambientBrightness, floor(ambientBrightness * 3.0 + 0.5) / 3.0, AMBIENT_CEL_AMOUNT / 100.0);
		ambientBrightness *= ambientBrightness;
	#endif
	#if BLOCKLIGHT_CEL_AMOUNT != 0
		blockBrightness = sqrt(blockBrightness);
		blockBrightness = mix(blockBrightness, floor(blockBrightness * 3.0 + 0.5) / 3.0, BLOCKLIGHT_CEL_AMOUNT / 100.0);
		blockBrightness *= blockBrightness;
	#endif
	
	#if defined OVERWORLD || defined END
		float lightDot = dot(normalize(shadowLightPosition), fshUpNormalSun > 0.5 ? gbufferModelView[1].xyz : normal);
		#if SHADOWS_TYPE == 2
			float lightDotLift = 0.3;
		#else
			float lightDotLift = 0.5;
		#endif
		// TODO: reintroduce 'SUNLIGHT_CEL_AMOUNT' here?
		lightDot = lightDotLift * 0.5 + (1.0 - lightDotLift * 0.5) * lightDot;
	#else
		float lightDot = 1.0;
	#endif
	
	// night saturation decrease
	#ifdef OVERWORLD
		float nightPercent = 1.0 - dayPercent;
		nightPercent *= ambientBrightness * (1.0 - blockBrightness);
		nightPercent *= nightPercent;
		nightPercent *= NIGHT_SATURATION_DECREASE;
		color = mix(vec3(getLum(color)), color, 1.0 - nightPercent * 0.1);
		color += nightPercent * 0.06;
	#endif
	
	//#ifdef END
	//	ambientBrightness = 1.0;
	//#endif
	
	vec2 prepareData10 = texelFetch(MISC_DATA_TEXTURE, ivec2(1, 0), 0).rg;
	vec2 prepareData01 = texelFetch(MISC_DATA_TEXTURE, ivec2(0, 1), 0).rg;
	vec2 prepareData11 = texelFetch(MISC_DATA_TEXTURE, ivec2(1, 1), 0).rg;
	vec3 shadowcasterLight = vec3(prepareData10, prepareData01.r) * 2.0;
	vec3 ambientLight = vec3(prepareData01.g, prepareData11) * 2.0;
	#ifdef OVERWORLD
		ambientLight = mix(CAVE_AMBIENT_COLOR * 0.6 * (1.0 + 0.4 * screenBrightness), ambientLight, ambientBrightness);
	#endif
	
	vec3 normalForSS = mat3(gbufferModelViewInverse) * normal;
	// +-1.0x: -0.4
	// +-1.0z: -0.0
	// +1.0y: +0.325
	// -1.0y: -0.65
	normalForSS.xz = abs(normalForSS.xz);
	normalForSS.y *= sign(normalForSS.y) * -0.25 + 0.75; // -1: *1, 1: *0.5
	float sideShading = dot(normalForSS, vec3(-0.4, 0.65, 0.0));
	float brightForSS = max(blockBrightness, ambientBrightness);
	sideShading *= mix(SIDE_SHADING_DARK, SIDE_SHADING_BRIGHT, brightForSS * brightForSS) * 0.8;
	
	#if BLOCK_BRIGHTNESS_CURVE == 2
		blockBrightness = pow2(blockBrightness);
	#elif BLOCK_BRIGHTNESS_CURVE == 3
		blockBrightness = pow3(blockBrightness);
	#elif BLOCK_BRIGHTNESS_CURVE == 4
		blockBrightness = pow4(blockBrightness);
	#elif BLOCK_BRIGHTNESS_CURVE == 5
		blockBrightness = pow5(blockBrightness);
	#endif
	
	#if SHADOWS_TYPE == 2
		// Perf: skip the (up to 20-tap) shadowmap filtering wherever the gates below provably zero the
		// result anyway — surfaces facing away from the light (sampleShadow returns black for those)
		// and fragments with no sky access (inSunlightAmount is multiplied by ambientBrightness², so
		// caves/interiors never see the sun). Bit-identical output, large savings underground.
		vec3 shadowColor = vec3(0.0);
		if (lightDot > 0.0 && ambientBrightness > 0.0 && sunLightBrightness + moonLightBrightness > 0.0)
			shadowColor = sampleShadow(viewPos, lightDot, normal);

		#ifdef DISTANT_HORIZONS
			// Fade shadows at vanilla render edge — synced with terrain dither curve.
			vec3 shadowPlayerPos = transform(gbufferModelViewInverse, viewPos);
			float dhEdgeDist = length(shadowPlayerPos) / far;
			float terrainPresence = exp(-3.0 * pow2(pow2(pow2(pow2(dhEdgeDist)))));
			shadowColor = mix(vec3(1.0), shadowColor, terrainPresence);
		#endif

		inSunlightAmount = getLum(shadowColor);
		#if PIXELATED_SHADOWS > 0
			inSunlightAmount *= float(!depthIsHand(depth));
		#endif
	#else
		vec3 shadowColor = vec3(1.0);
		inSunlightAmount = 1.0;
	#endif
	inSunlightAmount *= min((sunLightBrightness + moonLightBrightness) * 5.0, 1.0);
	inSunlightAmount *= clamp(lightDot, 0.0, 1.0);
	#if SHADOWS_TYPE == 1
		float dither = bayer64(gl_FragCoord.xy);
		dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
		inSunlightAmount *= step(1.0, ambientBrightness + dither * 0.006);
	#else
		inSunlightAmount *= ambientBrightness * ambientBrightness;
	#endif
	inSunlightAmount *= 1.0 - rainStrength * (1.0 - mix(WEATHER_BRIGHTNESS_MULT_NIGHT, WEATHER_BRIGHTNESS_MULT_DAY, dayPercent));
	
	shadowColor = shadowColor / (getLum(shadowColor) + 0.00001) * inSunlightAmount * shadowcasterLight;
	ambientLight *= 1.0 - inSunlightAmount;
	
	ambientLight *= 1.0 - rainStrength * (1.0 - mix(WEATHER_BRIGHTNESS_MULT_NIGHT, WEATHER_BRIGHTNESS_MULT_DAY, dayPercent)) * 0.25;
	vec3 lighting = ambientLight + shadowColor;
	
	#ifdef OVERWORLD
		lighting += lightningFlashAmount * LIGHTNING_BRIGHTNESS * 0.25 * ambientBrightness * ambientBrightness;
	#endif
	
	#ifdef OVERWORLD
		vec3 reflectedDir = normalize(reflect(viewPos, normal));
		vec3 lightDir = normalize(shadowLightPosition);
		float specular = max(dot(reflectedDir, lightDir), 0.0);
		specular *= specular;
		specular *= specular;
		specular *= specular;
		specular *= 1.0 - betterRainStrength;
		vec3 specularColor = shadowColor * (sunAngle < 0.5 ? vec3(1.0, 1.0, 0.4) : vec3(0.5, 0.7, 0.9) * 0.75);
		#if PBR_TYPE == 0
			specular *= 1.0 - 0.25 * getSaturation(color);
		#endif
		// max(0,...): the base 0.05 gives every surface a sun glint. A caller can pass a negative
		// specularness to opt OUT of it entirely (used by block entities — their glint popped on the
		// dark crumbling texels and read as a moving mirror when breaking chests).
		lighting += specularColor * specular * max(0.0, 0.05 + 0.6 * specularness) * min(inSunlightAmount * 64.0, 1.0) * min((sunLightBrightness + moonLightBrightness) * 5.0, 1.0);
	#endif
	
	vec3 blockLight = mix(BLOCK_COLOR_DARK, BLOCK_COLOR_BRIGHT, blockBrightness * blockBrightness);
	#if COLORED_LIGHTING_ENABLED == 1
		// Sample the floodfill volume ONCE and reuse it for the debug view, the blocklight re-hue, and the
		// artificial-light boost below. clColorAt4 is an 8-tap trilinear fetch (+ handheld blend) and
		// clEdgeFade a transform; doing them once instead of per-consumer halves the CL cost per lit fragment.
		bool clOutside;
		vec4 clSample = clColorAt4(viewPos, normal, clOutside);
		float clEdge = clEdgeFade(viewPos);
		vec3 clDebug = clSample.rgb; // floodfill colour at this surface (for the debug view)
		#if COLORED_LIGHTING_DEBUG == 2
			// DEBUG 2: raw emission of the block being looked at, straight from the data, bypassing the buffer.
			vec3 clPlayerPos = transform(gbufferModelViewInverse, viewPos);
			bool clOutside2;
			ivec3 clVoxel2 = getVoxelPos(clPlayerPos, vec3(0.0), clOutside2);
			if (!clOutside2) {
				uint voxelId = texelFetch(voxelIdsSampler, clVoxel2, 0).r;
				vec3 emission = vec3(0.0);
				vec3 translucency = vec3(0.0);
				#define GET_EMISSION
				#define GET_TRANSLUCENCY
				#include "/generated/voxelDatas.glsl"
				#undef GET_EMISSION
				#undef GET_TRANSLUCENCY
				clDebug = emission;
			}
		#endif
		// share of this blocklight explained by the coloured sources; the rest (LambDynLights: burning
		// mobs, dropped torches...) keeps the default warm colour instead of amplifying the coloured one
		float clShare = clOutside ? 1.0 : clDynShare(rawBlockBrightness, viewPos);
		// a coloured source's ARTIFICIAL light (redstone wire, strong emitters) is its own colour by definition —
		// it has no vanilla level to compare (the wire's is 0), so never hand it to the split
		if (!clOutside) clShare = max(clShare, smoothstep(0.0, 0.15, clamp(clSample.a, 0.0, 1.0) * clEdge));
		if (fshNoDynSplit > 0.5) clShare = 1.0;
		blockLight = applyColoredLight(blockLight, clSample, clOutside, clEdge, glowingAmount, clShare);
	#endif
	#ifdef OVERWORLD
		blockBrightness *= 1.0 + ambientBrightness * moonLightBrightness * (BLOCK_BRIGHTNESS_NIGHT_MULT - 1.0);
	#endif
	#if COLORED_LIGHTING_ENABLED == 1
		// strong sources (lava, glowstone, ...) cast colour even where vanilla blocklight is too dim.
		// Reuses the single sample above (was a second clColorAt4 + clEdgeFade).
		float clArtificial = clOutside ? 0.0 : clamp(clSample.a, 0.0, 1.0) * clEdge;
		float clColorPresence = clOutside ? 0.0 : clamp(max(clArtificial, getLum(clSample.rgb) * clEdge), 0.0, 1.0); // brightness boosts stay as before the split (hue-only split)
		// DAY: daylight normally suppresses blocklight (washing the colour out). Where coloured light
		// reaches, retain more of it (CL_DAY_BOOST), scaled by how sunny it is.
		float clSuppress = min(getLum(lighting), 1.0);
		#ifdef OVERWORLD
			clSuppress *= 1.0 - clColorPresence * clamp(CL_DAY_BOOST - 1.0, 0.0, 0.9) * dayPercent;
		#endif
		blockBrightness *= 1.0 - clSuppress;
		// NIGHT: lift the coloured blocklight so it pops (CL_NIGHT_BOOST), fading out toward daytime.
		#ifdef OVERWORLD
			blockBrightness = min(1.0, blockBrightness * (1.0 + clColorPresence * (CL_NIGHT_BOOST - 1.0) * (1.0 - dayPercent)));
		#endif
		blockBrightness = max(blockBrightness, clArtificial * (1.0 - min(getLum(lighting), 1.0)));
	#else
		blockBrightness *= 1.0 - min(getLum(lighting), 1.0);
	#endif
	#ifdef NETHER
		blockLight *= mix(vec3(1.0), NETHER_BLOCKLIGHT_MULT, blockBrightness);
	#endif
	lighting = mix(lighting, blockLight, blockBrightness);
	#if COLORED_LIGHTING_ENABLED == 1
		// small purple light from the player's own enchanted held item (hand + surroundings)
		lighting += CL_ENCHANT_COLOR * clEnchantLightAt(viewPos, normal);
	#endif

	#if COLORED_LIGHTING_ENABLED == 1 && COLORED_LIGHTING_DEBUG >= 1
		// DEBUG: show a raw colour directly (amplified), bypassing all lighting.
		// 1 = floodfill buffer contents, 2 = raw block emission from the data (skips the buffer).
		lighting = clDebug * 8.0;
		#if COLORED_LIGHTING_DEBUG == 3
			lighting = clOutside ? vec3(0.0) : vec3(1.0 - clShare, clShare, 0.0) * (0.15 + rawBlockBrightness);
		#elif COLORED_LIGHTING_DEBUG == 4
			bool clBadLevel = isnan(clStaticLevel) || !(clStaticLevel >= 0.0 && clStaticLevel <= 15.0);
			lighting = clOutside ? vec3(0.0) : clBadLevel ? vec3(1.0, 0.0, 1.0)
			         : vec3(min(rawBlockBrightness * 12.0 + 0.5, 12.5) / 12.5, min(clStaticLevel, 12.5) / 12.5, 0.0);
		#endif
	#endif

	float betterNightVision = nightVision;
	if (betterNightVision > 0.0) {
		betterNightVision = 0.6 + 0.2 * betterNightVision;
		betterNightVision *= NIGHT_VISION_BRIGHTNESS;
	}
	vec3 nightVisionMin = vec3(betterNightVision);
	nightVisionMin.rb *= 1.0 - NIGHT_VISION_GREEN_AMOUNT * (1.0 - ambientBrightness);
	nightVisionMin *= 1.0 + 0.5 * sideShading;
	lighting += nightVisionMin * (1.0 - 0.75 * getLum(lighting));
	
	lighting += glowingAmount * EMISSIVE_BRIGHTNESS * vec3(1.0, 0.85, 0.8);
	
	sideShading *= 1.0 - blockBrightness * blockBrightness;
	lighting *= 1.0 + sideShading;
	
	// [enchant fullbright] enchanted item texels (Enchantment Outlines) show their texture unlit
	lighting = mix(lighting, max(lighting, vec3(fshFullbrightLevel)), fshFullbright);
	#if DO_COLOR_CODED_GBUFFERS == 1
		lighting = vec3(1.0);
	#endif
	color *= lighting;
	
}
