in_out vec2 texcoord;

flat in_out float fogDensity;
flat in_out float fogDarken;
flat in_out float extraFogDist;

#if DEPTH_SUNRAYS_ENABLED == 1
	flat in_out vec2 lightCoord;
#endif
#if REALISTIC_CLOUDS_ENABLED == 1
	flat in_out vec3 cloudsShadowcasterDir;
	flat in_out float cloudsCoverage;
#endif



#ifdef FSH

#include "/utils/projections.glsl"
#include "/utils/depth.glsl"
#include "/utils/borderFogAmount.glsl"

#include "/utils/getFogColor.glsl"
#if COLORED_LIGHTING_ENABLED == 1
	// This composite runs AFTER the floodfill compute (composite.csh), so read the floodfill FRESH
	// (this frame, no 1-frame delay and no camera-shift correction) — the fog glow's raymarch + edge fade
	// then match the sampled cells exactly. (Surface lighting in the gbuffers stage runs before the
	// floodfill, so it must NOT define this and uses the delayed+compensated read instead.)
	#define CL_FRESH_READ
	#include "/lib/colored_lighting/applyColoredLight.glsl"
#endif
#if DEPTH_SUNRAYS_ENABLED == 1
	#include "/lib/sunrays_depth.glsl"
#endif
#if VOL_SUNRAYS_ENABLED == 1
	#include "/lib/sunrays_vol.glsl"
#endif
#if REALISTIC_CLOUDS_ENABLED == 1
	#include "/lib/clouds.glsl"
#endif
#if NETHER_CLOUDS_ENABLED == 1
	#include "/lib/nether_clouds.glsl"
#endif
#if END_CLOUDS_ENABLED == 1
	#include "/lib/end_clouds.glsl"
#endif

#if DEPTH_SUNRAYS_ENABLED == 1 || VOL_SUNRAYS_ENABLED == 1 || REALISTIC_CLOUDS_ENABLED == 1 || NETHER_CLOUDS_ENABLED == 1 || END_CLOUDS_ENABLED == 1
	#define NOISY_RENDERS_ACTIVE
#endif

