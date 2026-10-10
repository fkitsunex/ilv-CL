#ifndef INCLUDE_NIGHT_SKY
#define INCLUDE_NIGHT_SKY

// [night sky] ILV-CL's own aurora, Milky Way and star field — original procedural code (written for this pack,
// not taken from any mod). Added to the sky colour, so it also shows in sky reflections and the fog blend.

uniform int biome_precipitation; // Iris: 0 = none, 1 = rain, 2 = snow (for "aurora in cold biomes only")

float nsHash13(vec3 p) {
	p = fract(p * 0.1031);
	p += dot(p, p.zyx + 31.32);
	return fract((p.x + p.y) * p.z);
}
float nsHash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float nsNoise2(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = nsHash12(i);
	float b = nsHash12(i + vec2(1.0, 0.0));
	float c = nsHash12(i + vec2(0.0, 1.0));
	float d = nsHash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}
float nsNoise3(vec3 p) {
	vec3 i = floor(p);
	vec3 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float n000 = nsHash13(i);
	float n100 = nsHash13(i + vec3(1, 0, 0));
	float n010 = nsHash13(i + vec3(0, 1, 0));
	float n110 = nsHash13(i + vec3(1, 1, 0));
	float n001 = nsHash13(i + vec3(0, 0, 1));
	float n101 = nsHash13(i + vec3(1, 0, 1));
	float n011 = nsHash13(i + vec3(0, 1, 1));
	float n111 = nsHash13(i + vec3(1, 1, 1));
	return mix(mix(mix(n000, n100, f.x), mix(n010, n110, f.x), f.y),
	           mix(mix(n001, n101, f.x), mix(n011, n111, f.x), f.y), f.z);
}
float nsFbm2(vec2 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * nsNoise2(p); p = p * 2.03 + 17.1; a *= 0.5; }
	return v / 0.9375;
}
float nsFbm3(vec3 p) {
	float v = 0.0, a = 0.5;
	for (int i = 0; i < 4; i++) { v += a * nsNoise3(p); p = p * 2.03 + 17.1; a *= 0.5; }
	return v / 0.9375;
}

// Direction in the celestial frame, which turns with the sun exactly like vanilla's stars (Iris builds the
// celestial matrix as RotY(-90) * RotZ(sunPathRotation) * RotX(skyAngle), so its rotation axis in player
// space is (0, sin r, cos r) and the sun sits on its local +Y).
vec3 nsCelestial(vec3 playerDir) {
	vec3 sunDir = normalize(mat3(gbufferModelViewInverse) * sunPosition);
	float r = radians(sunPathRotation);
	vec3 axis = normalize(vec3(0.0, sin(r), cos(r)));
	axis = normalize(axis - sunDir * dot(axis, sunDir)); // keep it exactly perpendicular to the sun
	vec3 third = cross(axis, sunDir);
	return vec3(dot(playerDir, axis), dot(playerDir, sunDir), dot(playerDir, third));
}

