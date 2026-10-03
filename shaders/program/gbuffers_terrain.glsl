in_out vec2 texcoord;
in_out vec2 lmcoord;
in_out vec3 glcolor;
in_out float ao;
in_out float upDot;
#if PBR_TYPE == 0 && POM_ENABLED == 0
	flat in_out vec3 normal;
	flat in_out vec2 encodedNormal;
#endif
#if PBR_TYPE == 1 || POM_ENABLED == 1
	flat in_out mat3 tbn;
	flat in_out mat3 rawTbn;
#endif
in_out vec3 playerPos;
#if POM_ENABLED == 1
	in_out vec3 viewPos;
	flat in_out vec2 midTexCoord;
	flat in_out vec2 midCoordOffset;
#endif
flat in_out uint materialId;
#if PBR_TYPE == 0
	flat in_out float reflectiveness;
	flat in_out float specularness;
#endif

#if EMISSIVE_TEXTURES_ENABLED == 1
	in_out vec3 glowingColorMin;
	in_out vec3 glowingColorMax;
	in_out float glowingAmount;
	// tile-local UV for the embedded zinc glow mask (colortex15)
	flat in_out vec2 zincMid;
	flat in_out vec2 zincOffset;
#endif

#if SHOW_DANGEROUS_LIGHT == 1
	flat in_out float isDangerousLight;
#endif



#ifdef FSH

