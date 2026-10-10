#ifndef INCLUDE_GET_FOG_COLOR
#define INCLUDE_GET_FOG_COLOR



#ifndef INCLUDE_VANILLA_SKY_UNIFORMS
#define INCLUDE_VANILLA_SKY_UNIFORMS
	// vanilla sky / fog colour as the game (and sky mods like Cirrus, which recolour them) computed it
	vec3 vanillaSkyColor() { return skyColor; }
	vec3 vanillaFogColor() { return fogColor; }
	// [nether fog] Night Vision makes the game rescale the fog colour so its brightest channel hits 1
	// (fog * ((1 - nv) + nv / max)), which turned the Nether fog into a glaring wall. Undo that, so Night Vision
	// brightens only the lighting. The original max isn't recoverable at full strength, so it comes from the
	// biome (netherFogMax, shaders.properties); while the effect fades (nv < 1) it's computed exactly.
	vec3 netherFogColor() {
		float nv = clamp(nightVision, 0.0, 1.0);
		if (nv < 0.001) return fogColor;
		float maxNv = max(fogColor.r, max(fogColor.g, fogColor.b));
		float exactMax = (maxNv - nv) / max(1.0 - nv, 0.0001);
		float origMax = mix(clamp(exactMax, 0.01, 1.0), netherFogMax, smoothstep(0.85, 0.97, nv));
		return fogColor / ((1.0 - nv) + nv / origMax);
	}
#endif