// Aurora: curtains whose footprint is a set of slowly meandering lines on a sheet high above the world. The
// view ray crosses that sheet at several heights; each crossing adds the curtain there, green low down and
// fading through teal to violet at the top, with vertical ray streaks.
vec3 nsAurora(vec3 d) {
	if (d.y < 0.005) return vec3(0.0);
	float t = frameTimeCounter * 0.015 * AURORA_SPEED;
	vec3 acc = vec3(0.0);
	const int LAYERS = 16;
	// per-pixel, per-frame offset of the sample heights: fixed heights showed as separate stacked copies of
	// the curtain line ("visible layers"); jittered, TAA blends them into one continuous curtain
	float jitter = fract(52.9829189 * fract(dot(gl_FragCoord.xy, vec2(0.06711056, 0.00583715))) + float(frameCounter) * 0.61803399);
	for (int i = 0; i < LAYERS; i++) {
		float k = (float(i) + jitter) / float(LAYERS);
		vec2 p = d.xz / d.y * (1.0 + k * 0.55) * 1.1;       // where the ray crosses this height
		vec2 q = p * 0.42 + vec2(t, t * 0.37);
		float n = nsFbm2(q + 0.6 * vec2(nsNoise2(q * 0.7 + 3.0), nsNoise2(q * 0.7 - 5.0)));
		float line = 1.0 - clamp(abs(n - 0.5) * 9.0, 0.0, 1.0);   // thin isoline = the curtain
		line *= line * line;
		float rays = 0.55 + 0.45 * nsNoise2(p * 6.0 + vec2(0.0, t * 6.0)); // vertical streaks
		float lower = smoothstep(0.0, 0.12, k);              // soft bottom edge
		float upper = 1.0 - k;                               // curtains thin out with height
		vec3 col = mix(vec3(0.12, 1.0, 0.45), vec3(0.15, 0.75, 0.9), smoothstep(0.15, 0.55, k));
		col = mix(col, vec3(0.62, 0.25, 1.0), smoothstep(0.5, 1.0, k));
		acc += col * line * rays * lower * upper;
	}
	acc /= float(LAYERS);
	acc *= smoothstep(0.0, 0.18, d.y);                     // fade into the horizon haze
	acc *= 0.35 + 0.65 * nsNoise2(d.xz / max(d.y, 0.05) * 0.12 + t * 0.2); // whole curtains brighten / dim
	return acc;
}

// Milky Way: a soft band along a great circle of the celestial sphere, with cloudy structure, dark dust lanes
// along its core and a warmer central glow.
vec3 nsMilkyWay(vec3 c, out float bandAmount) {
	vec3 n = normalize(vec3(0.38, 0.27, 0.88));
	float lat = dot(c, n);
	float band = exp(-lat * lat / (2.0 * 0.13 * 0.13));
	float core = exp(-lat * lat / (2.0 * 0.05 * 0.05));
	bandAmount = band;
	if (band < 0.01) return vec3(0.0);
	float clouds = nsFbm3(c * 4.5);
	float dust = smoothstep(0.48, 0.72, nsFbm3(c * 9.0 + 3.1)) * core;
	float dens = band * (0.25 + 0.75 * clouds * clouds) * (1.0 - 0.8 * dust);
	vec3 col = mix(vec3(0.5, 0.58, 1.0), vec3(1.0, 0.82, 0.68), clamp(core * clouds * 1.3, 0.0, 1.0));
	return col * dens;
}

// Star field, vanilla-sized: square stars of 0.3-0.5 degrees (vanilla draws quads of half-size 0.15-0.25 at a
// distance of 100), one candidate per cell of a 3D grid around the sky sphere, roughly vanilla's count (more
// inside the Milky Way). The grid is coarse enough that a star always sits well inside its own cell — a star
// crossing the cell edge got clipped, and TAA jitter flipped those pixels between cells every frame (strobing).
float nsStars(vec3 c, float density) {
	const float CELLS = 70.0; // cells per unit of direction
	vec3 p = c * CELLS;
	vec3 cell = floor(p);
	vec3 f = p - cell;
	float h = nsHash13(cell);
	if (h > density) return 0.0;
	vec3 starPos = vec3(nsHash13(cell + 1.7), nsHash13(cell + 4.3), nsHash13(cell + 7.9)) * 0.5 + 0.25;
	float halfSize = (0.0015 + 0.001 * nsHash13(cell + 2.9)) * CELLS * length(c);  // in cells: 0.10 - 0.18
	float pixelCells = 2.0 / (gbufferProjection[1][1] * viewHeight) * CELLS * length(c);
	vec3 o = abs(f - starPos);
	float square = max(o.x, max(o.y, o.z));               // square-ish like vanilla's star quads
	float star = 1.0 - smoothstep(halfSize - pixelCells * 0.5, halfSize + pixelCells * 0.5, square);
	float brightness = 0.55 + 0.45 * nsHash13(cell + 9.1);
	float twinkle = 0.88 + 0.12 * sin(frameTimeCounter * (0.6 + 1.2 * nsHash13(cell + 5.5)) + h * 60.0); // gentle
	return star * brightness * twinkle;
}

