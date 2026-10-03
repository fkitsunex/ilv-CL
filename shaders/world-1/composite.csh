#version 430

// [CL rewrite] Colour-light floodfill. Runs in the COMPOSITE stage — the first stage AFTER the
// translucent gbuffers pass (gbuffers_water). Opaque emitters voxelise in gbuffers_terrain and the
// NETHER PORTAL (a translucent block) voxelises in gbuffers_water; both land before composite, so the
// floodfill here reads them ALL every frame, regardless of the shadow setting, in every dimension.
// (Was deferred1.csh, but the deferred stage runs BEFORE translucents, so it never saw the portal.
// Surface lighting now reads last frame's floodfill — a 1-frame delay, imperceptible since the
// floodfill is iterative anyway.)

#define SHADER_SHADOWCOMP
#define NETHER
#define CSH

#include "/basics/settings.glsl"
#include "/basics/uniforms.glsl"
#include "/generated/common.glsl"
#include "/basics/common.glsl"

#include "/program/shadowcomp.glsl"
