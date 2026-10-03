// View-space ray march. Compares positions in linear VIEW space, keeping full precision at
// ALL distances — including geometry beyond vanilla `far` (DH LODs). Returns `hitFade` in
// [0,1]: a smooth confidence (not a hard hit/miss) so there is no sharp accept/reject line.
void raytrace(out vec2 reflectionPos, out float hitFade, vec3 viewPos, vec3 reflectionDir, vec3 normal) {
	reflectionPos = vec2(0.5);
	hitFade = 0.0;

	float dither = bayer64(gl_FragCoord.xy);
	#if TEMPORAL_FILTER_ENABLED == 1
		dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
	#endif

	float lViewPos = length(viewPos);
	vec3 start = viewPos + normal * (lViewPos * 0.025 + 0.05);
	vec3 stepVec = reflectionDir * 0.5;
	vec3 tVec = stepVec;

	int sr = 0;
	vec3 sp = vec3(0.5);
	vec3 geoView = vec3(0.0);
	float err = 1.0e9;
	bool sampledGeo = false;

	for (int i = 0; i < 64; i++) {
		vec3 rayPos = start + tVec;
		sp = mult(gbufferProjection, rayPos) * 0.5 + 0.5;
		if (sp.x < 0.0 || sp.x > 1.0 || sp.y < 0.0 || sp.y > 1.0) break;

		// texture2DLod(…, 0): depth buffers have no mips, so this is bit-identical to texture2D but
		// skips the implicit derivative/LOD calculation — a real cost inside a divergent 64-step loop.
		float gDepth = texture2DLod(DEPTH_BUFFER_WO_TRANS_OR_HANDHELD, sp.xy, 0.0).r;
		sampledGeo = gDepth < 1.0;
		geoView = screenToView(vec3(sp.xy, gDepth));
		#ifdef DISTANT_HORIZONS
			if (gDepth >= 1.0) {
				float gDepthDh = texture2DLod(DH_DEPTH_BUFFER_WO_TRANS, sp.xy, 0.0).r;
				if (gDepthDh < 1.0) {
					geoView = screenToViewDh(vec3(sp.xy, gDepthDh));
					sampledGeo = true;
				}
			}
		#endif

		err = length(rayPos - geoView);
		if (err * 0.333 < length(stepVec)) {
			sr++;
			if (sr >= 8) break;
			tVec -= stepVec;
			stepVec *= 0.2;
		}
		stepVec *= 1.7;
		tVec += stepVec * (0.95 + 0.1 * dither);
	}

	if (!sampledGeo) return;
	if (sp.x < 0.0 || sp.x > 1.0 || sp.y < 0.0 || sp.y > 1.0) return;

	float lRay = length(geoView);
	if (lRay - lViewPos < -2.0) return;

	float errThresh = 1.0 + lRay * 0.25;
	hitFade = 1.0 - smoothstep(errThresh * 0.4, errThresh, err);

	float borderDist = min(min(sp.x, 1.0 - sp.x), min(sp.y, 1.0 - sp.y));
	hitFade *= smoothstep(0.0, 0.12, borderDist);

	float depthWithHandheld = texture2DLod(DEPTH_BUFFER_ALL, sp.xy, 0.0).r;
	if (depthIsHand(depthWithHandheld) && dot(viewPos, viewPos) > 2.5 + dither) hitFade = 0.0;

	reflectionPos = sp.xy;
}



// Sky-only reflection (no geometry raymarch) — for forward use on glass/ice in gbuffers_water.
// The SSR march runs on OPAQUE depth, so from a translucent surface it "sees through" water and
// nearby geometry and lands on false hits (naked lakebed, landscape on water). Glass looks right
// with just the atmospheric background + sun/moon sparkle, with zero false-hit artifacts.
void addSkyReflection(inout vec3 color, vec3 viewPos, vec3 normal, vec2 lmcoord, float reflectionStrength) {
	vec3 reflectionDirection = reflect(normalize(viewPos), normalize(normal));

	float fresnel = 1.0 - abs(dot(normalize(viewPos), normal));
	fresnel *= fresnel;
	fresnel *= fresnel;
	reflectionStrength *= 1.0 - REFLECTION_FRESNEL * (1.0 - fresnel);

	vec3 background = getSkyColor(reflectionDirection, true);
	if (isEyeInWater == 0) {
		vec3 lightDir = normalize(shadowLightPosition);
		float spec = max(dot(normalize(reflectionDirection), lightDir), 0.0);
		spec = pow(spec, 200.0);
		vec3 lightCol = sunAngle < 0.5 ? vec3(1.0, 0.95, 0.8) : vec3(0.55, 0.7, 1.0);
		background += spec * lightCol * (sunLightBrightness + moonLightBrightness) * 3.0;
	}

	float maxBrightness = max(lmcoord.x * 0.75, lmcoord.y);
	#ifdef END
		maxBrightness = 0.5 + 0.5 * lmcoord.x;
	#endif
	background *= maxBrightness * maxBrightness;
	if (isEyeInWater == 1) {
		background = mix(color * 0.5, background, lmcoord.y * lmcoord.y);
		background += vec3(0.0, 0.02, 0.06);
	}

	color = mix(color, background, reflectionStrength);
}



