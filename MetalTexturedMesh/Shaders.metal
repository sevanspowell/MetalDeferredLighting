#include <metal_stdlib>
using namespace metal;

struct Constants {
    float4x4 modelViewProjectionMatrix;
    float3x3 normalMatrix;
    float4x4 modelViewMatrix;
    float4x4 projectionMatrix;
    float4x4 modelMatrix;
    float cameraNear;
    float cameraFar;
};

struct VertexIn {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 texCoords;
};

typedef struct
{
    float4 albedo [[color(0)]];
    float4 normal [[color(1)]];
    float  depth [[color(2)]];
} FragOutput;

struct VertexOut {
    float4 position [[position]];
    float3 normal;
    float2 texCoords;
    float4 worldPosition;
};

struct GBufferOut {
    float4 albedo [[color(1)]];
    float4 normal [[color(0)]];
    float4 position [[color(2)]];
};

struct VertexPassThruIn {
    packed_float2 position;
};

struct VertexPassThruOut {
    float4 position [[position]];
};

struct LightVertexIn {
    packed_float3 position;
    packed_float3 normal;
    packed_float2 texCoords;
};

struct LightVertexOut {
    float4 position [[position]];
};

struct LightFragmentInput {
    float2 screenSize;
};

struct PointLight {
    float3 worldPosition;
    float attenuationConstant;
    float attenuationLinear;
    float attenuationExp;
    
    float3 color;

    float radius;
};


vertex VertexPassThruOut passThroughVertex(const device VertexPassThruIn *vertices [[ buffer(0) ]],
                                           unsigned int vid [[vertex_id]]) {
    VertexPassThruOut out;
    
    out.position = float4(vertices[vid].position, 0.0, 1.0);
    
    return out;
}

fragment float4 passThroughFragment(VertexPassThruOut inFrag [[stage_in]],
                                   constant LightFragmentInput *lightData [[ buffer(0) ]],
                                   texture2d<unsigned> compositeTexture [[ texture(0) ]],
                                   sampler sampler2d [[sampler(0)]]) {
    float2 sampleCoords = inFrag.position.xy / lightData->screenSize;
    
    vec<unsigned, 4> compositeUnsigned = compositeTexture.sample(sampler2d, sampleCoords);
    const float4 composite = normalize(float4(compositeUnsigned.x, compositeUnsigned.y, compositeUnsigned.z, compositeUnsigned.w)) / normalize(float4(1.0, 1.0, 1.0, 1.0));
    
    return composite;
    //return half4(1.0, 0.0, 0.0, 1.0);
}


vertex LightVertexOut lightVolumeVert(const device LightVertexIn *vertices [[buffer(0)]],
                                     const device Constants &uniforms [[buffer(1)]],
                                     unsigned int vid [[vertex_id]]) {
    LightVertexOut out;
    
    out.position = uniforms.modelViewProjectionMatrix * float4(vertices[vid].position, 1.0);
    
    return out;
}

fragment float4 lightVolumeFrag(LightVertexOut in [[stage_in]],
                                constant LightFragmentInput *lightData [[ buffer(0) ]],
                                constant PointLight *pointLight [[ buffer(1) ]],
                                texture2d<unsigned> albedoTexture [[ texture(0) ]],
                                texture2d<float> normalsTexture [[ texture(1) ]],
                                texture2d<float> positionTexture [[ texture(2) ]])
{
    // We sample albedo, normals and position from the position of this fragment, normalized to be 0-1 within screen space
    float2 sampleCoords = in.position.xy / lightData->screenSize;
    
    constexpr sampler texSampler;
    
    // Convert unsigned texture value to float value
    vec<unsigned, 4> albedoUnsigned = albedoTexture.sample(texSampler, sampleCoords);
    float3 albedo = normalize(float3(albedoUnsigned.x, albedoUnsigned.y, albedoUnsigned.z)) / normalize(float3(1.0, 1.0, 1.0));
    //albedo = float3(1.0, 1.0, 1.0);
    const float3 worldPosition = float3(positionTexture.sample(texSampler, sampleCoords));
    const float3 normal = normalize(float3(normalsTexture.sample(texSampler, sampleCoords)));
    const float3 camPos = float3(0, 0, 4.5);
    
    const float3 viewDir = normalize(camPos - worldPosition);
    const float3 lightDir = normalize(pointLight->worldPosition - worldPosition);

    /*
    float distance = length(pointLight->worldPosition - worldPosition);
    if (distance < pointLight->radius)
    {
        float3 diffuse = max(dot(normal, lightDir), 0.0) * albedo * pointLight->color;
        //lighting = float3(diffuse);
                          
        // attenuation
        float attenuation = 1.0 / (1.0 + pointLight->attenuationLinear * distance + pointLight->attenuationExp * distance * distance);
        diffuse *= attenuation;
        lighting += diffuse;
    }
    */
    
    float ndotL = max(dot(normal, lightDir), 0.0);
    float3 diffuse = ndotL * albedo * pointLight->color;
    
    // specular
    float3 halfwayDir = normalize(lightDir + viewDir);
    float3 specular = pow(max(dot(normal, halfwayDir), 0.0), 48.0) * 1;
    //float3 specular = float3(spec, spec, spec);
    
    float3 result = albedo * 0.00000001;
    result += (diffuse + specular);
    
    float3 gammaCorrect = pow(diffuse, (1.0/2.2));
    return float4(gammaCorrect, 1.0);
    //return float4(0.333, 0.0, 0.0, 1.0);
    //return float4(diffuse, 1.0);
}

fragment void lightVolumeNullFrag(LightVertexOut in [[stage_in]])
{
}

vertex VertexOut gBufferVert(const device VertexIn *vertices [[buffer(0)]],
                             const device Constants &uniforms [[buffer(1)]],
                             unsigned int vid [[vertex_id]]) {
    VertexOut out;
    VertexIn vin = vertices[vid];
    
    float4 inPosition = float4(vin.position, 1.0);
    out.position = uniforms.modelViewProjectionMatrix * inPosition;
    float3 normal = vin.normal;
    float3 eyeNormal = normalize(uniforms.normalMatrix * normal);
    
    out.normal = eyeNormal;
    out.texCoords = vin.texCoords;
    out.worldPosition = uniforms.modelMatrix * inPosition;
    
    return out;
}

fragment GBufferOut gBufferFrag(VertexOut in [[stage_in]],
                                texture2d<float> albedo_texture [[texture(0)]])
{
    constexpr sampler linear_sampler(min_filter::linear, mag_filter::linear);
    /*
    vec<unsigned, 4> albedoUnsigned = albedo_texture.sample(linear_sampler, in.texCoords);
    float3 albedo = normalize(float3(albedoUnsigned.x, albedoUnsigned.y, albedoUnsigned.z)) / normalize(float3(1.0, 1.0, 1.0));
    albedo = albedo;
     */
    float4 albedo = albedo_texture.sample(linear_sampler, in.texCoords);
    
    GBufferOut output;
    
    output.albedo = albedo;
    output.normal = float4(in.normal, 1.0);
    output.position = in.worldPosition;
    
    return output;
}
