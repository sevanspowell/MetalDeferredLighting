/*
    Copyright (C) 2016 Apple Inc. All Rights Reserved.
    See LICENSE.txt for this sample’s licensing information
    
    Abstract:
    The Renderer class. This is the reason for the sample. Here you'll find all the detail about how to setup and interact with Metal types to render content to the screen. This type conforms to MTKViewDelegate and performs the rendering in the appropriate call backs. It is created in the ViewController.viewDidLoad() method.
*/

import Metal
import simd
import MetalKit

struct Constants {
    var modelViewProjectionMatrix = matrix_identity_float4x4
    var normalMatrix = matrix_identity_float3x3
    var modelViewMatrix = matrix_identity_float4x4
    var projectionMatrix = matrix_identity_float4x4
    var modelMatrix = matrix_identity_float4x4
    var near = Float(0.0)
    var far = Float(1.0)
}

struct LightFragmentInput {
    var screenSize = float2(1, 1)
}

struct PointLight {
    var worldPosition = float3(0.0, 0.0, 0.0)
    var attenuationConstant = Float(1.0)
    var attenuationLinear = Float(0.7)
    var attenuationExp = Float(1.8)
    var color = float3(0.0, 0.0, 0.0)
    var radius = Float(1.0)
}

@objc
class Renderer : NSObject, MTKViewDelegate
{
    weak var view: MTKView!

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let sampler: MTLSamplerState
    let cubeTexture: MTLTexture
    let mesh: Mesh
    let lightSphere: Mesh
    let quadPositionBuffer: MTLBuffer

    var time = TimeInterval(0.0)
    var constants = Constants()

    var camPos = float3(0, 0, 2.5)
    var camSpeed = 0.2
    
    var gBufferAlbedoTexture: MTLTexture
    var gBufferNormalTexture: MTLTexture
    var gBufferDepthTexture: MTLTexture
    var gBufferPositionTexture: MTLTexture
    let gBufferDepthStencilState: MTLDepthStencilState
    var gBufferRenderPassDescriptor: MTLRenderPassDescriptor
    let gBufferRenderPipeline: MTLRenderPipelineState
    
    let lightVolumeDepthStencilState: MTLDepthStencilState
    var lightVolumeRenderPassDescriptor: MTLRenderPassDescriptor = MTLRenderPassDescriptor()
    let lightVolumeRenderPipeline: MTLRenderPipelineState
    let lightVolumeSampler: MTLSamplerState
    
    let lightNumber = 3
    var lightConstants = [Constants]()
    var lightFragmentInput = LightFragmentInput()
    var lights = [PointLight]()
    var lightAngle = [Float]()
    var lightRadius = [Float]()
    var lightRate = [Float]()
    
    let stencilPassDepthStencilState: MTLDepthStencilState
    let stencilRenderPassDescriptor: MTLRenderPassDescriptor
    let stencilRenderPipeline: MTLRenderPipelineState
    
    var compositeTexture: MTLTexture
    
    init?(mtkView: MTKView) {
        
        view = mtkView
        
        // Use 4x MSAA multisampling
        view.sampleCount = 1
        // Clear to solid white
        view.clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1)
        // Use a BGRA 8-bit normalized texture for the drawable
        view.colorPixelFormat = .bgra8Unorm
        // Use a 32-bit depth buffer
        view.depthStencilPixelFormat = .depth32Float
        
        // Ask for the default Metal device; this represents our GPU.
        if let defaultDevice = MTLCreateSystemDefaultDevice() {
            device = defaultDevice
        }
        else {
            print("Metal is not supported")
            return nil
        }
        
        // Create the command queue we will be using to submit work to the GPU.
        commandQueue = device.makeCommandQueue()
        commandQueue.label = "Command Queue master"

        for _ in 0...(lightNumber - 1) {
            lights.append(PointLight())
            lightConstants.append(Constants())
            lightAngle.append(0.0)
            lightRadius.append(0.0)
            lightRate.append(0)
        }
        
        lightAngle[0] = Float.pi/2
        lightRadius[0] = 2.0
        lightRate[0] = 1.0
        lights[0].color = float3(1.0, 0.0, 0.0)
        lights[0].attenuationConstant = 0.1
        lights[0].attenuationLinear = 1
        lights[0].attenuationExp = 5
        