// [End sky] ILV-CL's End sky (replaces the old flat colour + static noise): a dark void that is darkest at the
// zenith and turns into the End fog colour at the horizon (no seam with fogged terrain), slow drifting nebulae
// with swirled, domain-warped structure in violet / magenta / teal, and a still star field. Uses the End sky
// colour settings: END_SKY = the void, END_STATIC = the nebula base tint, END_FOG = the horizon.
vec3 getEndSky(vec3 d) {
	float up = d.y;
	vec3 col = mix(END_FOG_COLOR, END_SKY_COLOR * 0.5, smoothstep(-0.05, 0.7, up));
	float t = frameTimeCounter * 0.003 * END_NEBULA_SPEED;
	vec3 q = d * 2.1 + vec3(t, 0.0, t * 0.6);
	vec3 warp = vec3(nsFbm3(q + 1.3), nsFbm3(q + 7.1), nsFbm3(q - 4.2)) - 0.5;
	float n = nsFbm3(q * 1.5 + warp * 2.4);
	float nebula = smoothstep(0.42, 0.85, n);
	float wisps = smoothstep(0.58, 0.95, n);
	wisps *= wisps * wisps;
	float hue = nsFbm3(d * 1.2 - 9.0 + t * 0.5);
	vec3 nebulaColor = mix(END_STATIC_COLOR, vec3(0.95, 0.35, 0.8), smoothstep(0.35, 0.15, hue));
	nebulaColor = mix(nebulaColor, vec3(0.25, 0.75, 0.9), smoothstep(0.6, 0.82, hue));
	col += nebulaColor * (nebula * 0.16 + wisps * 0.42) * END_NEBULA_BRIGHTNESS;
	float stars = nsStars(d, 0.08 * NIGHT_STARS_DENSITY);
	col += vec3(0.92, 0.86, 1.0) * stars * (0.55 * END_STARS_BRIGHTNESS) * (1.0 - 0.6 * nebula);
	col = mix(END_FOG_COLOR, col, smoothstep(-0.2, 0.02, up));
	// below the islands there's nothing at all: the void goes BLACK, fading in gradually from just above the
	// horizon (kept in sync with the End fog in getFogColor)
	return col * smoothstep(-0.3, 0.3, up);
}

// All night-sky layers for a view-space direction (0 in daylight, rain, or outside the Overworld).
vec3 getNightSkyLayers(vec3 viewDir) {
	#ifdef OVERWORLD
		float night = clamp(1.0 - dayPercent, 0.0, 1.0);
		night *= night * (1.0 - rainStrength);
		if (night < 0.001) return vec3(0.0);
		vec3 d = normalize(mat3(gbufferModelViewInverse) * viewDir);
		float aboveHorizon = smoothstep(-0.03, 0.08, d.y);
		if (aboveHorizon <= 0.0) return vec3(0.0);
		vec3 c = nsCelestial(d);
		vec3 result = vec3(0.0);
		float band = 0.0;
		#if MILKY_WAY_ENABLED == 1
			result += nsMilkyWay(c, band) * (0.07 * MILKY_WAY_BRIGHTNESS);
		#endif
		#if NIGHT_STARS_ENABLED == 1
			float starDensity = (0.06 + 0.12 * band) * NIGHT_STARS_DENSITY;
			result += vec3(0.9, 0.93, 1.0) * nsStars(c, starDensity) * (0.5 * NIGHT_STARS_BRIGHTNESS);
		#endif
		#if AURORA_ENABLED == 1
			float auroraAmount = AURORA_BRIGHTNESS * 0.45;
			#if AURORA_COLD_BIOMES_ONLY == 1
				auroraAmount *= float(biome_precipitation == 2);
			#endif
			if (auroraAmount > 0.0) result += nsAurora(d) * auroraAmount;
		#endif
		return result * night * aboveHorizon;
	#else
		return vec3(0.0);
	#endif
}

#endif
