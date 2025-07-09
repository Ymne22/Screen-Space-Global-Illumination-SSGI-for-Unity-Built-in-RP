Shader "Hidden/SSGI"
{
    Properties
    {
        _MainTex("Texture", 2D) = "white" {}
    }
    SubShader
    {
        Cull Off ZWrite Off ZTest Always

        CGINCLUDE
        #include "UnityCG.cginc"

        #define PI 3.14159265359

        struct appdata {
            float4 vertex : POSITION;
            float2 uv : TEXCOORD0;
        };

        struct v2f {
            float2 uv : TEXCOORD0;
            float4 vertex : SV_POSITION;
            float3 ray : TEXCOORD1;
        };

        sampler2D _MainTex;
        sampler2D_float _CameraDepthTexture;
        sampler2D_float _CameraDepthNormalsTexture;
        float4x4 _InverseProjection, _Projection;
        int _FrameIndex;

        v2f vert(appdata v) {
            v2f o;
            o.vertex = UnityObjectToClipPos(v.vertex);
            o.uv = v.uv;
            o.ray = mul(_InverseProjection, float4(v.uv * 2 - 1, 0, 1)).xyz;
            return o;
        }
        
        float2 Halton(int index, int b1, int b2) {
            half r1 = 0.0, f1 = 1.0;
            int i = index;
            while (i > 0) { f1 /= b1; r1 += f1 * (i % b1); i = floor(i / (half)b1); }
            half r2 = 0.0, f2 = 1.0;
            i = index;
            while (i > 0) { f2 /= b2; r2 += f2 * (i % b2); i = floor(i / (half)b2); }
            return float2(r1, r2);
        }
        
        half RandomNoise(float2 co, half seed)
        {
            float2 p = frac(co * float2(0.1031, 0.1030));
            p += dot(p, p.yx + 19.19);
            half static_hash = frac((p.x + p.y) * p.y);

            // Using static hash for consistent noise without temporal accumulation
            return frac(static_hash);
        }

        half readDepth(float2 coord) {
            return LinearEyeDepth(SAMPLE_DEPTH_TEXTURE(_CameraDepthTexture, coord));
        }

        void getBasis(float3 n, out float3 t, out float3 b) {
            float3 up = abs(n.z) < 0.999 ? float3(0, 0, 1) : float3(1, 0, 0);
            t = normalize(cross(up, n));
            b = cross(n, t);
        }
        
        void getSceneData(float2 uv, float3 ray, out float3 viewPos, out float3 viewNormal) {
            half depth = readDepth(uv);
            viewPos = ray * depth; 
            half rawDepth;
            DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, uv), rawDepth, viewNormal);
        }
        ENDCG

        // PASS 0: Combined GI and AO Ray-Marching
        Pass
        {
            CGPROGRAM
            #pragma vertex vert
            #pragma fragment frag_ssgi
            #pragma multi_compile __ RENDER_GI RENDER_AO RENDER_GI_AO

            int _SampleCount;
            half _MaxGIRayDistance, _MaxAORayDistance, _IntersectionThickness, _SampleClampValue;
            half _CosineWeightedSampling;
            sampler2D _CameraGBufferTexture0;
            sampler2D _CameraGBufferTexture3;

            float4 frag_ssgi(v2f i) : SV_Target
            {
                if (readDepth(i.uv) >= 0.999 * _ProjectionParams.z) return 0;
                
                float3 viewPos, viewNormal;
                getSceneData(i.uv, i.ray, viewPos, viewNormal);
                
                float3 t, b;
                getBasis(viewNormal, t, b);
                
                float3 totalIndirectLight = 0;
                half totalOcclusion = 1;
                float3 origin = viewPos + viewNormal * (viewPos.z * 0.001);
                half randomRotation = RandomNoise(i.vertex.xy, _FrameIndex) * 2.0 * PI;

                #if defined(RENDER_GI) || defined(RENDER_GI_AO)
                [loop]
                for (int j = 0; j < _SampleCount; j++)
                {
                    float2 xi = Halton(j, 2, 3);
                    half phi = 2.0 * PI * xi.x + randomRotation;
                    half cosTheta = lerp(xi.y, sqrt(xi.y), _CosineWeightedSampling);
                    half sinTheta = sqrt(1.0 - cosTheta * cosTheta);
                    float3 localDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
                    float3 viewspaceRayDir = localDir.x * t + localDir.y * b + localDir.z * viewNormal;
                    half random_len_frac = frac(randomRotation + j * 0.379);
                    half ray_max_dist = lerp(0.1, _MaxGIRayDistance, random_len_frac);
                    const int marchSteps = 8;
                    const half stepGrowth = 1.8;
                    half currentRayLen = 0.1 * (1.0 + random_len_frac);
                    for (int k = 0; k < marchSteps; k++) 
                    {
                        if (currentRayLen > ray_max_dist) break;
                        float3 currentRayPos = origin + viewspaceRayDir * currentRayLen;
                        float4 currentClip = mul(_Projection, float4(currentRayPos, 1.0));
                        float2 currentUV = (currentClip.xy / currentClip.w) * 0.5 + 0.5;
                        if (saturate(currentUV).x != currentUV.x || saturate(currentUV).y != currentUV.y) break;
                        half sceneDepth = readDepth(currentUV);
                        half rayDepth = -currentRayPos.z;
                        half dynamicThickness = _IntersectionThickness * saturate(sceneDepth * 0.1);
                        if (rayDepth > sceneDepth && (rayDepth - sceneDepth) < dynamicThickness) 
                        {
                            if (sceneDepth < 0.999 * _ProjectionParams.z)
                            {
                                half3 finalColor = tex2D(_CameraGBufferTexture3, half4(currentUV, 0, 0)).rgb;
                                half3 albedo = tex2D(_CameraGBufferTexture0, half4(currentUV, 0, 0)).rgb;
                                half3 lightEnergy = finalColor / (albedo + 1e-4);
                                half3 indirectBounce = albedo * min(lightEnergy, (half3)_SampleClampValue);
                                totalIndirectLight += (indirectBounce * 2) + (albedo * 0.015);
                            }
                            break;
                        }
                        currentRayLen *= stepGrowth;
                    }
                }
                if(_SampleCount > 0) totalIndirectLight /= (half)_SampleCount;
                #endif

                #if defined(RENDER_AO) || defined(RENDER_GI_AO)
                [loop]
                for (int ao_j = 0; ao_j < _SampleCount; ao_j++)
                {
                    float2 xi = Halton(ao_j + 1, 2, 3);
                    half phi = 2.0 * PI * xi.x + randomRotation;
                    half cosTheta = sqrt(1.0 - xi.y);
                    half sinTheta = sqrt(xi.y);
                    float3 rayDir = float3(cos(phi) * sinTheta, sin(phi) * sinTheta, cosTheta);
                    float3 viewspaceRayDir = rayDir.x * t + rayDir.y * b + rayDir.z * viewNormal;
                    const int marchSteps = 8;
                    half stepLength = _MaxAORayDistance / marchSteps;
                    for (int k = 1; k <= marchSteps; k++)
                    {
                        half currentRayLen = k * stepLength;
                        float3 samplePos = origin + viewspaceRayDir * currentRayLen;
                        float4 projPos = mul(_Projection, float4(samplePos, 1.0));
                        float2 sampleUV = (projPos.xy / projPos.w) * 0.5 + 0.5;
                        if (saturate(sampleUV).x != sampleUV.x || saturate(sampleUV).y != sampleUV.y) break;
                        half sceneDepth = readDepth(sampleUV);
                        if (sceneDepth < -samplePos.z) 
                        {
                            float3 occluderPos = mul(_InverseProjection, float4(sampleUV * 2 - 1, 0, 1)).xyz * sceneDepth;
                            float3 vecToOccluder = occluderPos - viewPos;
                            half distToOccluder = length(vecToOccluder);
                            half attenuation = saturate(1.0 - distToOccluder / _MaxAORayDistance);
                            half horizon = saturate(dot(viewNormal, normalize(vecToOccluder)));
                            totalOcclusion += horizon * attenuation;
                            break;
                        }
                    }
                }
                if (_SampleCount > 0) totalOcclusion = saturate(1.0 - (totalOcclusion / _SampleCount) * 1.5);
                else totalOcclusion = 1.0;
                #else
                totalOcclusion = 1.0;
                #endif

                return float4(totalIndirectLight, totalOcclusion);
            }
            ENDCG
        }

        // PASS 1: Composite
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_composite
            #pragma fragment frag_composite

            struct v2f_comp { float4 vertex : SV_POSITION; float2 uv : TEXCOORD0; };
            
            v2f_comp vert_composite(appdata_base v) {
                v2f_comp o; o.vertex = UnityObjectToClipPos(v.vertex); o.uv = v.texcoord; return o;
            }
            
            sampler2D _AccumulatedSSGITex, _CameraGBufferTexture0;
            half _GIIntensity, _AOIntensity;
            
            fixed4 frag_composite(v2f_comp i) : SV_Target
            {
                fixed4 originalColor = tex2D(_MainTex, i.uv);
                
                float4 ssgi = tex2D(_AccumulatedSSGITex, i.uv);
                float3 indirectBouncedLight = ssgi.rgb;
                half ambientOcclusion = ssgi.a;

                float3 albedo = tex2D(_CameraGBufferTexture0, i.uv).rgb;
                
                float3 finalIndirectTerm = indirectBouncedLight * albedo * _GIIntensity;
                finalIndirectTerm = lerp(finalIndirectTerm, finalIndirectTerm * ambientOcclusion, _AOIntensity);

                float3 finalColor = originalColor.rgb + finalIndirectTerm;
                
                return float4(finalColor, originalColor.a);
            }
            ENDCG
        }

        // PASS 2: Gaussian Blur
        Pass
        {
            CGPROGRAM
            #pragma vertex vert_fullres
            #pragma fragment frag_gaussian_blur

            struct v2f_fullres {
                float4 vertex : SV_POSITION;
                half2 uv : TEXCOORD0;
            };

            v2f_fullres vert_fullres(appdata_base v) {
                v2f_fullres o;
                o.vertex = UnityObjectToClipPos(v.vertex);
                o.uv = v.texcoord;
                return o;
            }

            sampler2D _BlurSourceTex;
            half4 _FullResTexelSize;
            half _BlurRadius, _BlurDepthWeight, _BlurNormalWeight;

            half4 frag_gaussian_blur(v2f_fullres i) : SV_Target
            {
                half centerDepth = readDepth(i.uv);
                half rawDepth;
                half3 centerNormal;
                DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, i.uv), rawDepth, centerNormal);

                half4 total = 0.0h;
                half totalWeight = 0.0h;

                [unroll]
                for (int x = -6; x <= 6; x++) {
                    [unroll]
                    for (int y = -6; y <= 6; y++) {
                        half2 offset = half2(x, y) * _FullResTexelSize.xy * _BlurRadius * 2;
                        offset += (frac(sin(i.uv*100)*0.5-0.25)*_FullResTexelSize.xy);
                        half2 sampleUV = i.uv + offset;

                        half sampleDepth = readDepth(sampleUV);
                        half3 sampleNormal;
                        DecodeDepthNormal(tex2D(_CameraDepthNormalsTexture, sampleUV), rawDepth, sampleNormal);

                        half depthDiff = abs(centerDepth - sampleDepth);
                        half depthW = exp(-_BlurDepthWeight * depthDiff * depthDiff);

                        half normalDot = saturate(dot(centerNormal, sampleNormal));
                        half normalW = normalDot * normalDot;

                        half dist = dot(offset, offset);
                        half gaussW = exp(-dist * 2.0);

                        half weight = gaussW * depthW * normalW;
                        total += tex2D(_BlurSourceTex, sampleUV) * weight;
                        totalWeight += weight;
                    }
                }

                return (totalWeight > 1e-4) ? total / totalWeight : tex2D(_BlurSourceTex, i.uv);
            }
            ENDCG
        }
    }
}