void main() {
	vec2 lmcoord = lmcoord;
	
	
	// fade distant terrain — exponential curve, matched with dh_terrain.
	// Vanilla keeps where dither<=fog (near=solid), discards approaching far.
	#ifdef DISTANT_HORIZONS
		float dither = bayer64(gl_FragCoord.xy);
		#if TEMPORAL_FILTER_ENABLED == 1
			dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
		#endif
		float fog = max(length(playerPos.xz), abs(playerPos.y)) / far;
		fog = pow2(pow2(pow2(pow2(fog))));
		fog = exp(-3.0 * fog);
		if (dither > fog) discard;
	#elif defined VOXY
		
	#elif CYLINDRICAL_CLIPPING == 1
		float dither = bayer64(gl_FragCoord.xy);
		//#include "/utils/var_rng.glsl"
		//float dither = randomFloat(rng) * 0.5 + 0.5;
		#if TEMPORAL_FILTER_ENABLED == 1
			dither = fract(dither + 1.61803398875 * mod(float(frameCounter), 3600.0));
		#endif
		float fogDistance = max(length(playerPos.xz), abs(playerPos.y));
		fogDistance += dither * 4.0;
		fogDistance *= invFar;
		if (fogDistance >= BORDER_FOG_END - 0.01) {discard; return;}
	#endif
	
	
	// get pbr data
	
	#if POM_ENABLED == 1
		float pomDither = bayer64(gl_FragCoord.xy);
		pomDither = fract(pomDither + 1.61803398875 * mod(float(frameCounter), 3600.0)) * 0.25;
		// setup
		vec2 texStart = midTexCoord - midCoordOffset;
		vec2 texEnd = midTexCoord + midCoordOffset;
		vec2 inBlockCoord = percentThrough(texcoord, texStart, texEnd);
		vec2 texcoord = texcoord;
		vec3 tangentViewDir = normalize(transpose(rawTbn) * viewPos);
		tangentViewDir.y *= -1.0;
		tangentViewDir /= 256 / 32.0 * POM_QUALITY;
		tangentViewDir.z *= 10.0 / POM_DEPTH;
		// step through texture & search for hit
		float pomDepth = 0.0;
		vec4 normalAndDepth = vec4(1.0);
		float prevDepth;
		inBlockCoord += tangentViewDir.xy * pomDither;
		pomDepth -= tangentViewDir.z * pomDither;
		for (int i = 0; i < POM_QUALITY; i++) {
			prevDepth = normalAndDepth.a;
			normalAndDepth = texture2D(normals, texcoord);
			if (1.0 - normalAndDepth.a <= pomDepth) break;
			inBlockCoord += tangentViewDir.xy;
			pomDepth -= tangentViewDir.z;
			texcoord = mix(texStart, texEnd, fract(inBlockCoord));
		}
		// final processing
		vec3 normal = vec3(normalAndDepth.xy, 0.0);
		normal.xy -= 0.5;
		normal.xy *= PBR_NORMALS_AMOUNT * 0.5;
		normal.xy += 0.5;
		normal.z = sqrt(1.0 - dot(normal.xy, normal.xy));
		normal = normalize(normal * 2.0 - 1.0);
		//if (prevDepth != normalAndDepth.a) { // if hit edge instead of surface
		//	ivec2 currPixelCoord = ivec2(mix(texStart, texEnd, inBlockCoord) * textureSize(normals, 0));
		//	ivec2 prevPixelCoord = ivec2(mix(texStart, texEnd, inBlockCoord - tangentViewDir.xy) * textureSize(normals, 0));
		//	if (currPixelCoord.x != prevPixelCoord.x) {
		//		normal = vec3(currPixelCoord.x - prevPixelCoord.x, 0.0, 0.0);
		//	} else if (currPixelCoord.y != prevPixelCoord.y) {
		//		normal = vec3(0.0, currPixelCoord.y - prevPixelCoord.y, 0.0);
		//	}
		//}
	#endif
	
	#if PBR_TYPE == 0
		float reflectiveness = reflectiveness;
	#elif PBR_TYPE == 1
		vec2 pbrData = texture2D(specular, texcoord).rg;
		float reflectiveness = pbrData.g;
		// [upstream I-Like-Vanilla v1.4.5] labPBR metal fix: F0 values 230-255 are a metal-type
		// index, not a reflectance, so using pbrData.g raw made metals near-mirror ("too reflective").
		if (int(reflectiveness * 255.0 + 0.5) > 229) reflectiveness -= 175.0 / 255.0;
		reflectiveness *= 0.5;
		float specularness = sqrt(pbrData.r);
		#if POM_ENABLED == 0
			vec3 normal = vec3(texture2D(normals, texcoord).rg, 0.0);
			normal.xy -= 0.5;
			normal.xy *= PBR_NORMALS_AMOUNT * 0.5;
			normal.xy += 0.5;
			normal.z = sqrt(1.0 - dot(normal.xy, normal.xy));
			normal = normalize(normal * 2.0 - 1.0);
		#endif
	#endif
	
	#if PBR_TYPE == 1 || POM_ENABLED == 1
		normal = tbn * normal;
		vec2 encodedNormal = encodeNormal(normal);
	#endif
	
	reflectiveness *= mix(BLOCK_REFLECTION_AMOUNT_SURFACE, BLOCK_REFLECTION_AMOUNT_UNDERGROUND, lmcoord.y);
	
	
	// get texture color
	vec4 rawColor = texture2D(MAIN_TEXTURE, texcoord);
	if (rawColor.a < alphaTestRef) discard;
	
	vec4 color = rawColor;
	color.rgb *= glcolor;
	color.rgb = color.rgb - (4.0 / 27.0) * color.rgb * color.rgb * color.rgb;
	
	float m = getLum(color.rgb);
	m = m * m * (3.0 - 2.0 * m);
	color.rgb *= 1.0 - TEXTURE_CONTRAST * 0.125 + m * TEXTURE_CONTRAST * 0.25;
	
	color.rgb = mix(vec3(getLum(color.rgb)), color.rgb, 1.0 + (1.0 - ao) * 0.25);
	
	#if POM_ENABLED == 1
		color.rgb *= 1.0 - 0.1 * float(prevDepth != normalAndDepth.a);
		color.rgb *= 1.0 - pomDepth;
	#endif
	
	
	// misc
	
	#if PBR_TYPE == 0
		reflectiveness *= 1.0 - 0.5 * getSaturation(rawColor.rgb);
	#endif
	
	#if EMISSIVE_TEXTURES_ENABLED == 1
		float specularness = specularness;
		vec3 hsv = rgbToHsv(rawColor.rgb);
		if (all(greaterThan(hsv, glowingColorMin)) && all(lessThan(hsv, glowingColorMax))) {
			specularness = 254.0 / 255.0;
			reflectiveness = clamp(glowingAmount * 0.5, 0.0, 1.0);
		}
		// [soul lantern/torch] some animation frames have PURE-WHITE hottest core texels (sat~0, val 100)
		// that the cyan HSV box can't catch (undefined hue). Add them by brightness: any near-white,
		// very-bright texel glows. The bluish soul frame is dark (val<=39) and saturated, so it's excluded.
		if (materialId == BLOCK_ID_SOUL_LANTERN && getLum(rawColor.rgb) > 0.9 && getSaturation(rawColor.rgb) < 0.15) {
			specularness = 254.0 / 255.0;
			reflectiveness = clamp(0.4 * 0.5, 0.0, 1.0);
		}
		// [activated redstone wire] Power isn't in the (grayscale) dust texture — MC tints it red via the
		// vertex colour, so glcolor.r rises with power (~0.34 at power 1, ~1.0 at power 15; excluded from
		// the foliage tint in the VSH). Glow the wire red IN PROPORTION to power, so a stronger signal
		// reads brighter. Only lit wire reaches here (BLOCK_ID_REDSTONE_WIRE = power 1-15).
		if (materialId == BLOCK_ID_REDSTONE_WIRE) {
			float rsPower = clamp((glcolor.r - 0.32) / 0.68, 0.0, 1.0);
			specularness = 254.0 / 255.0;
			reflectiveness = clamp(rsPower * 0.5, 0.0, 1.0);
		}
		// [redstone torch heads] Standalone redstone torch AND every redstone DEVICE (repeater/comparator/
		// Create & addons) share CR's exact detection so their heads look identical. A texel glows if it's
		// pure-red-ish (r high, green ~= blue) AND is either NON-grey (maxDif > 0.125 -> the red parts) OR
		// near-pure-white (b > 0.99 -> the white-hot torch CENTRE). The b>0.99 half is the key: it lights the
		// bright centre while the dimmer white device FRAMES (b < 0.99, grey) stay dark.
		// Torch heads glow only on VANILLA redstone (standalone torch + repeater/comparator): pure-red-ish
		// texels (r high, g~=b) that are either non-grey (red parts) or near-pure-white (b>0.99 -> the
		// white-hot torch CENTRE). The Create/addon devices are floodfill-ONLY — their red displays and
		// indicators can't be told from a torch head by colour, so any surface detection lit them up; they
		// still cast red floodfill (BLOCK_ID_CREATE_REDSTONE voxelised), just with no fullbright pixels.
		vec3 rsAbsDif = abs(vec3(rawColor.r - rawColor.g, rawColor.g - rawColor.b, rawColor.r - rawColor.b));
		float rsMaxDif = max(rsAbsDif.r, max(rsAbsDif.g, rsAbsDif.b));
		if ((materialId == BLOCK_ID_REDSTONE_TORCH || materialId == BLOCK_ID_REDSTONE_DEVICE)
			&& (rsMaxDif > 0.125 || rawColor.b > 0.99)
			&& rawColor.r > 0.55 && abs(rawColor.g - rawColor.b) < 0.12) {
			specularness = 254.0 / 255.0;
			reflectiveness = clamp((3.5 - 2.25 * rawColor.g) * 0.3, 0.0, 1.0);
		}
		// [sculk shrieker souls] Detect the glowing inner souls the way Complementary does — an HSV box
		// only caught stray texels. Skip the bone-white rim (r >> b), then glow the green/cyan-dominant
		// soul texels (g > r), with a strong boost at the CENTRE of the block's top face (the soul hole).
		if (materialId == BLOCK_ID_SCULK_SHRIEKER) {
			float boneFactor = max(rawColor.r * 1.25 - rawColor.b, 0.0);
			if (boneFactor < 0.0001) {
				float soulEmit = pow2(max(rawColor.g - rawColor.r, 0.0)) * 2.0;
				vec2 coordFactor = abs(fract(playerPos.xz + cameraPosition.xz) - 0.5);
				if (max(coordFactor.x, coordFactor.y) < 0.43) soulEmit += rawColor.g * 7.0;
				if (soulEmit > 0.01) {
					specularness = 254.0 / 255.0;
					reflectiveness = clamp(soulEmit * 0.5, 0.0, 1.0);
				}
			}
		}
		// Zinc ore: dedicated emissive mask embedded in the shader (colortex15 = zinc_glow.png),
		// sampled with tile-local UV. Color detection can't separate zinc's pale speckles from
		// stone, so this uses a baked positional mask. White = glow, black = no glow.
		if (materialId == BLOCK_ID_ZINC_ORE) {
			vec2 zincLocalUV = percentThrough(texcoord, zincMid - zincOffset, zincMid + zincOffset);
			if (texture2D(colortex15, zincLocalUV).r > 0.5) {
				specularness = 254.0 / 255.0;
				reflectiveness = clamp(GLOWING_ORES_STRENGTH * GLOWING_ZINC_ORE_STRENGTH * 0.5, 0.0, 1.0);
			}
		}
		// Campfire / furnace flame. The brown LOGS and the orange FLAME share the same
		// hue, so HSV can't tell them apart; use the red-green gap + brightness instead. Brown
		// wood has r≈g and is dim (isLog) → never glows. The orange flame has r>>g or is bright →
		// glows. (Stone furnace body is grey r≈g≈b and dim → also never glows.)
		if (materialId == BLOCK_ID_CAMPFIRE) {
			vec3 c = rawColor.rgb;
			float dotC = dot(c, c);
			bool isLog = c.r > c.b && c.r - c.g < 0.15 && dotC < 1.4;
			if (!isLog && (c.r > c.b || dotC > 2.9)) {
				specularness = 254.0 / 255.0;
				reflectiveness = clamp(0.7 * 0.5, 0.0, 1.0); // flame glow amount (scaled by EMISSIVE_BRIGHTNESS later)
			}
		}
		// Soul campfire — variant for the cyan soul flame: brown logs (r>b) never glow; the
		// cyan flame (green dominant, g>r) or anything very bright glows.
		if (materialId == BLOCK_ID_SOUL_CAMPFIRE) {
			vec3 c = rawColor.rgb;
			float dotC = dot(c, c);
			bool isLog = c.r > c.b;
			if (!isLog && (c.g - c.r > 0.1 || dotC > 2.9)) {
				specularness = 254.0 / 255.0;
				reflectiveness = clamp(0.6 * 0.5, 0.0, 1.0);
			}
		}
		// Salt ore (Expanded Delight): same as zinc — neutral-white speckles can't be colour-detected,
		// so a baked positional mask (colortex14 = salt_glow.png) sampled with tile-local UV. White = glow.
		if (materialId == BLOCK_ID_SALT_ORE) {
			vec2 saltLocalUV = percentThrough(texcoord, zincMid - zincOffset, zincMid + zincOffset);
			if (texture2D(colortex14, saltLocalUV).r > 0.5) {
				specularness = 254.0 / 255.0;
				reflectiveness = clamp(GLOWING_ORES_STRENGTH * GLOWING_SALT_ORE_STRENGTH * 0.5, 0.0, 1.0);
			}
		}
	#endif

	// [glow lichen] It's an emitter decal, not a shiny surface.
	if (materialId == BLOCK_ID_GLOW_LICHEN) {
		if (abs(specularness - 254.0 / 255.0) < 0.001) {
			// the brightest emissive dots: push toward warm white and lift them so they read as bright
			// near-white specks (still below fullbright — glow amount 0.5 keeps them from blowing out).
			float clLum = getLum(color.rgb);
			color.rgb = mix(color.rgb, vec3(clLum), 0.65);
			color.rgb *= 1.4;
		} else {
			// DIM (non-glowing) texels keep a default reflectiveness; the forced-up normal makes them all
			// catch the overhead sun/moon specular at one angle (hardcoded cool-blue at night). Kill it so
			// the lichen never mirrors the cool night sky.
			reflectiveness = 0.0;
		}
	}

	#if LAVA_NOISE_ENABLED == 1
		if (materialId == BLOCK_ID_LAVA) {
			vec2 worldPos2 = playerPos.xz + cameraPosition.xz + playerPos.y + cameraPosition.y;
			worldPos2 += worldPos2.yx * 0.125;
			float noise = 1.4;
			noise -= valueNoise(vec3(worldPos2 * 0.125, frameTimeCounter * 0.125)) * 0.5;
			worldPos2 += 128.0;
			noise -= valueNoise(vec3(worldPos2 * 0.25 , frameTimeCounter * 0.125)) * 0.25;
			worldPos2 += 128.0;
			noise -= valueNoise(vec3(worldPos2 * 1.0  , frameTimeCounter * 0.125)) * 0.125;
			#ifdef OVERWORLD
				const float halfStrength = LAVA_NOISE_AMOUNT_OVERWORLD * 0.3;
			#elif defined NETHER
				const float halfStrength = LAVA_NOISE_AMOUNT_NETHER * 0.3;
			#elif defined END
				const float halfStrength = LAVA_NOISE_AMOUNT_END * 0.3;
			#endif
			noise = mix(1.0, noise * noise * noise, halfStrength + halfStrength * upDot);
			color.rgb *= noise;
		}
	#endif
	
	color.rgb *= 1.0 - upDot * 0.125 * SIDE_SHADING_BRIGHT * float(materialId == BLOCK_ID_PUMPKIN);
	
	#if SHOW_DANGEROUS_LIGHT == 1
		if (isDangerousLight > 0.0) {
			vec3 blockPos = fract(playerPos + cameraPosition);
			float centerDist = length(blockPos.xz - 0.5);
			vec3 indicatorColor = isDangerousLight > 0.75 ? vec3(1.0, 0.0, 0.0) : vec3(1.0, 1.0, 0.0);
			color.rgb = mix(color.rgb, indicatorColor, 0.35 * float(centerDist < 0.45));
			lmcoord.x = max(lmcoord.x, 0.1 * float(centerDist < 0.45));
		}
	#endif
	
	
	/* DRAWBUFFERS:02 */
	#if DO_COLOR_CODED_GBUFFERS == 1
		color = vec4(0.75, 0.75, 0.75, 1.0);
	#endif
	color.rgb *= 0.5;
	gl_FragData[0] = vec4(color);
	gl_FragData[1] = vec4(
		pack_2x8(lmcoord),
		pack_2x8(reflectiveness, specularness),
		encodedNormal
	);
	
}