        lightAngle[1] = 0
        lightRadius[1] = 2.0
        lightRate[1] = 1.5
        lights[1].color = float3(0.0, 1.0, 0.0)
        lights[1].attenuationConstant = 0.1
        lights[1].attenuationLinear = 1
        lights[1].attenuationExp = 5

        lightAngle[2] = Float.pi
        lightRadius[2] = 2.0
        lightRate[2] = 1.3
        lights[2].color = float3(0.0, 0.0, 1.0)
        lights[2].attenuationConstant = 0.1
        lights[2].attenuationLinear = 1
        lights[2].attenuationExp = 5
        
        /*
        lights[2].worldPosition = float3(-0.4, 0, 1.3)
        lights[2].color = float3(0.0, 0.0, 0.5)
        lights[2].attenuationConstant = 0.1
        lights[2].attenuationLinear = 0.6
        lights[2].attenuationExp = 9
        */
        
        for i in 0...(lightNumber - 1) {
            let lightMax: Float = max(max(lights[i].color.x, lights[i].color.y), lights[i].color.z)
            let lightRadius: Float = (-lights[i].attenuationLinear + sqrt(lights[i].attenuationLinear * lights[i].attenuationLinear - 4 * lights[i].attenuationExp * (lights[i].attenuationConstant - (256.0/5.0) * lightMax))) / (2.0 * lights[i].attenuationExp)
            lights[i].radius = lightRadius
            print(lightRadius)
        }
        
        lightSphere = Mesh(sphereWithSize: 1.0, device: device)!
        
        mesh = Mesh(sphereWithSize: 1.0, device: device)!
        
        do {
            cubeTexture = try Renderer.buildTexture(name: "checkerboard", device)
        }
        catch {
            print("Unable to load texture from main bundle")
            return nil
        }
        
        let width = Int(self.view.drawableSize.width)
        let height = Int(self.view.drawableSize.height)
        let library = device.newDefaultLibrary()!
        
        // GBUFFER
        // Build gBuffer textures
        // Albedo
        let albedoDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        albedoDesc.sampleCount = 1
        albedoDesc.storageMode = .private
        albedoDesc.textureType = .type2D
        albedoDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferAlbedoTexture = device.makeTexture(descriptor: albedoDesc)
        
        // Normal
        let normalDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        normalDesc.sampleCount = 1
        normalDesc.storageMode = .private
        normalDesc.textureType = .type2D
        normalDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferNormalTexture = device.makeTexture(descriptor: normalDesc)
        
        // Depth
        let depthDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
        depthDesc.sampleCount = 1
        depthDesc.storageMode = .private
        depthDesc.textureType = .type2D
        depthDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferDepthTexture = device.makeTexture(descriptor: depthDesc)
        
        // Position
        let posDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        posDesc.sampleCount = 1
        posDesc.storageMode = .private
        posDesc.textureType = .type2D
        posDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferPositionTexture = device.makeTexture(descriptor: posDesc)
        
        // Clear
        let clearDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        clearDesc.sampleCount = 1
        clearDesc.storageMode = .private
        clearDesc.textureType = .type2D
        clearDesc.usage = [.renderTarget, .shaderRead]
        
        compositeTexture = device.makeTexture(descriptor: clearDesc)
        
        // Build gBuffer depth stencil state
        let depthStencilStateDesc: MTLDepthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilStateDesc.isDepthWriteEnabled = true
        depthStencilStateDesc.depthCompareFunction = .lessEqual
        depthStencilStateDesc.frontFaceStencil = nil
        depthStencilStateDesc.backFaceStencil = nil
        gBufferDepthStencilState = device.makeDepthStencilState(descriptor: depthStencilStateDesc)
        
