#include "/lib/Syntax.glsl"


varying vec2 texcoord;

#include "/lib/Uniform/Shading_Variables.glsl"


/***********************************************************************/
#if defined vsh

uniform sampler3D colortex7;

uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowModelView;
uniform mat4 shadowModelViewInverse;

uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;

uniform float sunAngle;
uniform float far;

uniform float rainStrength;
uniform float wetness;

#include "/lib/Settings.glsl"
#include "/lib/Utility.glsl"
#include "/lib/Debug.glsl"
#include "/lib/Uniform/Projection_Matrices.vsh"
#include "/UserProgram/centerDepthSmooth.glsl"
#include "/lib/Uniform/Shadow_View_Matrix.vsh"
#include "/lib/Fragment/PrecomputedSky.glsl"
#include "/lib/Vertex/Shading_Setup.vsh"

void main() {
	texcoord    = gl_MultiTexCoord0.st;
	gl_Position = ftransform();
	
	SetupProjection();
	SetupShading();
}

#endif
/***********************************************************************/



/***********************************************************************/
#if defined fsh

uniform sampler3D colortex7;
uniform sampler2D colortex8;
uniform sampler2D colortex9;

uniform sampler2D colortex1;
uniform sampler2D colortex2;
uniform sampler2D colortex3;
uniform sampler2D colortex4;
uniform sampler2D gdepthtex;
uniform sampler2D depthtex1;
uniform sampler2D noisetex;
uniform sampler2D shadowtex0;
uniform sampler2D shadowtex1;
uniform sampler2D shadowcolor0;
uniform mat4 gbufferModelView;

uniform float viewHeight;


uniform vec3 shadowLightPosition;

uniform mat4 gbufferModelViewInverse;
uniform mat4 shadowProjection;

uniform vec3 cameraPosition;

uniform vec2 pixelSize;

uniform float rainStrength;
uniform float wetness;

uniform float near;
uniform float far;

uniform ivec2 eyeBrightnessSmooth;

uniform int isEyeInWater;

#include "/lib/Settings.glsl"
#include "/lib/Utility.glsl"
#include "/lib/Debug.glsl"
#include "/lib/Uniform/Projection_Matrices.fsh"
#include "/lib/Uniform/Shadow_View_Matrix.fsh"
#include "/lib/Fragment/Masks.fsh"
#include "/lib/Misc/CalculateFogfactor.glsl"


vec3 GetColor(vec2 coord) {
	return texture2D(colortex1, coord).rgb;
}

float GetDepth(vec2 coord) {
	return texture2D(gdepthtex, coord).x;
}

float GetTransparentDepth(vec2 coord) {
	return texture2D(depthtex1, coord).x;
}

vec3 CalculateViewSpacePosition(vec3 screenPos) {
	screenPos = screenPos * 2.0 - 1.0;
	
	return projMAD(projInverseMatrix, screenPos) / (screenPos.z * projInverseMatrix[2].w + projInverseMatrix[3].w);
}

vec2 ViewSpaceToScreenSpace(vec3 viewSpacePosition) {
	return (diagonal2(projMatrix) * viewSpacePosition.xy + projMatrix[3].xy) / -viewSpacePosition.z * 0.5 + 0.5;
}

#include "/lib/Fragment/WaterDepthFog.fsh"
#include "/lib/Fragment/ComputeSunlight.fsh"
#include "/lib/Fragment/Sky.fsh"
#include "/lib/Fragment/ComputeSSReflections.fsh"



/* DRAWBUFFERS:32 */
#include "/lib/Exit.glsl"

vec3 ComputeReflectiveSurface(float depth0, float depth1, mat2x3 frontPos, mat2x3 backPos, vec3 normal, float baseReflectance, float perceptualSmoothness, float skyLightmap, Mask mask, out vec3 alpha, vec3 transmit) {
	vec3 color = vec3(0.0);
	
	alpha = vec3(1.0);
	
	if (mask.transparent == 1.0) {
		color += texture2D(colortex3, texcoord).rgb;
		alpha *= clamp01(1.0 - texture2D(colortex3, texcoord).a);
	}

	if (depth1 < 1.0) {
		if (mask.water == 1.0)
			WaterDepthFog(frontPos[0], backPos[0] * (1-isEyeInWater), alpha); // surface, behind water
		
		color += texture2D(colortex1, texcoord).rgb * alpha;
		
		alpha *= 0.0;
	}

	if (mask.water == 1.0 && depth1 >= 1.0 && isEyeInWater == 0) // sky, behind water
		alpha *= 0.1;

	if (depth0 < 1.0)
		ComputeSSReflections(color, frontPos, normal, baseReflectance, perceptualSmoothness, skyLightmap);
	
	return color * transmit;
	
}

void main() {
	vec2 texture4 = ScreenTex(colortex4).rg;
	
	vec4  decode4       = Decode4x8F(texture4.r);
	Mask  mask          = CalculateMasks(decode4.r);
	float specularity    = decode4.g;
	float baseReflectance = ScreenTex(colortex9).g;
	float perceptualSmoothness = ScreenTex(colortex9).r;
	float skyLightmap   = decode4.a;
	
	gl_FragData[1] = vec4(decode4.r, 0.0, 0.0, 1.0);
	
	float depth0 = (mask.hand > 0.5 ? 0.55 : GetDepth(texcoord));
	
	vec3 normal = DecodeNormal(texture4.g, 11) * mat3(gbufferModelViewInverse);
	
	mat2x3 frontPos;
	frontPos[0] = CalculateViewSpacePosition(vec3(texcoord, depth0));
	frontPos[1] = mat3(gbufferModelViewInverse) * frontPos[0];
	
	float  depth1  = depth0;
	mat2x3 backPos = frontPos;
	float  alpha   = 0.0;
	
	if (mask.transparent > 0.5) {
		depth1     = (mask.hand > 0.5 ? 0.55 : GetTransparentDepth(texcoord));
		//alpha      = texture2D(colortex3, texcoord).a;
		baseReflectance = ScreenTex(colortex8).g;
		perceptualSmoothness = ScreenTex(colortex8).r;
		backPos[0] = CalculateViewSpacePosition(vec3(texcoord, depth1));
		backPos[1] = mat3(gbufferModelViewInverse) * backPos[0];
	}
	
	if (true) { // this stuff has to be in a different scope because it was designed that way
		vec3 alpha = vec3(1.0);
		vec3 fogTransmit = vec3(1.0);
		vec3 color = vec3(0.0);
		vec3 fog = (depth0 < 1.0) ? SkyAtmosphereToPoint(vec3(0.0), frontPos[1], fogTransmit) : vec3(0.0);
		
		color = fog + ComputeReflectiveSurface(depth0, depth1, frontPos, backPos, normal, baseReflectance, perceptualSmoothness, skyLightmap, mask, alpha, fogTransmit);
		
		if (alpha.r + alpha.g + alpha.b > 0.0) {
			color += ComputeSky(normalize(frontPos[1]), vec3(0.0), alpha, 1.0, false, 1.0);
		}
		
		gl_FragData[0] = vec4(clamp01(EncodeColor(color)), 1.0);
		exit();
		return;
	}
}

#endif
/***********************************************************************/