#endif



#ifdef VSH

#include "/utils/projections.glsl"
#include "/lib/lighting/vsh_lighting.glsl"

#if WAVING_ENABLED == 1
	#include "/lib/waving.glsl"
#endif
#if TAA_ENABLED == 1
	#include "/lib/taa_jitter.glsl"
#endif

// [CL rewrite] Voxelise colour-light emitters HERE in the terrain gbuffers pass (ALL dimensions), so
// coloured lighting no longer depends on the sun shadow pass — it works with real-time shadows OFF and
// in the sunless Nether/End alike. The floodfill runs in worldN/deferred1.csh (a compute AFTER gbuffers)
// so it reads these fresh voxels the same frame. In the Overworld the shadow pass ALSO voxelises when
// shadows are on (bonus off-screen coverage); with shadows off, this gbuffers path is the only voxeliser.
// NOTE: updateVoxelIds.glsl leaves GET_VOXEL_ID #defined, which would corrupt the reflectiveness
// blockDatas include below — #undef it right after.
#if COLORED_LIGHTING_ENABLED == 1
	#define CL_COPYCAT // copycat light-material detection (needs the atlas + mc_midTexCoord, see updateVoxelIds)
	#include "/lib/colored_lighting/updateVoxelIds.glsl"
	#undef GET_VOXEL_ID