        // Build gBuffer render pass descriptor
        gBufferRenderPassDescriptor = MTLRenderPassDescriptor()
        gBufferRenderPassDescriptor.colorAttachments[1].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1.0)
        gBufferRenderPassDescriptor.colorAttachments[1].texture = gBufferAlbedoTexture
        gBufferRenderPassDescriptor.colorAttachments[1].loadAction = .clear
        gBufferRenderPassDescriptor.colorAttachments[1].storeAction = .store
        
        gBufferRenderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        gBufferRenderPassDescriptor.colorAttachments[0].texture = gBufferNormalTexture
        gBufferRenderPassDescriptor.colorAttachments[0].loadAction = .clear
        gBufferRenderPassDescriptor.colorAttachments[0].storeAction = .store
        
        gBufferRenderPassDescriptor.colorAttachments[2].clearColor = MTLClearColorMake(0, 0, 0, 1)
        gBufferRenderPassDescriptor.colorAttachments[2].texture = gBufferPositionTexture
        gBufferRenderPassDescriptor.colorAttachments[2].loadAction = .clear
        gBufferRenderPassDescriptor.colorAttachments[2].storeAction = .store
        
        gBufferRenderPassDescriptor.colorAttachments[3].clearColor = MTLClearColorMake(0, 0, 0, 1)
        gBufferRenderPassDescriptor.colorAttachments[3].texture = compositeTexture
        gBufferRenderPassDescriptor.colorAttachments[3].loadAction = .clear
        gBufferRenderPassDescriptor.colorAttachments[3].storeAction = .store
        
        gBufferRenderPassDescriptor.depthAttachment.loadAction = .clear
        gBufferRenderPassDescriptor.depthAttachment.storeAction = .store
        gBufferRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        gBufferRenderPassDescriptor.depthAttachment.clearDepth = 1.0
        
        gBufferRenderPassDescriptor.stencilAttachment.loadAction = .clear
        gBufferRenderPassDescriptor.stencilAttachment.storeAction = .store
        gBufferRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture
        gBufferRenderPassDescriptor.stencilAttachment.clearStencil = 0
        
        // Build gBuffer render pipeline
        let gBufferRenderPipelineDesc = MTLRenderPipelineDescriptor()
        gBufferRenderPipelineDesc.colorAttachments[1].pixelFormat = .rgba8Unorm
        gBufferRenderPipelineDesc.colorAttachments[0].pixelFormat = .rgba16Float
        gBufferRenderPipelineDesc.colorAttachments[2].pixelFormat = .rgba16Float
        gBufferRenderPipelineDesc.colorAttachments[3].pixelFormat = .bgra8Unorm
        gBufferRenderPipelineDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        gBufferRenderPipelineDesc.stencilAttachmentPixelFormat = .depth32Float_stencil8
        gBufferRenderPipelineDesc.sampleCount = 1
        gBufferRenderPipelineDesc.label = "GBuffer Render"
        gBufferRenderPipelineDesc.vertexFunction = library.makeFunction(name: "gBufferVert")
        gBufferRenderPipelineDesc.fragmentFunction = library.makeFunction(name: "gBufferFrag")
        do {
            try gBufferRenderPipeline = device.makeRenderPipelineState(descriptor: gBufferRenderPipelineDesc)
        } catch let error {
            fatalError("Failed to create GBuffer pipeline state, error \(error)")
        }
        
        // Decrement when front faces depth fail
        let frontFaceStencilOp: MTLStencilDescriptor = MTLStencilDescriptor()
        frontFaceStencilOp.stencilCompareFunction = .always        // Stencil test always succeeds, only concerned about depth test
        frontFaceStencilOp.stencilFailureOperation = .keep         // Stencil test always succeeds
        frontFaceStencilOp.depthStencilPassOperation = .keep       // Do nothing if depth test passes
        frontFaceStencilOp.depthFailureOperation = .decrementWrap // Decrement if depth test fails
        
        // Increment when back faces depth fail
        let backFaceStencilOp: MTLStencilDescriptor = MTLStencilDescriptor()
        backFaceStencilOp.stencilCompareFunction = .always        // Stencil test always succeeds, only concerned about depth test
        backFaceStencilOp.stencilFailureOperation = .keep         // Stencil test always succeeds
        backFaceStencilOp.depthStencilPassOperation = .keep       // Do nothing if depth test passes
        backFaceStencilOp.depthFailureOperation = .incrementWrap // Increment if depth test fails
        
        let stencilPassDepthStencilStateDesc: MTLDepthStencilDescriptor = MTLDepthStencilDescriptor()
        stencilPassDepthStencilStateDesc.isDepthWriteEnabled = false           // Only concerned with modifying stencil buffer
        stencilPassDepthStencilStateDesc.depthCompareFunction = .lessEqual     // Only perform stencil op when depth function fails
        stencilPassDepthStencilStateDesc.frontFaceStencil = frontFaceStencilOp // For front-facing polygons
        stencilPassDepthStencilStateDesc.backFaceStencil = backFaceStencilOp   // For back-facing polygons
        stencilPassDepthStencilState = device.makeDepthStencilState(descriptor: stencilPassDepthStencilStateDesc)
        
        // Build light volume depth-stencil state
        let lightVolumeStencilOp: MTLStencilDescriptor = MTLStencilDescriptor()
        lightVolumeStencilOp.stencilCompareFunction = .notEqual           // Only pass if not equal to reference value (ref. value is 0)
        lightVolumeStencilOp.stencilFailureOperation = .keep              // Don't modify stencil value at all
        lightVolumeStencilOp.depthStencilPassOperation = .keep
        lightVolumeStencilOp.depthFailureOperation = .keep                // Depth test is set to always succeed
        
        let lightVolumeDepthStencilStateDesc: MTLDepthStencilDescriptor = MTLDepthStencilDescriptor()
        lightVolumeDepthStencilStateDesc.isDepthWriteEnabled = false       // Don't modify depth buffer
        lightVolumeDepthStencilStateDesc.depthCompareFunction = .always // Stencil buffer will be used to determine if we should light this fragment, ignore depth value
        lightVolumeDepthStencilStateDesc.backFaceStencil = lightVolumeStencilOp
        lightVolumeDepthStencilStateDesc.frontFaceStencil = lightVolumeStencilOp
        lightVolumeDepthStencilState = device.makeDepthStencilState(descriptor: lightVolumeDepthStencilStateDesc)
        
        // Build light volume render pass descriptor
        // Get current render pass descriptor instead
        lightVolumeRenderPassDescriptor = MTLRenderPassDescriptor()
        lightVolumeRenderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.0, 0.0, 0.0, 1)
        lightVolumeRenderPassDescriptor.colorAttachments[0].texture = compositeTexture
        lightVolumeRenderPassDescriptor.colorAttachments[0].loadAction = .load // Each light volume is additive
        lightVolumeRenderPassDescriptor.colorAttachments[0].storeAction = .store
        lightVolumeRenderPassDescriptor.depthAttachment.clearDepth = 1.0
        //lightVolumeRenderPassDescriptor.depthAttachment.loadAction = .load
        //lightVolumeRenderPassDescriptor.depthAttachment.storeAction = .store
        //lightVolumeRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        lightVolumeRenderPassDescriptor.stencilAttachment.loadAction = .load
        lightVolumeRenderPassDescriptor.stencilAttachment.storeAction = .dontCare
        lightVolumeRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture
        
        // Build light volume render pipeline
        let lightVolumeRenderPipelineDesc = MTLRenderPipelineDescriptor()
        lightVolumeRenderPipelineDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        lightVolumeRenderPipelineDesc.colorAttachments[0].isBlendingEnabled = true
        lightVolumeRenderPipelineDesc.colorAttachments[0].rgbBlendOperation = .add
        lightVolumeRenderPipelineDesc.colorAttachments[0].sourceRGBBlendFactor = .one
        lightVolumeRenderPipelineDesc.colorAttachments[0].destinationRGBBlendFactor = .one
        lightVolumeRenderPipelineDesc.colorAttachments[0].alphaBlendOperation = .add
        lightVolumeRenderPipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = .one
        lightVolumeRenderPipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = .one
        lightVolumeRenderPipelineDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        lightVolumeRenderPipelineDesc.stencilAttachmentPixelFormat = .depth32Float_stencil8
        lightVolumeRenderPipelineDesc.sampleCount = 1
        lightVolumeRenderPipelineDesc.label = "Light Volume Render"
        lightVolumeRenderPipelineDesc.vertexFunction = library.makeFunction(name: "lightVolumeVert")
        lightVolumeRenderPipelineDesc.fragmentFunction = library.makeFunction(name: "lightVolumeFrag")
        do {
            try lightVolumeRenderPipeline = device.makeRenderPipelineState(descriptor: lightVolumeRenderPipelineDesc)
        } catch let error {
            fatalError("Failed to create lightVolume pipeline state, error \(error)")
        }
        
        let stencilRenderPipelineDesc = MTLRenderPipelineDescriptor()
        stencilRenderPipelineDesc.label = "Stencil Pipeline"
        stencilRenderPipelineDesc.sampleCount = view.sampleCount
        stencilRenderPipelineDesc.vertexFunction = library.makeFunction(name: "lightVolumeVert")
        stencilRenderPipelineDesc.fragmentFunction = library.makeFunction(name: "lightVolumeNullFrag")
        stencilRenderPipelineDesc.depthAttachmentPixelFormat = .depth32Float_stencil8
        stencilRenderPipelineDesc.stencilAttachmentPixelFormat = .depth32Float_stencil8
        do {
            try stencilRenderPipeline = device.makeRenderPipelineState(descriptor: stencilRenderPipelineDesc)
        } catch let error {
            fatalError("Failed to create Stencil pipeline state, error \(error)")
        }
        
        stencilRenderPassDescriptor = MTLRenderPassDescriptor()
        stencilRenderPassDescriptor.depthAttachment.loadAction = .load
        stencilRenderPassDescriptor.depthAttachment.storeAction = .store
        stencilRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        stencilRenderPassDescriptor.stencilAttachment.loadAction = .clear
        stencilRenderPassDescriptor.stencilAttachment.storeAction = .store
        stencilRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture
    
        // Make a texture sampler that wraps in both directions and performs bilinear filtering
        sampler = Renderer.buildSamplerStateWithDevice(device, addressMode: .repeat, filter: .linear)
        lightVolumeSampler = Renderer.buildSamplerStateWithDevice(device, addressMode: .repeat, filter: .nearest)
        
        // Create quad
        //All the combinations of quads needed.
        let quadVerts: [Float] =
            [
                -1.0, 1.0,
                1.0, -1.0,
                -1.0, -1.0,
                -1.0, 1.0,
                1.0, 1.0,
                1.0, -1.0,
                
                -1.0, 1.0,
                0.0, 0.0,
                -1.0, 0.0,
                -1.0, 1.0,
                0.0, 1.0,
                0.0, 0.0,
                
                0.0, 1.0,
                1.0, 0.0,
                0.0, 0.0,
                0.0, 1.0,
                1.0, 1.0,
                1.0, 0.0,
                
                -1.0, 0.0,
                0.0, -1.0,
                -1.0, -1.0,
                -1.0, 0.0,
                0.0, 0.0,
                0.0, -1.0,
                
                0.0, 0.0,
                1.0, -1.0,
                0.0, -1.0,
                0.0, 0.0,
                1.0, 0.0,
                1.0, -1.0,
                
        ];
        
        quadPositionBuffer = device.makeBuffer(bytes: quadVerts, length:quadVerts.count * MemoryLayout<Float>.size, options: []);
        
        lightFragmentInput.screenSize.x = Float(view.drawableSize.width)
        lightFragmentInput.screenSize.y = Float(view.drawableSize.height)
        
        super.init()
        
        // Now that all of our members are initialized, set ourselves as the drawing delegate of the view
        view.delegate = self
        view.device = device
    }

    class func buildTexture(name: String, _ device: MTLDevice) throws -> MTLTexture {
        let textureLoader = MTKTextureLoader(device: device)
        let asset = NSDataAsset.init(name: name)
        if let data = asset?.data {
            return try textureLoader.newTexture(with: data, options: [:])
        } else {
            fatalError("Could not load image \(name) from an asset catalog in the main bundle")
        }
    }
    
    class func buildSamplerStateWithDevice(_ device: MTLDevice,
                                           addressMode: MTLSamplerAddressMode,
                                           filter: MTLSamplerMinMagFilter) -> MTLSamplerState
    {
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.sAddressMode = addressMode
        samplerDescriptor.tAddressMode = addressMode
        samplerDescriptor.minFilter = filter
        samplerDescriptor.magFilter = filter
        return device.makeSamplerState(descriptor: samplerDescriptor)
    }
    
    func calcCartesianPositionFromPolar(angle: Float, radius: Float) -> float3 {
        return float3(radius * cos(angle), radius * sin(angle), 1.0)
    }
    
    func updateWithTimestep(_ timestep: TimeInterval)
    {
        // We keep track of time so we can animate the various transformations
        time = time + timestep
        //time = 1.0
        
        let modelToWorldMatrix = matrix4x4_rotation(Float(time) * 0.5, vector_float3(0.7, 1, 0))
        
        // So that the figure doesn't get distorted when the window changes size or rotates,
        // we factor the current aspect ration into our projection matrix. We also select
        // sensible values for the vertical view angle and the distances to the near and far planes.
        //let viewSize = self.view.bounds.size
        let aspectRatio = Float(view.drawableSize.width / view.drawableSize.height)
        let verticalViewAngle = radians_from_degrees(65)
        let nearZ: Float = 0.1
        let farZ: Float = 100.0
        let projectionMatrix = matrix_perspective(verticalViewAngle, aspectRatio, nearZ, farZ)
        
        let viewMatrix = matrix_look_at(camPos.x, camPos.y, camPos.z, 0, 0, 0, 0, 1, 0)
        
        // The combined model-view-projection matrix moves our vertices from model space into clip space
        var mvMatrix = matrix_multiply(viewMatrix, modelToWorldMatrix);
        constants.modelViewProjectionMatrix = matrix_multiply(projectionMatrix, mvMatrix)
        constants.normalMatrix = matrix_inverse_transpose(matrix_upper_left_3x3(mvMatrix))
        constants.modelViewMatrix = mvMatrix;
        constants.projectionMatrix = projectionMatrix;
        constants.modelMatrix = modelToWorldMatrix;
        constants.near = nearZ;
        constants.far = farZ;

        for i in 0...(lightNumber-1) {
            // Move lights
            lightAngle[i] += Float(timestep) * 0.5 * lightRate[i]
            lights[i].worldPosition = calcCartesianPositionFromPolar(angle: lightAngle[i], radius: lightRadius[i])
            //lights[i].worldPosition = float3(0, 0.4, 0)

            let lightModelToWorldMatrix = matrix_multiply(matrix4x4_translation(lights[i].worldPosition.x, lights[i].worldPosition.y, lights[i].worldPosition.z), matrix4x4_scale(vector3(lights[i].radius, lights[i].radius, lights[i].radius)))
            mvMatrix = matrix_multiply(viewMatrix, lightModelToWorldMatrix);
            lightConstants[i].modelViewProjectionMatrix = matrix_multiply(projectionMatrix, mvMatrix)
            lightConstants[i].normalMatrix = matrix_inverse_transpose(matrix_upper_left_3x3(mvMatrix))
            lightConstants[i].modelViewMatrix = mvMatrix;
            lightConstants[i].projectionMatrix = projectionMatrix;
            lightConstants[i].modelMatrix = lightModelToWorldMatrix;
            lightConstants[i].near = nearZ;
            lightConstants[i].far = farZ;
        }
    }

    func render(_ view: MTKView) {
        // Our animation will be dependent on the frame time, so that regardless of how
        // fast we're animating, the speed of the transformations will be roughly constant.
        let timestep = 1.0 / TimeInterval(view.preferredFramesPerSecond)
        updateWithTimestep(timestep)
        
        // Our command buffer is a container for the  work we want to perform with the GPU.
        let commandBuffer = commandQueue.makeCommandBuffer()
        
        let currDrawable = view.currentDrawable
        
        //gBufferRenderPassDescriptor.colorAttachments[3].texture = currDrawable?.texture
        //print(gBufferRenderPassDescriptor.colorAttachments[3].texture)
        let gBufferEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: gBufferRenderPassDescriptor)
        gBufferEncoder.pushDebugGroup("GBuffer")
        gBufferEncoder.label = "GBuffer"
        gBufferEncoder.setDepthStencilState(gBufferDepthStencilState)
        gBufferEncoder.setCullMode(.back)
        gBufferEncoder.setFrontFacing(.counterClockwise)
        gBufferEncoder.setRenderPipelineState(gBufferRenderPipeline)
        gBufferEncoder.setVertexBuffer(mesh.vertexBuffer, offset:0, at:0)
        gBufferEncoder.setVertexBytes(&constants, length: MemoryLayout<Constants>.size, at: 1)
        gBufferEncoder.setFragmentTexture(cubeTexture, at: 0)
        gBufferEncoder.setFragmentSamplerState(sampler, at: 0)
        gBufferEncoder.drawIndexedPrimitives(type: mesh.primitiveType,
                                            indexCount: mesh.indexCount,
                                            indexType: mesh.indexType,
                                            indexBuffer: mesh.indexBuffer,
                                            indexBufferOffset: 0)
        gBufferEncoder.popDebugGroup()
        gBufferEncoder.endEncoding()

        commandBuffer.commit()

        
        let stencilPassCommandBuffer = commandQueue.makeCommandBuffer()
        
        // Perform stencil pass for each light
        for i in 0...(lightNumber - 1) {
            var stencilPassEncoder = stencilPassCommandBuffer.makeRenderCommandEncoder(descriptor: stencilRenderPassDescriptor)
            stencilPassEncoder.pushDebugGroup("Stencil Pass")
            stencilPassEncoder.label = "Stencil Pass"
            stencilPassEncoder.setDepthStencilState(stencilPassDepthStencilState)
            stencilPassEncoder.setCullMode(.none)
            stencilPassEncoder.setFrontFacing(.counterClockwise)
            stencilPassEncoder.setRenderPipelineState(stencilRenderPipeline)
            stencilPassEncoder.setVertexBuffer(lightSphere.vertexBuffer, offset:0, at:0)
            stencilPassEncoder.setFragmentBytes(&lightFragmentInput, length: MemoryLayout<LightFragmentInput>.size, at: 0)
            
            stencilPassEncoder.setVertexBytes(&lightConstants[i], length: MemoryLayout<Constants>.size, at: 1)
            stencilPassEncoder.drawIndexedPrimitives(type: lightSphere.primitiveType, indexCount: lightSphere.indexCount, indexType: lightSphere.indexType, indexBuffer: lightSphere.indexBuffer, indexBufferOffset: 0)
            
            stencilPassEncoder.popDebugGroup()
            stencilPassEncoder.endEncoding()
        }

        stencilPassCommandBuffer.commit()
    
        
        let commandBuffer2 = commandQueue.makeCommandBuffer()
        //lightVolumeRenderPassDescriptor.colorAttachments[0].texture = currDrawable?.texture
        //print(lightVolumeRenderPassDescriptor.colorAttachments[0].texture)
        
        for i in 0...(lightNumber - 1) {
            var lightEncoder = commandBuffer2.makeRenderCommandEncoder(descriptor: lightVolumeRenderPassDescriptor)
            lightEncoder.pushDebugGroup("Light Volume Pass")
            lightEncoder.label = "Light Volume Pass"
            lightEncoder.setDepthStencilState(lightVolumeDepthStencilState)
            lightEncoder.setStencilReferenceValue(0)
            lightEncoder.setCullMode(.front)
            lightEncoder.setFrontFacing(.counterClockwise)
            lightEncoder.setRenderPipelineState(lightVolumeRenderPipeline)
            lightEncoder.setFragmentTexture(gBufferAlbedoTexture, at: 0)
            lightEncoder.setFragmentSamplerState(lightVolumeSampler, at: 0)
            lightEncoder.setFragmentTexture(gBufferNormalTexture, at: 1)
            lightEncoder.setFragmentSamplerState(lightVolumeSampler, at: 1)
            lightEncoder.setFragmentTexture(gBufferPositionTexture, at: 2)
            lightEncoder.setFragmentSamplerState(lightVolumeSampler, at: 2)
            lightEncoder.setVertexBuffer(lightSphere.vertexBuffer, offset:0, at:0)
            lightEncoder.setFragmentBytes(&lightFragmentInput, length: MemoryLayout<LightFragmentInput>.size, at: 0)

            lightEncoder.setVertexBytes(&lightConstants[i], length: MemoryLayout<Constants>.size, at: 1)
            lightEncoder.setFragmentBytes(&lights[i], length: MemoryLayout<PointLight>.size, at: 1)
            lightEncoder.drawIndexedPrimitives(type: lightSphere.primitiveType, indexCount: lightSphere.indexCount, indexType: lightSphere.indexType, indexBuffer: lightSphere.indexBuffer, indexBufferOffset: 0)

            lightEncoder.popDebugGroup()
            lightEncoder.endEncoding()
        }

        commandBuffer2.commit()
        
        let commandBuffer3 = commandQueue.makeCommandBuffer()
        var blitEncoder = commandBuffer3.makeBlitCommandEncoder()
        blitEncoder.pushDebugGroup("Final Pass")
        let origin: MTLOrigin = MTLOriginMake(0, 0, 0)
        let size: MTLSize = MTLSizeMake(Int(self.view.drawableSize.width), Int(self.view.drawableSize.height), 1)
        //let size: MTLSize = MTLSizeMake(Int(512), Int(512), 1)
        blitEncoder.copy(from: compositeTexture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: origin, sourceSize: size, to: (currDrawable?.texture)!, destinationSlice: 0, destinationLevel: 0, destinationOrigin: origin)
        blitEncoder.endEncoding()
        blitEncoder.popDebugGroup()

        if let drawable = currDrawable
        {
            commandBuffer3.present(drawable)
        }

        commandBuffer3.commit()
    }
    
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        let width = Int(size.width);
        let height = Int(size.height);
        
        print(width)
        print(height)
        
        lightFragmentInput.screenSize.x = Float(width)
        lightFragmentInput.screenSize.y = Float(height)
        
        let albedoDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        albedoDesc.sampleCount = 1
        albedoDesc.storageMode = .private
        albedoDesc.textureType = .type2D
        albedoDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferAlbedoTexture = device.makeTexture(descriptor: albedoDesc)
        
        // Normal
        let normalDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        normalDesc.sampleCount = 1
        normalDesc.storageMode = .private
        normalDesc.textureType = .type2D
        normalDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferNormalTexture = device.makeTexture(descriptor: normalDesc)
        
        // Depth
        let depthDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float_stencil8, width: width, height: height, mipmapped: false)
        depthDesc.sampleCount = 1
        depthDesc.storageMode = .private
        depthDesc.textureType = .type2D
        depthDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferDepthTexture = device.makeTexture(descriptor: depthDesc)
        
        // Position
        let posDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
        posDesc.sampleCount = 1
        posDesc.storageMode = .private
        posDesc.textureType = .type2D
        posDesc.usage = [.renderTarget, .shaderRead]
        
        gBufferPositionTexture = device.makeTexture(descriptor: posDesc)
        
        // Clear
        let clearDesc: MTLTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        clearDesc.sampleCount = 1
        clearDesc.storageMode = .private
        clearDesc.textureType = .type2D
        clearDesc.usage = [.renderTarget, .shaderRead]
        
        compositeTexture = device.makeTexture(descriptor: clearDesc)
        
        gBufferRenderPassDescriptor.colorAttachments[1].texture = gBufferAlbedoTexture

        gBufferRenderPassDescriptor.colorAttachments[0].texture = gBufferNormalTexture

        gBufferRenderPassDescriptor.colorAttachments[2].texture = gBufferPositionTexture

        gBufferRenderPassDescriptor.colorAttachments[3].texture = compositeTexture

        gBufferRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture

        gBufferRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture

        lightVolumeRenderPassDescriptor.colorAttachments[0].texture = compositeTexture

        lightVolumeRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        
        lightVolumeRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture
        
        stencilRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
        
        stencilRenderPassDescriptor.stencilAttachment.texture = gBufferDepthTexture

        //compositeRenderPassDescriptor.depthAttachment.texture = gBufferDepthTexture
    }

    @objc(drawInMTKView:)
    func draw(in metalView: MTKView)
    {
        render(metalView)
    }
}