void addReflection(inout vec3 color, vec3 viewPos, vec3 normal, vec2 lmcoord, sampler2D texture, float reflectionStrength) {
	
	vec3 reflectionDirection = reflect(normalize(viewPos), normalize(normal));
	vec2 reflectionPos;
	float hitFade;
	raytrace(reflectionPos, hitFade, viewPos, reflectionDirection, normal);

	float fresnel = 1.0 - abs(dot(normalize(viewPos), normal));
	fresnel *= fresnel;
	fresnel *= fresnel;
	reflectionStrength *= 1.0 - REFLECTION_FRESNEL * (1.0 - fresnel);

	// ===== Atmospheric background reflection =====
	// Base: directional sky (already includes horizon gradient + sun glow).
	vec3 background = getSkyColor(reflectionDirection, true);

	// The sky-sample and sun/moon specular only make sense above water — underwater there is no sky
	// or sun to reflect, and applying them tinted the reflections white. Skip them when submerged;
	// the SSR below then reflects the scene exactly like on the surface.
	if (isEyeInWater == 0) {
		// Sample the REAL rendered sky where the reflection ray points at on-screen sky. This is what
		// removes the hard SSR→sky line (the background now matches the actual sky). NOTE: the far point
		// sits at infinity in the reflected direction, so it projects to the ray's VANISHING point — the
		// empty sky ABOVE the cloud layer — which is why this sample alone never caught clouds. Clouds are
		// handled by the cloud-plane intersection below, which lands on where the cloud actually is.
		vec3 farPoint = viewPos + reflectionDirection * (far * 2.0 + 64.0);
		vec3 skySp = mult(gbufferProjection, farPoint) * 0.5 + 0.5;
		if (skySp.x >= 0.0 && skySp.x <= 1.0 && skySp.y >= 0.0 && skySp.y <= 1.0) {
			float sd = texture2DLod(DEPTH_BUFFER_WO_TRANS_OR_HANDHELD, skySp.xy, 0.0).r;
			bool sdSky = sd >= 1.0;
			#ifdef DISTANT_HORIZONS
				float sdDh = texture2DLod(DH_DEPTH_BUFFER_WO_TRANS, skySp.xy, 0.0).r;
				sdSky = sdSky && sdDh >= 1.0;
			#endif
			if (sdSky) {
				// The 253/255 no-reflect tag rejects tagged overlays (particles, held items, mod UI)
				// drawn over the sky so they don't bleed into the reflection.
				float skySpec = unpack_2x8(texelFetch(OPAQUE_DATA_TEXTURE, ivec2(skySp.xy * viewSize), 0).y).y;
				if (abs(skySpec - 252.5 / 255.0) >= 0.004) background = texture2DLod(texture, skySp.xy, 0.0).rgb * 2.0;
			}
		}

		// Sun / moon specular highlight — bright sparkle that bridges SSR and sky smoothly.
		vec3 lightDir = normalize(shadowLightPosition);
		float spec = max(dot(normalize(reflectionDirection), lightDir), 0.0);
		spec = pow(spec, 200.0);
		vec3 lightCol = sunAngle < 0.5 ? vec3(1.0, 0.95, 0.8) : vec3(0.55, 0.7, 1.0);
		background += spec * lightCol * (sunLightBrightness + moonLightBrightness) * 3.0;
	}

	float maxBrightness = max(lmcoord.x * 0.75, lmcoord.y);
	#ifdef END
		maxBrightness = 0.5 + 0.5 * lmcoord.x;
	#endif
	background *= maxBrightness * maxBrightness;
	if (isEyeInWater == 1) {
		// underwater there's no sky to reflect, so the "miss" background falls back to a
		// dimmed version of the surface's OWN colour, weighted by sky access (lmcoord.y). Near the
		// surface (some sky access) you still get a little sky; deep down it's just the surroundings'
		// colour. The reflection is never brighter or "skier" than what's actually around → no white.
		background = mix(color * 0.5, background, lmcoord.y * lmcoord.y);
		background += vec3(0.0, 0.02, 0.06); // faint water tint
	}

	vec3 reflectionColor = background;
	if (hitFade > 0.0) {
		// Overlay rejection: tagged (253/255 no-reflect sentinel) pixels — particles, held items,
		// nametags, mod UI — drop the SSR and fall back to the background.
		float hitSpec = unpack_2x8(texelFetch(OPAQUE_DATA_TEXTURE, ivec2(reflectionPos * viewSize), 0).y).y;
		if (abs(hitSpec - 252.5 / 255.0) < 0.004) hitFade = 0.0; // 253 no-reflect + 252 fullbright (enchanted held items)

		// `texture` is the caller's scene source (composite4 passes the final image, colortex0).
		vec3 ssr = texture2DLod(texture, reflectionPos, 0.0).rgb * 2.0;
		float reflectionDepth = texelFetch(DEPTH_BUFFER_WO_TRANS, ivec2(reflectionPos * viewSize), 0).r;
		ssr *= REFLECTIONS_BRIGHTNESS - (REFLECTIONS_BRIGHTNESS - 1.0) * step(1.0, reflectionDepth);
		// hitFade (smooth confidence + screen-border fade) blends SSR into the matching
		// background → no hard line, soft silhouette edges. Underwater the SSR is identical to the
		// surface (it reflects the rendered scene), so reflected blocks keep their real colour.
		reflectionColor = mix(background, ssr, hitFade);
	}
	color = mix(color, reflectionColor, reflectionStrength);

}
