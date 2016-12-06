/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    Shader file with functions for rendering lit, textured geometry.
*/

#include <metal_stdlib>
using namespace metal;

float eyeSpaceDepthToNDC(float zEye, float near, float far);
float ndcDepthToDepthBuf(float zNDC);
float4 calcPointLight(float3 fragWorldPos, float3 lightWorldPos, float3 normal, float3 lightColor, float ambientIntensity, float diffuseIntensity, float attenuationConstant, float attenuationLinear, float attenuationExp);

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


struct DepthOut {
    float4 position[[position]];
    float4 ecPosition;
};

struct VertexOutput {
    float4 position [[position]];
    float3 v_normal;
    float3 v_texcoord;
    float v_linearDepth;
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
    //half4 clear [[color(3)]];
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
    float ambientIntensity;
    float diffuseIntensity;
    
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

float4 calcPointLight(float3 fragWorldPos, float3 lightWorldPos, float3 normal, float3 lightColor, float ambientIntensity, float diffuseIntensity, float attenuationConstant, float attenuationLinear, float attenuationExp) {
    float3 lightDirection = fragWorldPos - lightWorldPos;
    float distance = length(lightDirection);
    lightDirection = normalize(lightDirection);
    
    float4 ambientColor = float4(lightColor * ambientIntensity, 1.0);
    float diffuseFactor = 1 - dot(normal, lightDirection);
    
    float4 diffuseColor = float4(0, 0, 0, 0);
    float4 specularColor = float4(0, 0, 0, 0);
    
    return float4(diffuseFactor, diffuseFactor, diffuseFactor, 1.0);
    
    if (diffuseFactor > 0.0) {
        diffuseColor = float4(lightColor * diffuseIntensity * diffuseFactor, 1.0);
    }
    
    float4 color = (ambientColor + diffuseColor + specularColor);
    
    float attenuation = attenuationConstant + attenuationLinear * distance + attenuationExp * distance * distance;
    
    attenuation = max(1.0, attenuation);
    
    return color / attenuation;
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

/*
vertex VertexOutput gBufferVert(device VertexIn *vertices [[buffer(0)]],
                              device Constants &uniforms [[buffer(1)]],
                              uint vertexId [[vertex_id]])
{
    VertexOutput output;
    
    VertexIn vData = vertices[vertexId];
    
    output.v_normal = uniforms.normalMatrix * float3(vData.normal);
    output.v_linearDepth = (uniforms.modelViewMatrix * float4(vData.position, 1.0f)).z;
    output.v_texcoord = float3(vData.texCoords, 1.0);
    
    return output;
}

fragment FragOutput gBufferFrag(VertexOutput in [[stage_in]],
                                texture2d<float> albedo_texture [[texture(0)]])
{
    constexpr sampler linear_sampler(min_filter::linear, mag_filter::linear);
    float4 albedo = albedo_texture.sample(linear_sampler, in.v_texcoord.xy);
    
    FragOutput output;
    
    output.albedo = albedo;
    output.normal = float4(in.v_normal, 1.0);
    output.depth = in.v_linearDepth;
    
    return output;
}

vertex VertexPassThru compositionVertex(constant float2 *posData [[buffer(0)]],
                                        uint vid [[vertex_id]])
{
    VertexPassThru output;
    output.position = float4(posData[vid], 0.0f, 1.0f);
    return output;
}

fragment float4 compositionFrag(VertexPassThru in [[stage_in]],
                                FragOutput gBuffers)
{
    float3 normal = gBuffers.normal.rgb;
    float4 diffuse = gBuffers.albedo;
    
    return diffuse;
}

vertex VertexOut vertex_show_albedo(device VertexIn *vertices [[buffer(0)]],
                                  constant Constants &uniforms [[buffer(1)]],
                                  uint vertexId [[vertex_id]])
{
    float3 modelPosition = vertices[vertexId].position;
    float3 modelNormal = vertices[vertexId].normal;
    
    VertexOut out;
    // Multiplying the model position by the model-view-projection matrix moves us into clip space
    out.position = uniforms.modelViewProjectionMatrix * float4(modelPosition, 1);
    // Copy the vertex normal and texture coordinates
    out.normal = uniforms.normalMatrix * modelNormal;
    out.texCoords = vertices[vertexId].texCoords;
    return out;
}

fragment half4 fragment_show_albedo(VertexOut fragmentIn [[stage_in]],
                                     texture2d<float, access::sample> tex2d [[texture(0)]],
                                     sampler sampler2d [[sampler(0)]])
{
    // Sample the texture to get the surface color at this point
    half3 surfaceColor = half3(tex2d.sample(sampler2d, fragmentIn.texCoords).rrr);
    // Re-normalize the interpolated surface normal
    //half3 normal = normalize(half3(fragmentIn.normal));
    // Compute the ambient color contribution
    //half3 color = ambientLightIntensity * surfaceColor;
    half3 color = surfaceColor;
    // Calculate the diffuse factor as the dot product of the normal and light direction
    //float diffuseFactor = saturate(dot(normal, -lightDirection));
    // Add in the diffuse contribution from the light
    //color += diffuseFactor * diffuseLightIntensity * surfaceColor;
    return half4(color, 1);
}

vertex VertexOut vertex_show_normals(device VertexIn *vertices [[buffer(0)]],
                                     constant Constants &uniforms [[buffer(1)]],
                                     uint vertexId [[vertex_id]])
{
    float3 modelPosition = vertices[vertexId].position;
    float3 modelNormal = vertices[vertexId].normal;
    
    VertexOut out;
    out.position = uniforms.modelViewProjectionMatrix * float4(modelPosition, 1);
    out.normal = uniforms.normalMatrix * modelNormal;
    
    return out;
}

fragment float4 fragment_show_normals(VertexOut fragmentIn [[stage_in]])
{
    float3 color = (normalize(fragmentIn.normal) * 0.5 + 0.5);
    return float4(color, 1);
}

vertex DepthOut vertex_show_depth(device VertexIn *vertices [[buffer(0)]],
                                     constant Constants &uniforms [[buffer(1)]],
                                     uint vertexId [[vertex_id]])
{
    float3 modelPosition = vertices[vertexId].position;

    DepthOut out;
    out.ecPosition = uniforms.modelViewMatrix * float4(modelPosition, 1);
    out.position = uniforms.projectionMatrix * out.ecPosition;
    
    return out;
}

fragment float4 fragment_show_depth(DepthOut fragmentIn [[stage_in]], constant Constants &uniforms [[buffer(1)]])
{
    float zEye = fragmentIn.ecPosition.z;
    float zNDC = eyeSpaceDepthToNDC(zEye, 0.1, 100);
    float zBuf = ndcDepthToDepthBuf(zNDC);
    
    return float4(zEye, zEye, zEye, 1);
}

vertex DepthOut vertex_show_depth(device VertexIn *vertices [[buffer(0)]],
                                  constant Constants &uniforms [[buffer(1)]],
                                  uint vertexId [[vertex_id]])
{
    float3 modelPosition = vertices[vertexId].position;
    
    DepthOut out;
    out.ecPosition = uniforms.modelViewMatrix * float4(modelPosition, 1);
    out.position = uniforms.projectionMatrix * out.ecPosition;
    
    return out;
}

fragment float4 fragment_show_depth(DepthOut fragmentIn [[stage_in]], constant Constants &uniforms [[buffer(1)]])
{
    float zEye = fragmentIn.ecPosition.z;
    float zNDC = eyeSpaceDepthToNDC(zEye, uniforms.cameraNear, uniforms.cameraFar);
    float zBuf = ndcDepthToDepthBuf(zNDC);
    
    return float4(zBuf, zBuf, zBuf, 1);
}

//Z in Normalized Device Coordinates
//http://www.songho.ca/opengl/gl_projectionmatrix.html
float eyeSpaceDepthToNDC(float zEye, float near, float far) {
    float A = -(far + near) / (far - near); //projectionMatrix[2].z
    float B = -2.0 * far * near / (far - near); //projectionMatrix[3].z;

    float zNDC = (A * zEye + B) / -zEye;
    return zNDC;
}


//depth buffer encoding
//http://stackoverflow.com/questions/6652253/getting-the-true-z-value-from-the-depth-buffer
float ndcDepthToDepthBuf(float zNDC) {
    return 0.5 * zNDC + 0.5;
}
*/
