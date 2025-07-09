using UnityEngine;
using UnityEngine.Rendering;

[ExecuteInEditMode]
[AddComponentMenu("Image Effects/Rendering/SSGI")]
[ImageEffectAllowedInSceneView]
[RequireComponent(typeof(Camera))]
public class SSGI : MonoBehaviour
{
    [SerializeField]
    private Shader _shader;

    [Header("Ray-Marching")]
    [Range(1, 128)]
    public int sampleCount = 16;
    [Range(0.1f, 100f)]
    public float maxGIRayDistance = 25.0f;
    [Range(0.1f, 20f)]
    public float maxAORayDistance = 2.0f;
    [Range(0.01f, 5.0f)]
    public float intersectionThickness = 2.5f;

    [Header("Lighting")]
    [Range(0.01f, 5.0f)]
    public float giIntensity = 1.0f;
    [Range(0.0f, 5.0f)]
    public float aoIntensity = 1.0f;
    [Range(1.0f, 20.0f)]
    public float sampleClampValue = 5.0f;
    [Tooltip("Use physically-based cosine-weighted sampling for GI.")]
    public bool cosineWeightedSampling = true;

    [Header("Performance & Filtering")]
    [Range(0.25f, 1.0f)]
    public float resolutionScale = 0.5f;
    [Range(0, 8)]
    public int filterIterations = 1;
    [Range(0.0f, 2.0f)]
    public float filterRadius = 1.0f;
    [Range(0.0f, 50.0f)]
    public float depthWeight = 10.0f;
    [Range(0.0f, 100.0f)]
    public float normalWeight = 20.0f;

    private Material _material;
    private Camera _camera;
    private CommandBuffer _commandBuffer;
    private int _frameIndex = 0;

    private const int PASS_SSGI = 0;
    private const int PASS_COMPOSITE = 1;
    private const int PASS_GAUSSIAN = 2;

    void OnEnable()
    {
        _camera = GetComponent<Camera>();
        _camera.depthTextureMode |= DepthTextureMode.Depth | DepthTextureMode.DepthNormals;
        _commandBuffer = new CommandBuffer { name = "SSGI" };
        _camera.AddCommandBuffer(CameraEvent.BeforeImageEffects, _commandBuffer);
    }

    void OnDisable()
    {
        if (_commandBuffer != null)
        {
            _camera.RemoveCommandBuffer(CameraEvent.BeforeImageEffects, _commandBuffer);
            _commandBuffer.Release();
            _commandBuffer = null;
        }
        if (_material != null) DestroyImmediate(_material);
    }

    void OnPreRender()
    {
        if (_shader == null) return;
        if (_material == null) _material = new Material(_shader) { hideFlags = HideFlags.HideAndDontSave };

        _commandBuffer.Clear();
        _frameIndex++;
        int lowResW = (int)(_camera.pixelWidth * resolutionScale);
        int lowResH = (int)(_camera.pixelHeight * resolutionScale);
        int fullResW = _camera.pixelWidth;
        int fullResH = _camera.pixelHeight;

        Matrix4x4 projMatrix = GL.GetGPUProjectionMatrix(_camera.projectionMatrix, false);
        Matrix4x4 viewMatrix = _camera.worldToCameraMatrix;

        // --- Set Global Shader Properties ---
        _material.SetMatrix("_InverseProjection", projMatrix.inverse);
        _material.SetMatrix("_Projection", projMatrix);
        _material.SetInt("_FrameIndex", _frameIndex);

        // Ray-Marching & Lighting
        _material.SetInt("_SampleCount", sampleCount);
        _material.SetFloat("_GIIntensity", giIntensity);
        _material.SetFloat("_AOIntensity", aoIntensity);
        _material.SetFloat("_MaxGIRayDistance", maxGIRayDistance);
        _material.SetFloat("_MaxAORayDistance", maxAORayDistance);
        _material.SetFloat("_CosineWeightedSampling", cosineWeightedSampling ? 1.0f : 0.0f);
        _material.SetFloat("_IntersectionThickness", intersectionThickness);
        _material.SetFloat("_SampleClampValue", sampleClampValue);
        
        // Render Mode & Texel Sizes
        _material.EnableKeyword("RENDER_GI_AO");
        _material.DisableKeyword("RENDER_GI");
        _material.SetVector("_FullResTexelSize", new Vector4(1.0f / fullResW, 1.0f / fullResH, fullResW));
        
        // --- Command Buffer Execution ---

        // 1. SSGI Ray-Marching Pass
        int ssgiTextureID = Shader.PropertyToID("_SSGITexture");
        _commandBuffer.GetTemporaryRT(ssgiTextureID, lowResW, lowResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
        _commandBuffer.Blit(null, ssgiTextureID, _material, PASS_SSGI);
        RenderTargetIdentifier lastResult = ssgiTextureID;
        
        // 2. Spatial Filtering (Gaussian Blur)
        if (filterRadius > 0 && filterIterations > 0)
        {
            int upscaledID = Shader.PropertyToID("_UpscaledResult");
            _commandBuffer.GetTemporaryRT(upscaledID, fullResW, fullResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);
            _commandBuffer.Blit(lastResult, upscaledID); // Upscale before blurring
            
            _commandBuffer.ReleaseTemporaryRT(ssgiTextureID); // Release low-res texture now

            int blurBufferID = Shader.PropertyToID("_BlurBuffer");
            _commandBuffer.GetTemporaryRT(blurBufferID, fullResW, fullResH, 0, FilterMode.Bilinear, RenderTextureFormat.DefaultHDR);

            _material.SetFloat("_BlurRadius", filterRadius);
            _material.SetFloat("_BlurDepthWeight", depthWeight);
            _material.SetFloat("_BlurNormalWeight", normalWeight);

            RenderTargetIdentifier source = upscaledID;
            RenderTargetIdentifier dest = blurBufferID;

            for (int i = 0; i < filterIterations; i++)
            {
                _commandBuffer.SetGlobalTexture("_BlurSourceTex", source);
                _commandBuffer.Blit(source, dest, _material, PASS_GAUSSIAN);
                var temp = source; source = dest; dest = temp;
            }
            lastResult = source;
            
            if (dest == (RenderTargetIdentifier)blurBufferID) _commandBuffer.ReleaseTemporaryRT(blurBufferID);
            else _commandBuffer.ReleaseTemporaryRT(upscaledID);
        }

        // 3. Composite
        _commandBuffer.SetGlobalTexture("_AccumulatedSSGITex", lastResult);
        int tempTargetID = Shader.PropertyToID("_TempCameraTarget");
        _commandBuffer.GetTemporaryRT(tempTargetID, -1, -1, 0, FilterMode.Bilinear);
        _commandBuffer.Blit(BuiltinRenderTextureType.CameraTarget, tempTargetID);
        _commandBuffer.SetGlobalTexture("_MainTex", tempTargetID);
        _commandBuffer.Blit(tempTargetID, BuiltinRenderTextureType.CameraTarget, _material, PASS_COMPOSITE);
        _commandBuffer.ReleaseTemporaryRT(tempTargetID);
        
        // Release the final result texture
        _commandBuffer.ReleaseTemporaryRT(Shader.PropertyToID(lastResult.ToString()));
    }
}