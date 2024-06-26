#if !defined COMPUTESUNLIGHT_FSH
#define COMPUTESUNLIGHT_FSH

#include "/lib/Misc/ShadowBias.glsl"

float GetLambertianShading(vec3 normal) {
	return clamp01(dot(normal, lightVector));
}

// https://github.com/riccardoscalco/glsl-pcg-prng/blob/main/index.glsl
uint pcg(uint v) {
	uint state = v * uint(747796405) + uint(2891336453);
	uint word = ((state >> ((state >> uint(28)) + uint(4))) ^ state) * uint(277803737);
	return (word >> uint(22)) ^ word;
}

float prng (uint seed) {
	return float(pcg(seed)) / float(uint(0xffffffff));
}

float GetLambertianShading(vec3 normal, vec3 lightVector, Mask mask) {
	float shading = clamp01(dot(normal, lightVector));
	      shading = mix(shading, 1.0, mask.translucent);
	
	return shading;
}

float shadowVisibility(sampler2D shadowMap, vec3 shadowPosition){
	return step(shadowPosition.z, texture2D(shadowMap, shadowPosition.xy).r);
}

mat2 getRandomRotation(vec2 offset){
	uint seed = uint(gl_FragCoord.x * viewHeight+ gl_FragCoord.y) * 720720u;
	seed += floatBitsToInt(
	gbufferModelViewInverse[2].x +
	gbufferModelViewInverse[2].y +
	gbufferModelViewInverse[2].z +
	cameraPosition.x +
	cameraPosition.y +
	cameraPosition.z
	);
	#ifdef DYNAMIC_NOISE
	seed += frameCounter;
	#endif
	float randomAngle = 2 * PI * prng(seed);
	float cosTheta = cos(randomAngle);
	float sinTheta = sin(randomAngle);
	return mat2(cosTheta, -sinTheta, sinTheta, cosTheta);
}

#if SHADOW_TYPE == 2
	vec3 ComputeShadows(vec3 shadowPosition, float biasCoeff) {
		float spread = (1.0 - biasCoeff) / shadowMapResolution;
		
		#ifdef VARIABLE_PENUMBRA_SHADOWS
			float shadowDepthRange = 255; // distance that a depth of 1 indicates

			float sunWidth = 0.9; // approximation of sun width if it was 100m away instead of several million km
			float receiverDepth = shadowPosition.z * shadowDepthRange;
			float blockerDepthSum;

			float pixelsPerBlock = shadowMapResolution / shadowDistance;
			float maxPenumbraWidth = 2 * pixelsPerBlock;


			int blockerCount = 0;
			float blockerSearchSamples = 4.0;
			float blockerSearchInterval = maxPenumbraWidth / blockerSearchSamples;
			for(float y = -maxPenumbraWidth; y < maxPenumbraWidth; y += blockerSearchInterval){
				for(float x = -maxPenumbraWidth; x < maxPenumbraWidth; x += blockerSearchInterval){
					float newBlockerDepth = texture2D(shadowtex0, shadowPosition.xy + vec2(x, y) * spread).r * shadowDepthRange;
					if (newBlockerDepth < receiverDepth){
						blockerDepthSum += newBlockerDepth;
						blockerCount++;
					}
					
				}
			}

			float blockerDepth = blockerDepthSum / blockerCount;



			
			float penumbraWidth = (receiverDepth - blockerDepth) * sunWidth / blockerDepth;
			penumbraWidth = clamp(penumbraWidth, -maxPenumbraWidth, maxPenumbraWidth);

			float range = max(SHADOW_SOFTNESS, penumbraWidth * pixelsPerBlock);
		#else
			float range       = SHADOW_SOFTNESS;
		#endif

		// float sampleCount = pow(range / interval * 2.0 + 1.0, 2.0);
		float sampleCount = SHADOW_SAMPLES;
		float interval = (range * 2) / sqrt(sampleCount);

		
		vec3 sunlight = vec3(0.0);
		
		int samples = 0;
		for (float y = -range; y <= range; y += interval){
			for (float x = -range; x <= range; x += interval){
				vec2 offset = vec2(x, y);
				offset = getRandomRotation(offset) * offset;
				#ifdef TRANSPARENT_SHADOWS
				float fullShadow = shadowVisibility(shadowtex0, shadowPosition + vec3(offset, 0) * spread);
				float opaqueShadow = shadowVisibility(shadowtex1, shadowPosition + vec3(offset, 0) * spread);
				float shadowTransparency = 1.0 - texture2D(shadowcolor0, shadowPosition.xy).a;
				vec3 shadowColor = texture2D(shadowcolor0, shadowPosition.xy).rgb * shadowTransparency;

				sunlight += mix(shadowColor * opaqueShadow, vec3(1.0), fullShadow);
				#else
				sunlight += vec3(shadowVisibility(shadowtex0, shadowPosition + vec3(offset, 0) * spread));
				#endif
				samples++;
			}
		}
		
		return sunlight / samples;
	}
#else
	#define ComputeShadows(shadowPosition, biasCoeff) vec3(shadowVisibility(shadowtex0, shadowPosition));
#endif

float ComputeSunlightFast(vec3 worldSpacePosition, float sunlightCoeff){
	if (sunlightCoeff <= 0.0) return sunlightCoeff;

	float distCoeff = GetDistanceCoeff(worldSpacePosition);
	
	if (distCoeff >= 1.0) return sunlightCoeff;
	
	float biasCoeff;
	
	vec3 shadowPosition = BiasShadowProjection(projMAD(shadowProjection, transMAD(shadowViewMatrix, worldSpacePosition + gbufferModelViewInverse[3].xyz)), biasCoeff) * 0.5 + 0.5;
	
	if (any(greaterThan(abs(shadowPosition.xyz - 0.5), vec3(0.5)))) return sunlightCoeff;
	
	float sunlight = shadowVisibility(shadowtex0, shadowPosition);
	sunlight = mix(sunlight, 1.0, distCoeff);

	return sunlightCoeff * pow(sunlight, mix(2.0, 1.0, clamp01(length(worldSpacePosition) * 0.1)));
}

vec3 ComputeSunlight(vec3 worldSpacePosition, float sunlightCoeff) {
	if (sunlightCoeff <= 0.0) return vec3(sunlightCoeff);
	
	float distCoeff = GetDistanceCoeff(worldSpacePosition);
	
	if (distCoeff >= 1.0) return vec3(sunlightCoeff);
	
	float biasCoeff;
	
	vec3 shadowPosition = BiasShadowProjection(projMAD(shadowProjection, transMAD(shadowViewMatrix, worldSpacePosition + gbufferModelViewInverse[3].xyz)), biasCoeff) * 0.5 + 0.5;
	
	if (any(greaterThan(abs(shadowPosition.xyz - 0.5), vec3(0.5)))) return vec3(sunlightCoeff);
	
	vec3 sunlight = ComputeShadows(shadowPosition, biasCoeff);
	      sunlight = mix(sunlight, vec3(sunlightCoeff), distCoeff);
	
	return vec3(sunlightCoeff) * pow(sunlight, vec3(mix(2.0, 1.0, clamp01(length(worldSpacePosition) * 0.1))));
}

#endif