#endif
//vec2 Project3DPointTo2D(vec3 point, vec3 planeOrigin, vec3 planeNormal) {
//	// Step 1: Project the point onto the plane
//	vec3 toPoint = point - planeOrigin;
//	vec3 normal = normalize(planeNormal);
//	vec3 projected = point - dot(toPoint, normal) * normal;

//	// Step 2: Create 2D basis vectors (u and v) on the plane
//	vec3 x = cross(normal, vec3(0.0, 1.0, 0.0));
//	if (dot(x, x) < 0.001) x = cross(normal, vec3(1.0, 0.0, 0.0));
//	x = normalize(x);
//	vec3 y = cross(normal, x);

//	// Step 3: Get 2D coordinates
//	vec3 relative = projected - planeOrigin;
//	return vec2(dot(relative, x), dot(relative, y));
//}

void main() {
	// get basics
	texcoord = (gl_TextureMatrix[0] * gl_MultiTexCoord0).xy;
	lmcoord  = (gl_TextureMatrix[1] * gl_MultiTexCoord1).xy;
	adjustLmcoord(lmcoord);
	vec4 glcolor4 = gl_Color;
	
	#if POM_ENABLED != 1
		vec3 viewPos;
	#endif
	viewPos = transform(gl_ModelViewMatrix, gl_Vertex.xyz);
	playerPos = transform(gbufferModelViewInverse, viewPos);
	
	#if POM_ENABLED == 1
		midTexCoord = mat2(gl_TextureMatrix[0]) * mc_midTexCoord;
		midCoordOffset = abs(texcoord - midTexCoord);
	#endif

	#if EMISSIVE_TEXTURES_ENABLED == 1
		zincMid = mat2(gl_TextureMatrix[0]) * mc_midTexCoord;
		zincOffset = abs(texcoord - zincMid);
	#endif
	
	
	// block id stuff (decoded before the glcolor tint below, which needs materialId)
	uint encodedData = uint(mc_Entity.x + 0.5);
	encodedData *= uint((encodedData & (1u << 14u)) > 0u && encodedData != 65535u);
	materialId = encodedData;
	materialId &= (1u << 10u) - 1u;

	// [CL rewrite] voxelise this block for the colour-light volume, every dimension (see note above)
	#if COLORED_LIGHTING_ENABLED == 1
		updateVoxelIds(playerPos, materialId); // every vertex: partial-block votes (ids are written once per quad inside)
	#endif


	bool isFoliage = (encodedData & (3u << 12u)) >= (2u << 12u);
	bool isFlatShaded = (encodedData & (3u << 12u)) >= (1u << 12u);


	// start processing glcolor (foliage tint). Biome-tinted foliage carries a SATURATED vertex colour
	// (the green/etc. biome grass colour); plain AO/face-shading only ever multiplies white by a grey
	// scalar, so it stays fully desaturated. The old "glcolor != white" test wrongly caught that grey
	// shade — most visibly on MOVING Create contraptions (Flywheel bakes shade into the vertex colour,
	// so they came out green / flickered green). Gate on saturation instead: grey shade (sat 0) is
	// left alone, real biome tint (sat > 0) still gets recoloured. Still also skip Sophisticated's
	// dyed models, whose tint IS saturated but isn't foliage.
	bool isDyedModded = (materialId == BLOCK_ID_SOPHISTICATED_SOLID || materialId == BLOCK_ID_SOPHISTICATED_PARTIAL);
	// Activated redstone wire carries a SATURATED red vertex colour that encodes POWER (dark->bright red);
	// the foliage-tint path would desaturate/re-tint it, destroying the power signal we read in the FSH.
	isDyedModded = isDyedModded || (materialId == BLOCK_ID_REDSTONE_WIRE);
	if (getSaturation(glcolor4.rgb) > 0.05 && !isDyedModded) {
		glcolor4.rgb = mix(vec3(getLum(glcolor4.rgb)), glcolor4.rgb, FOLIAGE_SATURATION);
		glcolor4.rgb *= vec3(FOLIAGE_TINT_RED, FOLIAGE_TINT_GREEN, FOLIAGE_TINT_BLUE);
		#if SNOWY_TWEAKS_ENABLED == 1
			if (inSnowyBiome > 0.0) {
				float snowiness = (0.9 + 0.1 * wetness) * inSnowyBiome / (1.0 + 0.00390625 * length(playerPos)) * lmcoord.y * lmcoord.y;
				glcolor4.rgb = mix(glcolor4.rgb, vec3(1.0, 1.05, 1.2), snowiness);
				glcolor4.rgb *= 1.0 + 0.4 * snowiness;
				glcolor4.a = mix(glcolor4.a, 1.0, snowiness * 0.5);
			}
		#endif
	}
	
	
	// process normals
	
	#if !(PBR_TYPE == 0 && POM_ENABLED == 0)
		vec3 normal;
	#endif
	normal = gl_NormalMatrix * gl_Normal;
	
	#if PBR_TYPE == 0
		// foliage normals
		#if OVERRIDE_FOLIAGE_NORMALS == 1
			if (isFlatShaded) {
				//normal = normalize(mix(normal, gl_NormalMatrix * vec3(0.0, 1.0, 0.0), 0.75));
				normal = gl_NormalMatrix * vec3(0.0, 1.0, 0.0);
			}
		#endif
		// [glow lichen] It's a flat, light-emitting decal that can sit on any face. Its geometry normal
		// points OUT of that face (sideways on walls, down on ceilings), so directional side-shading
		// darkens every placement except the top. As an emitter it should read uniformly bright, so force
		// its normal fully up on ALL faces — unconditionally, since OVERRIDE_FOLIAGE_NORMALS defaults off.
		if (materialId == BLOCK_ID_GLOW_LICHEN) {
			normal = gl_NormalMatrix * vec3(0.0, 1.0, 0.0);
		}
	#endif
	
	#if PBR_TYPE == 0 && POM_ENABLED == 0
		encodedNormal = encodeNormal(normal);
	#endif
	
	#if PBR_TYPE == 1 || POM_ENABLED == 1
		vec3 tangent = normalize(gl_NormalMatrix * at_tangent.xyz);
		vec3 bitangent = normalize(cross(normal, tangent) * at_tangent.w);
		tbn = mat3(tangent, bitangent, normal);
		rawTbn = tbn;
		#if OVERRIDE_FOLIAGE_NORMALS == 1
			if (isFlatShaded) {
				tbn = mat3(gbufferModelView[0].xyz, gbufferModelView[2].xyz, gbufferModelView[1].xyz);
			}
		#endif
		// [glow lichen] force up-normal on all faces (see PBR_TYPE==0 branch above for why)
		if (materialId == BLOCK_ID_GLOW_LICHEN) {
			tbn = mat3(gbufferModelView[0].xyz, gbufferModelView[2].xyz, gbufferModelView[1].xyz);
		}
	#endif
	
	
	// finish processing glcolor (ao)
	upDot = dot(normal, gbufferModelView[1].xyz);
	ao = 1.0 - glcolor4.a;
	ao *= mix(VANILLA_AO_DARK, VANILLA_AO_BRIGHT, max(lmcoord.x, lmcoord.y));
	//ao *= 15.0/16.0 + abs(upDot) / 16.0;
	ao = 1.0 - ao;
	
	glcolor = glcolor4.rgb * ao;
	
	
	// get block data
	#if PBR_TYPE == 0
		#define GET_REFLECTIVENESS
		#define GET_SPECULARNESS
	#endif
	#define DO_BRIGHTNESS_TWEAKS
	#if EMISSIVE_TEXTURES_ENABLED == 1
		#define GET_GLOWING_COLOR
	#endif
	#include "/generated/blockDatas.glsl"
	
	
	// misc
	
	#if FOLIAGE_NOISE_ENABLED
		if (isFoliage) {
			ivec2 iWorldPos2 = ivec2(playerPos.xz + cameraPosition.xz + at_midBlock.xz / 64.0);
			uint rng = uint(iWorldPos2.x) + uint(iWorldPos2.y) * 1024u;
			float lift = randomFloat(rng);
			glcolor *= 1.0 + lift * vec3(1.2, 0.8, 0.9) * 0.25 * FOLIAGE_NOISE_AMOUNT;
		}
	#endif
	
	#if SHOW_DANGEROUS_LIGHT == 1
		isDangerousLight = 0.0;
		if (gl_Normal.y > 0.9) {
			if (lmcoord.x < 0.5) {
				if (abs(lmcoord.x - 0.05) < 0.02) {
					isDangerousLight = 0.5;
				} else {
					isDangerousLight = 1.0;
				}
			}
		}
	#endif
	
	
	// experiments
	
	//#define WORLD_TEXTURE_SCALING 2
	//#define TEXTURE_SIZE 16
	//vec2 scale = textureSize(MAIN_TEXTURE, 0) / TEXTURE_SIZE;
	////texcoord *= scale;
	//vec2 texcoordFract = fract(texcoord);
	//vec3 worldPos = playerPos + cameraPosition;
	//vec2 worldTexPos = Project3DPointTo2D(worldPos, vec3(0.0), gl_Normal);
	//texcoordFract += mod(worldTexPos, WORLD_TEXTURE_SCALING);
	//texcoordFract /= WORLD_TEXTURE_SCALING;
	////texcoord = floor(texcoord) + texcoordFract;
	////texcoord /= scale;
	
	// fun way to screw up the textures:
	//#define WORLD_TEXTURE_SCALING 2
	//#define TEXTURE_SIZE 16
	//vec2 scale = textureSize(MAIN_TEXTURE, 0) / TEXTURE_SIZE;
	//texcoord *= scale;
	//vec2 texcoordFract = fract(texcoord);
	//vec3 worldPos = playerPos + cameraPosition;
	//vec2 worldTexPos = Project3DPointTo2D(worldPos, vec3(0.0), gl_Normal);
	//texcoordFract += mod(worldTexPos, WORLD_TEXTURE_SCALING);
	//texcoordFract /= WORLD_TEXTURE_SCALING;
	//texcoord = floor(texcoord) + texcoordFract;
	//texcoord /= scale;
	
	
	#if WAVING_ENABLED == 1
		applyWaving(playerPos, encodedData);
	#endif
	
	
	gl_Position = playerToNdc(playerPos);
	
	
	#if TAA_ENABLED == 1
		doTaaJitter(gl_Position.xy);
	#endif
	
	
	doVshLighting(lmcoord, viewPos, normal);
	
}

#endif