vec3 getFogColor(vec3 viewPos, vec3 playerPos) {
	vec3 fogColorOut;
	
	#ifdef OVERWORLD
		
		#if CUSTOM_OVERWORLD_SKYBOX == 0
			const vec3 DAY_COLOR = SKY_DAY_COLOR * 0.75;
			const vec3 NIGHT_COLOR = SKY_NIGHT_COLOR * 0.25;
			const vec3 HORIZON_DAY_COLOR = SKY_HORIZON_DAY_COLOR * 0.75;
			const vec3 HORIZON_NIGHT_COLOR = SKY_HORIZON_NIGHT_COLOR * 0.25;
			const vec3 HORIZON_SUNRISE_COLOR = SKY_HORIZON_SUNRISE_COLOR;
			const vec3 HORIZON_SUNSET_COLOR = SKY_HORIZON_SUNSET_COLOR;
		#elif CUSTOM_OVERWORLD_SKYBOX == 1
			const vec3 DAY_COLOR = SKY_DAY_COLOR * 0.8;
			const vec3 NIGHT_COLOR = SKY_NIGHT_COLOR * 0.3;
			const vec3 HORIZON_DAY_COLOR = SKY_HORIZON_DAY_COLOR * 0.8;
			const vec3 HORIZON_NIGHT_COLOR = SKY_HORIZON_NIGHT_COLOR * 0.25;
			const vec3 HORIZON_SUNRISE_COLOR = SKY_HORIZON_SUNRISE_COLOR * 0.75;
			const vec3 HORIZON_SUNSET_COLOR = SKY_HORIZON_SUNSET_COLOR * 0.75;
		#endif
		
		float sunriseSunsetPercent = ambientSunrisePercent + ambientSunsetPercent;
		vec3 viewDir = normalize(viewPos);
		
		float skyMixFactor = dayPercent;
		float upDot = dot(viewDir, gbufferModelView[1].xyz);
		fogColorOut = mix(NIGHT_COLOR, DAY_COLOR, skyMixFactor);
		fogColorOut = mix(fogColorOut, vec3(0.05 + dayPercent * 0.4), inPaleGarden);
		upDot = max(upDot, 0.0);
		vec3 horizonColor = mix(HORIZON_NIGHT_COLOR, HORIZON_DAY_COLOR, skyMixFactor);
		#if CUSTOM_OVERWORLD_SKYBOX == 1
			horizonColor *= 1.0 - 0.4 * sunriseSunsetPercent;
			fogColorOut *= 1.0 - 0.4 * sunriseSunsetPercent;
		#endif
		horizonColor = mix(horizonColor, vec3(0.1 + 0.25 * dayPercent), inPaleGarden);
		// [night fog] the light horizon band is a daytime thing: at night it made the fog (and the far terrain
		// faded into the sky) grey against a black sky. Fade it out at night — kept identical in getSkyColor.
		float horizonAmount = 1.0 - max(upDot, 0.5 * (1.0 - dayPercent));
		#if HORIZON_FADE_STRENGTH > 0
			horizonAmount *= horizonAmount;
		#endif
		#if HORIZON_FADE_STRENGTH > 1
			horizonAmount *= horizonAmount;
		#endif
		#if HORIZON_FADE_STRENGTH > 2
			horizonAmount *= horizonAmount;
		#endif
		#if HORIZON_FADE_STRENGTH > 3
			horizonAmount *= horizonAmount;
		#endif
		#if HORIZON_FADE_STRENGTH > 4
			horizonAmount *= horizonAmount;
		#endif
		#if HORIZON_FADE_STRENGTH > 5
			horizonAmount *= horizonAmount;
		#endif
		#if FOG_BUG_RECREATION == 1
			horizonAmount = 1.0;
		#endif
		fogColorOut = mix(fogColorOut, horizonColor, horizonAmount);
		
		float sunDot = dot(viewDir, sunPosition * 0.01) * 0.5 + 0.5;
		#if CUSTOM_OVERWORLD_SKYBOX == 0
			sunDot = 1.0 - (1.0 - sunDot) * (1.0 - sunDot);
		#elif CUSTOM_OVERWORLD_SKYBOX == 1
			sunDot *= sunDot;
		#endif
		float upDotForSS = 1.0 - (1.0 - upDot) * (1.0 - upDot);
		sunDot *= percentThrough(upDotForSS * (1.0 - SUNRISE_SUNSET_TOP_HEIGHT * 0.5), 1.0, SUNRISE_SUNSET_BOTTOM_HEIGHT);
		sunDot *= sunriseSunsetPercent;
		sunDot *= 1.0 - 0.5 * inPaleGarden;
		fogColorOut = mix(fogColorOut, sunAngle > 0.25 && sunAngle < 0.75 ? HORIZON_SUNSET_COLOR : HORIZON_SUNRISE_COLOR, sunDot);
		
		fogColorOut *= 2.0/3.0;
		fogColorOut = min(fogColorOut, 1.0);
		fogColorOut = 1.0 - (fogColorOut - 1.0) * (fogColorOut - 1.0);
		fogColorOut *= 3.0/2.0 * 1.2;
		fogColorOut *= 0.3 + 0.7 * dayPercent;

		// rain/overcast mix AFTER the brightening curve — keeps the wet fog grey instead of white,
		// so it matches the sky and the Distant Horizons border doesn't show as a white band in rain.
		// (kept identical to the rain mix in /utils/getSkyColor.glsl)
		float rainAmount = rainStrength * SKY_WEATHER_DESATURATION;
		rainAmount *= 1.0 - (1.0 - dayPercent) * (1.0 - dayPercent);
		fogColorOut = mix(fogColorOut, vec3(0.8, 0.9, 1.0) * SKY_WEATHER_BRIGHTNESS * dayPercent, rainAmount);
		#if CUSTOM_OVERWORLD_SKYBOX == 1
			// custom skyboxes / sky mods: the game's own fog colour (sky mods like Cirrus recolour it)
			fogColorOut = vanillaFogColor();
		#endif
		
		#if UNDERGROUND_FOG_COLOR_TYPE == 1
			#define FOG_COLOR fogColor
		#elif UNDERGROUND_FOG_COLOR_TYPE == 2
			#define FOG_COLOR vec3(UNDERGROUND_FOG_BRIGHTNESS * 0.5)
		#endif
		// the cave fog colour is a fixed grey: half under a roof at night it lifted the fog well above the night
		// sky. Near the surface it's capped by the surface fog, so it can only darken it (deep caves unchanged).
		#if UNDERGROUND_FOG_CONDITION == 1
			fogColorOut = mix(mix(FOG_COLOR, min(FOG_COLOR, fogColorOut), smootherEyeBrightness.y), fogColorOut, smootherEyeBrightness.y);
		#elif UNDERGROUND_FOG_CONDITION == 2
			fogColorOut = mix(mix(FOG_COLOR, min(FOG_COLOR, fogColorOut), positionalUndergroundDarkness), fogColorOut, positionalUndergroundDarkness);
		#endif
		
	#elif defined NETHER
		
		// must stay the same as in /utils/getSkyColor.glsl
		fogColorOut = netherFogColor();
		fogColorOut = mix(vec3(getLum(fogColorOut)), fogColorOut, NETHER_SKY_FOG_SATURATION);
		fogColorOut = NETHER_SKY_BASE_COLOR + NETHER_SKY_FOG_INFLUENCE * fogColorOut;
		fogColorOut *= NETHER_SKY_TINT_COLOR;
		
	#elif defined END
		
		fogColorOut = END_FOG_COLOR;
		// the void below the islands is empty -> its fog fades to black too (matches getEndSky)
		fogColorOut *= smoothstep(-0.3, 0.3, playerPos.y / max(length(playerPos), 0.0001));
		
	#endif
	
	if (isEyeInWater == 1) {
		fogColorOut = WATER_FOG_COLOR * (0.2 + 0.8 * max(dayPercent, eyeBrightnessSmooth.x / 240.0));
	} else if (isEyeInWater == 2) {
		fogColorOut = LAVA_FOG_COLOR * (0.2 + 0.8 * max(dayPercent, eyeBrightnessSmooth.x / 240.0));
	} else if (isEyeInWater == 3) {
		fogColorOut = POWDERED_SNOW_FOG_COLOR * (0.2 + 0.8 * max(dayPercent, eyeBrightnessSmooth.x / 240.0));
	}
	
	return fogColorOut;
	
}



#endif
