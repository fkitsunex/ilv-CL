#ifndef INCLUDE_GET_SKY_COLOR
#define INCLUDE_GET_SKY_COLOR

#include "/lib/night_sky.glsl"



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

vec3 getSkyColor(vec3 viewDir, const bool includeLightning) {
	vec3 skyColor;
	
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
		
		float skyMixFactor = dayPercent;
		float upDot = dot(viewDir, gbufferModelView[1].xyz);
		skyColor = mix(NIGHT_COLOR, DAY_COLOR, skyMixFactor);
		skyColor = mix(skyColor, vec3(0.05 + dayPercent * 0.4), inPaleGarden);
		upDot = max(upDot, 0.0);
		vec3 horizonColor = mix(HORIZON_NIGHT_COLOR, HORIZON_DAY_COLOR, skyMixFactor);
		#if CUSTOM_OVERWORLD_SKYBOX == 1
			horizonColor *= 1.0 - 0.4 * sunriseSunsetPercent;
			skyColor *= 1.0 - 0.4 * sunriseSunsetPercent;
		#endif
		horizonColor = mix(horizonColor, vec3(0.1 + 0.25 * dayPercent), inPaleGarden);
		// [night sky] no light horizon band at night (it made the fog grey against a black sky) — must stay the
		// same as in /utils/getFogColor.glsl
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
		skyColor = mix(skyColor, horizonColor, horizonAmount);
		
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
		skyColor = mix(skyColor, sunAngle > 0.25 && sunAngle < 0.75 ? HORIZON_SUNSET_COLOR : HORIZON_SUNRISE_COLOR, sunDot);

		skyColor *= 2.0/3.0;
		skyColor = min(skyColor, 1.0);
		skyColor = 1.0 - (skyColor - 1.0) * (skyColor - 1.0);
		skyColor *= 3.0/2.0 * 1.2;
		skyColor *= 0.3 + 0.7 * dayPercent;

		// rain/overcast mix AFTER the brightening curve, so the wet sky stays a controlled grey
		// instead of being pushed to white (otherwise the Distant Horizons border shows up as a
		// white band during rain). SKY_WEATHER_BRIGHTNESS now directly sets the overcast brightness.
		float rainAmount = rainStrength * SKY_WEATHER_DESATURATION;
		rainAmount *= 1.0 - (1.0 - dayPercent) * (1.0 - dayPercent);
		skyColor = mix(skyColor, vec3(0.8, 0.9, 1.0) * SKY_WEATHER_BRIGHTNESS * dayPercent, rainAmount);
		#if CUSTOM_OVERWORLD_SKYBOX == 1
			// custom skyboxes / sky mods: follow the game's own sky -> fog gradient (Cirrus recolours these), so
			// fog, reflections and the DH border match the sky that's actually drawn
			float vanillaHorizonAmount = 1.0 - upDot; // the game's own gradient (fog = vanilla fog colour here)
			vanillaHorizonAmount *= vanillaHorizonAmount;
			vanillaHorizonAmount *= vanillaHorizonAmount;
			skyColor = mix(vanillaSkyColor(), vanillaFogColor(), vanillaHorizonAmount);
		#endif
		
		if (includeLightning) {
			skyColor += lightningFlashAmount * LIGHTNING_BRIGHTNESS * 0.25;
			// [night sky] aurora, Milky Way, stars (the actual sky + its reflections; not the fog colour)
			skyColor += getNightSkyLayers(viewDir);
		}
		
		vec3 playerDir = mat3(gbufferModelViewInverse) * viewDir;
		playerDir /= max(length(playerDir.xz), abs(playerDir.y * 1.25));
		float cameraPositionY = mix(cameraPosition.y, max(cameraPosition.y, 56.0), eyeBrightnessSmooth.y / 240.0);
		float yPos = playerDir.y * far + cameraPositionY;
		float darkenAmount = percentThrough(yPos, 56.0, 56.0 - far / 4.0);
		#if UNDERGROUND_FOG_COLOR_TYPE == 1
			#define FOG_COLOR fogColor
		#elif UNDERGROUND_FOG_COLOR_TYPE == 2
			#define FOG_COLOR vec3(UNDERGROUND_FOG_BRIGHTNESS * 0.5)
		#endif
		// below the horizon the sky DARKENS towards the cave fog — never brightens (the grey lit up the night sky)
		skyColor = mix(skyColor, min(FOG_COLOR, skyColor), darkenAmount);
		
		#if CUSTOM_OVERWORLD_SKYBOX == 1
			skyColor *= CUSTOM_OVERWORLD_SKY_BRIGHTNESS;
			skyColor = mix(vec3(getLum(skyColor)), skyColor, CUSTOM_OVERWORLD_SKY_SATURATION);
		#endif
		
		#if AUTO_EXPOSURE_ENABLED == 1
			skyColor *= 0.9;
		#endif
		
	#elif defined NETHER
		
		// must stay the same as in /utils/getFogColor.glsl
		skyColor = netherFogColor();
		skyColor = mix(vec3(getLum(skyColor)), skyColor, NETHER_SKY_FOG_SATURATION);
		skyColor = NETHER_SKY_BASE_COLOR + NETHER_SKY_FOG_INFLUENCE * skyColor;
		skyColor *= NETHER_SKY_TINT_COLOR;
		
	#elif defined END
		
		#if CUSTOM_END_SKYBOX == 0
			skyColor = getEndSky(normalize(mat3(gbufferModelViewInverse) * viewDir)); // lib/night_sky.glsl
		#elif CUSTOM_END_SKYBOX == 1
			skyColor = vec3(0.0);
		#endif
		
	#endif
	
	if (isEyeInWater == 1) {
		skyColor = mix(skyColor, WATER_FOG_COLOR * (0.25 + 0.75 * max(dayPercent, eyeBrightnessSmooth.x / 240.0)), 0.75);
	} else if (isEyeInWater == 2) {
		skyColor = mix(skyColor, LAVA_FOG_COLOR * (0.25 + 0.75 * max(dayPercent, eyeBrightnessSmooth.x / 240.0)), 0.75);
	} else if (isEyeInWater == 3) {
		skyColor = mix(skyColor, POWDERED_SNOW_FOG_COLOR * (0.25 + 0.75 * max(dayPercent, eyeBrightnessSmooth.x / 240.0)), 0.75);
	}
	
	return skyColor;
	
}



#endif
