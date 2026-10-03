#if COLORED_LIGHTING_ENABLED == 1
	#include "/lib/colored_lighting/applyColoredLight.glsl"
#endif



// set to 1 by gbuffers_particles: add the sun/moon light (undirected, as for an up-facing surface) — this
// path had none, so particles drawn after deferred only got the sky ambient and never the warm dusk light
float simpleParticleSun = 0.0;

void doSimpleFshLighting(inout vec3 color, float blockBrightness, float ambientBrightness, float specularness, vec3 viewPos, vec3 normal) {
	float rawBlockBrightness = blockBrightness;
	
	// night saturation decrease
	#ifdef OVERWORLD
		float nightPercent = 1.0 - dayPercent;
		nightPercent *= ambientBrightness * (1.0 - blockBrightness);
		nightPercent *= nightPercent;
		nightPercent *= NIGHT_SATURATION_DECREASE;
		color = mix(vec3(getLum(color)), color, 1.0 - nightPercent * 0.1);
		color += nightPercent * 0.06;
	#endif
	
	#ifdef END
		ambientBrightness = 1.0;
	#endif
	
	vec2 prepareData10 = texelFetch(MISC_DATA_TEXTURE, ivec2(1, 0), 0).rg;
	vec2 prepareData01 = texelFetch(MISC_DATA_TEXTURE, ivec2(0, 1), 0).rg;
	vec2 prepareData11 = texelFetch(MISC_DATA_TEXTURE, ivec2(1, 1), 0).rg;
	vec3 shadowcasterLight = vec3(prepareData10, prepareData01.r) * 2.0;
	vec3 ambientLight = vec3(prepareData01.g, prepareData11) * 2.0;
	#ifdef OVERWORLD
		// cave ambient only in the Overworld (as fsh_lighting): the Nether has no skylight, so this used to swap
		// its ambient for the dark cave colour and particles there came out near-black
		ambientLight = mix(CAVE_AMBIENT_COLOR * 0.6 * (1.0 + 0.4 * screenBrightness), ambientLight, ambientBrightness);
	#endif
	#if defined OVERWORLD || defined END
		if (simpleParticleSun > 0.5) {
			// same sun term as fsh_lighting (no shadow map), for an up-facing surface
			float pLightDot = dot(normalize(shadowLightPosition), gbufferModelView[1].xyz);
			pLightDot = 0.25 + 0.75 * pLightDot; // lightDotLift 0.5, as fsh_lighting without real-time shadows
			float pSun = min((sunLightBrightness + moonLightBrightness) * 5.0, 1.0) * clamp(pLightDot, 0.0, 1.0);
			pSun *= ambientBrightness * ambientBrightness;
			pSun *= 1.0 - rainStrength * (1.0 - mix(WEATHER_BRIGHTNESS_MULT_NIGHT, WEATHER_BRIGHTNESS_MULT_DAY, dayPercent));
			ambientLight = ambientLight * (1.0 - pSun) + shadowcasterLight * pSun;
		}
	#endif
	
	#if BLOCK_BRIGHTNESS_CURVE == 2
		blockBrightness = pow2(blockBrightness);
	#elif BLOCK_BRIGHTNESS_CURVE == 3
		blockBrightness = pow3(blockBrightness);
	#elif BLOCK_BRIGHTNESS_CURVE == 4
		blockBrightness = pow4(blockBrightness);
	#elif BLOCK_BRIGHTNESS_CURVE == 5
		blockBrightness = pow5(blockBrightness);
	#endif
	
	ambientLight *= 1.0 - rainStrength * (1.0 - mix(WEATHER_BRIGHTNESS_MULT_NIGHT, WEATHER_BRIGHTNESS_MULT_DAY, dayPercent)) * 0.25;
	vec3 lighting = ambientLight;
	
	#ifdef OVERWORLD
		lighting += lightningFlashAmount * LIGHTNING_BRIGHTNESS * 0.25 * ambientBrightness * ambientBrightness;
	#endif
	
	vec3 blockLight = mix(BLOCK_COLOR_DARK, BLOCK_COLOR_BRIGHT, blockBrightness * blockBrightness);
	// Coloured light: same treatment as surfaces (fsh_lighting) — before, daylight simply zeroed the
	// blocklight here (`*= 1 - lum(lighting)`), so particles under the open sky never took any colour, and
	// they also missed the night boost and the strong sources' artificial light.
	#if COLORED_LIGHTING_ENABLED == 1
		bool clOutside;
		vec4 clSample = clColorAt4(viewPos, normal, clOutside);
		float clEdge = clEdgeFade(viewPos);
		blockLight = applyColoredLight(blockLight, clSample, clOutside, clEdge, 0.0, 1.0); // no dyn-light split for particles
	#endif
	#ifdef OVERWORLD
		blockBrightness *= 1.0 + ambientBrightness * moonLightBrightness * (BLOCK_BRIGHTNESS_NIGHT_MULT - 1.0);
	#endif
	#if COLORED_LIGHTING_ENABLED == 1
		float clArtificial = clOutside ? 0.0 : clamp(clSample.a, 0.0, 1.0) * clEdge;
		float clColorPresence = clOutside ? 0.0 : clamp(max(clArtificial, getLum(clSample.rgb) * clEdge), 0.0, 1.0);
		float clSuppress = min(getLum(lighting), 1.0);
		#ifdef OVERWORLD
			clSuppress *= 1.0 - clColorPresence * clamp(CL_DAY_BOOST - 1.0, 0.0, 0.9) * dayPercent;
		#endif
		blockBrightness *= 1.0 - clSuppress;
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
	blockLight *= blockBrightness;
	lighting *= 1.0 - min(getLum(blockLight), 1.0);
	lighting += blockLight;
	
	float betterNightVision = nightVision;
	if (betterNightVision > 0.0) {
		betterNightVision = 0.6 + 0.2 * betterNightVision;
		betterNightVision *= NIGHT_VISION_BRIGHTNESS;
	}
	vec3 nightVisionMin = vec3(betterNightVision);
	nightVisionMin.rb *= 1.0 - NIGHT_VISION_GREEN_AMOUNT * (1.0 - ambientBrightness);
	lighting += nightVisionMin * (1.0 - 0.75 * getLum(lighting));
	
	#if DO_COLOR_CODED_GBUFFERS == 1
		lighting = vec3(1.0);
	#endif
	color *= lighting;
	
}