void main() {
	vec3 color = texelFetch(MAIN_TEXTURE, texelcoord, 0).rgb * 2.0;
	#if defined OVERWORLD && REALISTIC_CLOUDS_ENABLED == 0
		bool isCloud = unpack_2x8(texelFetch(TRANSPARENT_DATA_TEXTURE, texelcoord, 0).y).y > 0.5;
	#else
		const bool isCloud = false;
	#endif
	
	#if FOG_IGNORES_TRANSPARENTS == 0
		float depth;
		if (isCloud) depth = texelFetch(DEPTH_BUFFER_WO_TRANS, texelcoord, 0).r;
		else depth = texelFetch(DEPTH_BUFFER_ALL, texelcoord, 0).r;
	#elif FOG_IGNORES_TRANSPARENTS == 1
		float depth = texelFetch(DEPTH_BUFFER_WO_TRANS, texelcoord, 0).r;
	#endif
	vec3 viewPos = screenToView(vec3(texcoord, depth));
	#ifdef DISTANT_HORIZONS
		#if FOG_IGNORES_TRANSPARENTS == 0
			float depthDh;
			if (isCloud) depthDh = texelFetch(DH_DEPTH_BUFFER_WO_TRANS, texelcoord, 0).r;
			else depthDh = texelFetch(DH_DEPTH_BUFFER_ALL, texelcoord, 0).r;
		#elif FOG_IGNORES_TRANSPARENTS == 1
			float depthDh = texelFetch(DH_DEPTH_BUFFER_WO_TRANS, texelcoord, 0).r;
		#endif
		vec3 viewPosDh = screenToViewDh(vec3(texcoord, depthDh));
		if (viewPosDh.z > viewPos.z) viewPos = viewPosDh;
	#endif
	#ifdef VOXY
		// this does slightly fix something but idk if it's worth it
		//float depthVx = texelFetch(VX_DEPTH_BUFFER_OPAQUE, texelcoord, 0).r;
		//if (depthVx != 1.0) viewPos = screenToViewVx(vec3(texcoord, depthVx));
		//float depthVxTrans = texelFetch(VX_DEPTH_BUFFER_TRANS, texelcoord, 0).r;
		//if (depthVxTrans != 1.0) viewPos = screenToViewVx(vec3(texcoord, depthVxTrans));
	#endif
	vec3 playerPos = transform(gbufferModelViewInverse, viewPos);
	
	
	#ifdef DISTANT_HORIZONS
		//float dhTransparentDepth = texelFetch(DH_DEPTH_BUFFER_ALL, texelcoord, 0).r;
		//vec3 dhTransparentViewPos = screenToViewDh(vec3(texcoord, dhTransparentDepth));
		//if (dhTransparentViewPos.z > viewPos.z - 0.5 || depth > fromLinearDepth(0.9)) {
		//	vec4 dhTransparents = texelFetch(VOXY_TRANSPARENTS_TEXTURE, texelcoord, 0);
		//	dhTransparents.rgb *= 2.0;
		//	dhTransparents.a *= float(!depthIsHand(depth));
		//	color.rgb = mix(color.rgb, dhTransparents.rgb, dhTransparents.a);
		//}
	#endif
	
	
	#if BORDER_FOG_ENABLED == 1 || CYLINDRICAL_CLIPPING == 1
		float _fogDistance;
		float fogAmount = getBorderFogAmount(playerPos, _fogDistance);
		#ifdef DISTANT_HORIZONS
			fogAmount = mix(fogAmount, 1.0, float(depth == 1.0 && depthDh == 1.0));
		#endif
		#ifdef VOXY
			fogAmount = mix(fogAmount, 1.0, float(depth == 1.0));
		#endif
	#else
		const float fogAmount = 0.0;
	#endif
	
	#ifdef OVERWORLD
		float distMult = max(playerPos.y + cameraPosition.y - 64.0, 0.0);
		const float distMultAmplitude = 1.5;
		const float distMultSlope = 8.0;
		distMult = distMultAmplitude * distMultSlope / (distMult + distMultSlope);
	#elif defined NETHER
		float distMult = max(playerPos.y + cameraPosition.y - 30.0, 0.0);
		const float distMultAmplitude = 3.0;
		const float distMultSlope = 6.0;
		distMult = distMultAmplitude * distMultSlope / (distMult + distMultSlope);
	#elif defined END
		const float distMult = 1.0;
	#endif
	
	
	
	#ifdef NOISY_RENDERS_ACTIVE
		vec3 pos = vec3(texcoord, depth);
		vec2 prevCoord = texcoord;
		if (!depthIsHand(depth)) {
			vec3 cameraOffset = cameraPosition - previousCameraPosition;
			prevCoord = reproject(pos, cameraOffset);
		}
		vec2 prevNoisyRender = vec2(0.0);
		bool prevIsValid = all(greaterThanEqual(prevCoord, vec2(0.0))) && all(lessThan(prevCoord, vec2(1.0)));
		if (prevIsValid) {
			float prevDepth = texture2D(PREV_DEPTH_TEXTURE, prevCoord).r;
			float depthDiff = (depth - prevDepth) / depth;
			prevIsValid = depthDiff < 0.00015;
		}
		if (prevIsValid) {
			ivec2 iPrevCoord = ivec2(prevCoord * viewSize);
			prevNoisyRender = texelFetch(NOISY_RENDERS_TEXTURE, iPrevCoord, 0).rg;
		}
	#endif
	
	
	
	// ======== ATMOSPHERIC FOG ======== //
	
	vec2 brightnesses = eyeBrightnessSmooth / 240.0;
	// Per-fragment skylight (this fragment's own sky access, from the gbuffer). Used to pick the fog
	// per fragment: max(camera, fragment) skylight means the sunlit SURFACE seen through a cave mouth
	// keeps bright surface fog instead of being dimmed by the dark/dense cave fog the camera is in.
	float fragSkylight = unpack_2x8(texelFetch(OPAQUE_DATA_TEXTURE, texelcoord, 0).x).y;
	float fogSkylight = max(brightnesses.y, fragSkylight);
	float fogDist = length(playerPos);
	fogDist *= 1.0 + distMult;

	float fogDensity = fogDensity;
	float fogDarken = fogDarken;
	vec3 atmoFogColor = getFogColor(viewPos, playerPos);
	atmoFogColor *= 1.0 - blindness;
	// Kill the fog COLOUR fast under Darkness (reach black by ~0.4, before the density spike below fills
	// the screen). Linear (1-darknessFactor) left a partly-bright, dense fog during the fade in/out —
	// and with low colour saturations the glow is near-white, so it washed out white. Darken the SCENE
	// too (fogDarken) so the effect actually darkens the view instead of adding light fog on top.
	float clDarkFade = smoothstep(0.0, 0.4, darknessFactor);
	atmoFogColor *= 1.0 - clDarkFade;
	fogDarken = mix(fogDarken, 1.0, clDarkFade);
	if (isEyeInWater == 0) {
		#ifndef NETHER
			atmoFogColor *= 0.5 + 0.5 * fogSkylight;
		#endif
		#ifdef OVERWORLD
			fogDensity = mix(UNDERGROUND_FOG_DENSITY, mix(ATMOSPHERIC_FOG_DENSITY, NIGHT_ATMOSPHERIC_FOG_DENSITY, ambientMoonPercent), min(fogSkylight * 1.5, 1.0));
			fogDensity = mix(fogDensity, WEATHER_FOG_DENSITY, betterRainStrength * fogSkylight);
			fogDensity = mix(fogDensity, mix(PALE_GARDEN_FOG_NIGHT_DENSITY, PALE_GARDEN_FOG_DENSITY, dayPercent), inPaleGarden);
		#elif defined NETHER
			fogDensity = NETHER_FOG_DENSITY;
		#elif defined END
			fogDensity = END_FOG_DENSITY;
		#endif
		fogDensity = mix(fogDensity, BLINDNESS_EFFECT_FOG_DENSITY, blindness);
		// Ramp the darkness fog DENSITY in only AFTER the fog colour has already gone dark (clDarkFade
		// above fades the colour over darknessFactor 0..0.4). DARKNESS_EFFECT_FOG_DENSITY can be huge, so
		// with a plain darknessFactor mix the density spikes near df=0 — filling the screen with fog while
		// the colour is still bright = the washed-out white flash. Delaying it (0.25..1.0) keeps the fog
		// dark as it thickens.
		fogDensity = mix(fogDensity, DARKNESS_EFFECT_FOG_DENSITY / 2.0, smoothstep(0.25, 1.0, darknessFactor));
		fogDensity /= 256.0;
	}
	
	fogDist = mix(fogDist, 0.0, fogAmount);
	float atmoFogAmount = 1.0 - exp(-fogDensity * (fogDist + extraFogDist));
	#ifndef NETHER
		atmoFogAmount *= 1.0 - 0.25 * float(isEyeInWater == 0);
	#endif
	// [colored fog glow] raymarch the view ray through the CL volume and fold the colour it passes through
	// INTO the fog colour, so the coloured fog fades EXACTLY like the pack's normal fog (which has no dome)
	// rather than being a separate additive glow/ring. Skipped in fluids (they have their own fog).
	#if COLORED_LIGHTING_ENABLED == 1 // (strength checked at runtime: #if can't compare floats < 1)
	// Only raymarch where there is actually fog to tint: the glow is folded into atmoFogColor and applied
	// as `atmoFogColor * atmoFogAmount`, so with ~no fog at this fragment the whole 6-sample × 8-tap march
	// is wasted. Skipping it there is a big saving on clear/near-field pixels and when fog is disabled.
	if (CL_FOG_GLOW_STRENGTH > 0.001 && isEyeInWater == 0 && atmoFogAmount > 0.002) {
		float clDist = length(playerPos);
		float clRayLen = min(clDist, float(COLORED_LIGHTING_DIST) * 0.9);
		if (clRayLen > 0.5) {
			vec3 clStep = (playerPos / max(clDist, 0.001)) * (clRayLen / float(CL_FOG_GLOW_SAMPLES));
			vec3 clPos = clStep * bayer64(gl_FragCoord.xy);
			vec3 clGlow = vec3(0.0);
			float clWeight = 0.0;
			for (int i = 0; i < CL_FOG_GLOW_SAMPLES; i++) {
				vec4 cl = clSampleSmooth(clPos, vec3(0.0));
				vec3 rel = abs(clPos + cameraPositionFract) / vec3(halfColoredLightingSize);
				float edge = 1.0 - smoothstep(0.75, 1.0, max(rel.x, max(rel.y, rel.z)));
				clGlow += cl.rgb * edge;
				clWeight += edge;
				clPos += clStep;
			}
			if (clWeight > 0.001) {
				vec3 clAvg = clGlow / clWeight;
				float clMax = max(clAvg.r, max(clAvg.g, clAvg.b));
				if (clMax > 0.00001) {
					// saturated source hue + saturating intensity so bright sources don't dominate
					vec3 clHue = clamp(mix(vec3(1.0), clAvg / clMax, CL_FOG_GLOW_SATURATION), 0.0, 1.0);
					float intensity = pow(clMax / (clMax + 2.0), 1.0 / CL_FOG_GLOW_REACH);
					// The pow() with a high CL_FOG_GLOW_REACH boosts even a tiny averaged colour to a large
					// intensity; the old hard `clMax > 0.001` cutoff then dropped it to 0 abruptly at the radius
					// where the ray's average dilutes below that — a sharp sphere/dome. Fade the intensity
					// smoothly to 0 as clMax -> 0 instead, so it tapers with no hard edge (rays that pass dense
					// light keep full colour, so distant fog still accumulates properly).
					intensity *= smoothstep(0.0, 0.015, clMax);
					// darken the glow by the blindness/darkness effects too — the base fog above is already
					// multiplied by these, but the glow is added AFTER, so without this it stays bright and
					// looks fullbright while everything else goes dark under the Darkness effect.
					atmoFogColor += clHue * (intensity * CL_FOG_GLOW_STRENGTH) * ((1.0 - blindness) * (1.0 - clDarkFade));
				}
			}
		}
	}
	#endif

	color = mix(vec3(getLum(color)), color, 1.0 + atmoFogAmount * 0.5);
	color *= 1.0 - min(atmoFogAmount * fogDarken, 1.0);
	color += atmoFogColor * atmoFogAmount;

	
	#if defined OVERWORLD && HBD_ENABLED == 1
		float desaturationAmount = 1.0 - HBD_SCALE / (max(playerPos.y + cameraPosition.y - 64.0, 0) + HBD_SCALE);
		desaturationAmount *= 1.0 - fogAmount;
		desaturationAmount *= HBD_STRENGTH * 0.75;
		color.rgb = mix(color.rgb, vec3(getLum(color.rgb) + 0.1), desaturationAmount);
	#endif
	
	
	
	// ======== SUNRAYS ======== //
	
	#if DEPTH_SUNRAYS_ENABLED == 1
		float depthSunraysAddition = getDepthSunraysAmount();
		depthSunraysAddition *= 1.0 - 0.8 * fogAmount;
		float dither = bayer64(gl_FragCoord.xy);
		dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
		depthSunraysAddition += dither / 255.0;
	#else
		float depthSunraysAddition = 0.0;
	#endif
	#if VOL_SUNRAYS_ENABLED == 1
		float volSunraysAmount = getVolSunraysAmount(playerPos, distMult);
		volSunraysAmount *= 1.0 - fogAmount;
		volSunraysAmount = 1.0 / (1.0 + volSunraysAmount * 0.01); // compress data to [0-1] (the *0.01 is pretty important for preventing quantization, if the strength needs to be changed, do so elsewhere)
	#else
		float volSunraysAmount = 1.0;
	#endif
	
	
	
	// ======== CLOUDS RENDERING ======== //
	
	#if REALISTIC_CLOUDS_ENABLED == 1
		vec2 cloudData = computeClouds(playerPos);
	#elif NETHER_CLOUDS_ENABLED == 1
		vec2 cloudData = computeNetherClouds(playerPos);
	#elif END_CLOUDS_ENABLED == 1
		vec2 cloudData = computeEndClouds(playerPos);
	#else
		vec2 cloudData = vec2(0.0);
	#endif
	
	
	
	// ======== TEMPORAL FILTERING FOR CLOUDS AND SUNRAYS ======== //
	
	#ifdef NOISY_RENDERS_ACTIVE
		if (prevIsValid) {
			#if DEPTH_SUNRAYS_ENABLED == 1 || VOL_SUNRAYS_ENABLED == 1
				vec2 prevSunraysDatas = unpack_2x8(prevNoisyRender.x);
			#endif
			#if DEPTH_SUNRAYS_ENABLED == 1
				if (abs(prevSunraysDatas.x - depthSunraysAddition) > 0.02)
					depthSunraysAddition = mix(depthSunraysAddition, prevSunraysDatas.x, 0.75);
			#endif
			#if VOL_SUNRAYS_ENABLED == 1
				if (abs(prevSunraysDatas.y - volSunraysAmount) > 0.02)
					volSunraysAmount = mix(volSunraysAmount, prevSunraysDatas.y, 0.5);
			#endif
			#if REALISTIC_CLOUDS_ENABLED == 1 || NETHER_CLOUDS_ENABLED == 1 || END_CLOUDS_ENABLED == 1 || END_CLOUDS_ENABLED == 1
				vec2 prevCloudsData = unpack_2x8(prevNoisyRender.y);
				cloudData = mix(cloudData, prevCloudsData, 0.5);
			#endif
		}
	#endif
	
	
	
	// ======== MIX WEATHER RENDER ======== //
	
	if (rainStrength > 0.0) {
		vec4 weather = texelFetch(WEATHER_TEXTURE, texelcoord, 0);
		color = mix(color, weather.rgb * 1.5, weather.a);
	}
	
	
	
	#if !defined NOISY_RENDERS_ACTIVE
		/* DRAWBUFFERS:0 */
		color *= 0.5;
		gl_FragData[0] = vec4(color, 1.0);
	#endif
	#if defined NOISY_RENDERS_ACTIVE
		/* DRAWBUFFERS:06 */
		color *= 0.5;
		gl_FragData[0] = vec4(color, 1.0);
		gl_FragData[1] = vec4(
			pack_2x8(depthSunraysAddition, volSunraysAmount),
			pack_2x8(cloudData),
			0.0, 1.0
		);
	#endif
	
}

#endif



#ifdef VSH

void main() {
	gl_Position = ftransform();
	texcoord = gl_MultiTexCoord0.xy;
	
	
	
	// ======== ATMOSPHERIC FOG ======== //
	
	if (isEyeInWater == 0) {
		fogDensity = 0.0;
		#ifdef OVERWORLD
			fogDarken = 1.1;
			fogDarken = mix(fogDarken, 0.85, betterRainStrength * eyeBrightnessSmooth.y / 240.0);
		#elif defined NETHER
			fogDarken = 0.75;
		#else
			fogDarken = 1.0;
		#endif
		extraFogDist = 2.0 * inPaleGarden;
		extraFogDist += betterRainStrength * 8.0;
	} else if (isEyeInWater == 1) {
		fogDensity = WATER_FOG_DENSITY * 0.2;
		fogDarken = 1.0;
		extraFogDist = 48.0;
	} else if (isEyeInWater == 2) {
		fogDensity = LAVA_FOG_DENSITY * 0.2;
		fogDarken = 1.0;
		extraFogDist = 1.5;
	} else if (isEyeInWater == 3) {
		fogDensity = POWDERED_SNOW_FOG_DENSITY * 0.2;
		fogDarken = 1.0;
		extraFogDist = 1.0;
	} else {
		fogDensity = 1.0;
		fogDarken = 1.0;
		extraFogDist = 0.0;
	}
	
	fogDensity = mix(fogDensity, BLINDNESS_EFFECT_FOG_DENSITY / 300.0, blindness);
	fogDarken = mix(fogDarken, 1.0, blindness);
	extraFogDist *= 1.0 - blindness;
	
	fogDensity = mix(fogDensity, DARKNESS_EFFECT_FOG_DENSITY / 600.0, darknessFactor);
	fogDarken = mix(fogDarken, 1.0, darknessFactor);
	extraFogDist = mix(extraFogDist, 4.0, darknessFactor);
	
	
	
	// ======== SUNRAYS ======== //
	
	#if DEPTH_SUNRAYS_ENABLED == 1
		vec3 lightPos = shadowLightPosition * mat3(gbufferProjection);
		lightPos /= lightPos.z;
		lightCoord = lightPos.xy * 0.5 + 0.5;
	#endif
	
	
	
	// ======== CLOUDS ======== //
	
	#if REALISTIC_CLOUDS_ENABLED == 1
		cloudsShadowcasterDir = normalize(mat3(gbufferModelViewInverse) * shadowLightPosition) * 10.0;
		cloudsCoverage = mix(1.0 - CLOUD_COVERAGE, 0.8 - 0.6 * CLOUD_WEATHER_COVERAGE, rainStrength);
	#endif
	
	
	
}

#endif
