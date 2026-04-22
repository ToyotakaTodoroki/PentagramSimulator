import Foundation
import Metal
import MetalKit
import simd

// MARK: - GPU Data Structures (must match Metal shaders)

/// Particle data structure for GPU
struct GPUParticle {
    var positionMass: SIMD4<Float>    // xyz: position, w: mass
    var velocityAge: SIMD4<Float>     // xyz: velocity, w: age
    var elementWeights: SIMD4<Float>  // wood, fire, earth, metal (water = 1 - sum)
    var metadata: SIMD4<Float>        // x: generation, y: attractorMemory, z: predictability, w: unused
}

/// Simulation parameters for GPU
struct SimulationParams {
    var deltaTime: Float
    var globalTime: Float
    var transitionRate: Float
    var attractorStrength: Float
    var interactionRadius: Float
    var generationRate: Float
    var particleCount: UInt32
    var frameIndex: UInt32
    var gogyoStrength: Float          // 五行 interaction strength
    var temperature: Float            // annealing temperature
    var latticeStrength: Float        // strength of lattice-forming forces

    // Sphere Lattice parameters
    var sphereRadius: Float
    var sphereAttractionStrength: Float
    var sphereRepulsionStrength: Float
    var sphereLatticeEnabled: Bool

    // Localized Regions parameters
    var numSpatialRegions: UInt32

    // Configurable Grid Size
    var currentGridSize: UInt32
    var gridTotal: UInt32
}

// MARK: - Spatial Region Structure
struct SpatialRegion {
    var center: SIMD3<Float>
    var radius: Float
    var gogyoStrength: Float
    var temperature: Float
    var latticeStrength: Float
}

/// Render parameters for GPU
struct RenderParams {
    var viewProjection: simd_float4x4
    var cameraPosition: SIMD3<Float>
    var time: Float
    var particleScale: Float
    var bifurcationIntensity: Float
    var _padding: SIMD2<Float> = .zero
}

// MARK: - Grid Constants (must match shader)

private let gridChannels: Int = 6  // wood, fire, earth, metal, water, count

// MARK: - Particle Renderer

public class ParticleRenderer: NSObject, MTKViewDelegate {

    // MARK: - Properties

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var particleBuffer: MTLBuffer?
    private var particleBufferB: MTLBuffer?  // Double buffering
    private var useBufferA = true

    // Grid buffer for 五行 spatial interaction
    private var gridBuffer: MTLBuffer?

    // Pipeline states
    private var computePipelineState: MTLComputePipelineState?
    private var clearGridPipelineState: MTLComputePipelineState?
    private var accumulateGridPipelineState: MTLComputePipelineState?
    private var renderPipelineState: MTLRenderPipelineState?
    private var postProcessPipelineState: MTLComputePipelineState?

    private var simulationParams = SimulationParams(
        deltaTime: 1.0 / 60.0,
        globalTime: 0,
        transitionRate: 0.1,
        attractorStrength: 0.5,
        interactionRadius: 0.5,
        generationRate: 0.8,
        particleCount: 100_000,
        frameIndex: 0,
        gogyoStrength: 1.0,
        temperature: 0.01,
        latticeStrength: 1.0,

        // Sphere Lattice default parameters
        sphereRadius: 5.0,
        sphereAttractionStrength: 0.5, // Increased default
        sphereRepulsionStrength: 0.2,  // Increased default
        sphereLatticeEnabled: false,

        // Localized Regions default parameters
        numSpatialRegions: 0,

        // Configurable Grid Size
        currentGridSize: 32,
        gridTotal: 0
    )

    private var renderParams = RenderParams(
        viewProjection: matrix_identity_float4x4,
        cameraPosition: SIMD3<Float>(0, 0, 30),
        time: 0,
        particleScale: 3.0,
        bifurcationIntensity: 1.0
    )

    private var cameraAngle: Float = 0
    private var cameraDistance: Float = 30
    private var cameraHeight: Float = 10

    public var particleCount: Int = 100_000 {
        didSet {
            simulationParams.particleCount = UInt32(particleCount)
            initializeParticleBuffers()
        }
    }

    public var collapseIntensity: Float = 0  // For visualizing linear→attractor collapse

    public var onElementDistributionUpdate: (([Float]) -> Void)?
    public var onGenerationUpdate: ((Float, Float) -> Void)?

    // MARK: - Initialization

    public init?(metalKitView: MTKView) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal is not supported on this device")
            return nil
        }

        self.device = device
        metalKitView.device = device
        metalKitView.colorPixelFormat = .bgra8Unorm
        metalKitView.depthStencilPixelFormat = .depth32Float

        guard let commandQueue = device.makeCommandQueue() else {
            print("Failed to create command queue")
            return nil
        }
        self.commandQueue = commandQueue

        // Set initial temperature to a reasonable default
        simulationParams.temperature = 0.5 

        super.init()

        metalKitView.delegate = self

        setupPipelines()
        initializeParticleBuffers()
        initializeGridBuffer()
    }

    // MARK: - Setup

    private func setupPipelines() {
        // Compile shaders from source at runtime
        do {
            let library = try device.makeLibrary(source: metalShaderSource, options: nil)
            setupPipelinesWithLibrary(library)
        } catch {
            print("Failed to compile Metal shaders: \(error)")
        }
    }

    private func setupPipelinesWithLibrary(_ library: MTLLibrary) {
        // Compute pipeline for particle update
        if let updateFunction = library.makeFunction(name: "updateParticles") {
            do {
                computePipelineState = try device.makeComputePipelineState(function: updateFunction)
            } catch {
                print("Failed to create compute pipeline: \(error)")
            }
        }

        // Grid clear pipeline
        if let clearFunction = library.makeFunction(name: "clearGrid") {
            do {
                clearGridPipelineState = try device.makeComputePipelineState(function: clearFunction)
            } catch {
                print("Failed to create clearGrid pipeline: \(error)")
            }
        }

        // Grid accumulate pipeline
        if let accumFunction = library.makeFunction(name: "accumulateGrid") {
            do {
                accumulateGridPipelineState = try device.makeComputePipelineState(function: accumFunction)
            } catch {
                print("Failed to create accumulateGrid pipeline: \(error)")
            }
        }

        // Render pipeline for particles
        let renderDescriptor = MTLRenderPipelineDescriptor()
        renderDescriptor.vertexFunction = library.makeFunction(name: "particleVertex")
        renderDescriptor.fragmentFunction = library.makeFunction(name: "particleFragment")
        renderDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        renderDescriptor.colorAttachments[0].isBlendingEnabled = true
        renderDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        renderDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        renderDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        renderDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        renderDescriptor.depthAttachmentPixelFormat = .depth32Float

        do {
            renderPipelineState = try device.makeRenderPipelineState(descriptor: renderDescriptor)
        } catch {
            print("Failed to create render pipeline: \(error)")
        }

        // Post-process pipeline for collapse visualization
        if let collapseFunction = library.makeFunction(name: "visualizeLinearToAttractorCollapse") {
            do {
                postProcessPipelineState = try device.makeComputePipelineState(function: collapseFunction)
            } catch {
                print("Failed to create post-process pipeline: \(error)")
            }
        }
    }

    private func initializeParticleBuffers() {
        var particles: [GPUParticle] = []
        particles.reserveCapacity(particleCount)

        for _ in 0..<particleCount {
            let position = SIMD3<Float>(
                Float.random(in: -10...10),
                Float.random(in: -10...10),
                Float.random(in: -10...10)
            )
            let velocity = SIMD3<Float>(
                Float.random(in: -1...1),
                Float.random(in: -1...1),
                Float.random(in: -1...1)
            )
            let mass = Float.random(in: 0.5...2.0)
            let purity = Float.random(in: 0.6...0.9)
            let noise = (1.0 - purity) / 4.0

            let particle = GPUParticle(
                positionMass: SIMD4<Float>(position, mass),
                velocityAge: SIMD4<Float>(velocity, 0),
                elementWeights: SIMD4<Float>(purity, noise, noise, noise),  // Start with Wood
                metadata: SIMD4<Float>(0, 0, 0, 0)  // generation=0, memory=0
            )
            particles.append(particle)
        }

        let bufferSize = MemoryLayout<GPUParticle>.stride * particleCount
        particleBuffer = device.makeBuffer(bytes: particles, length: bufferSize, options: .storageModeShared)
        particleBufferB = device.makeBuffer(length: bufferSize, options: .storageModeShared)
    }

    private func initializeGridBuffer() {
        let currentGridSize = simulationParams.currentGridSize
        let calculatedGridTotal = currentGridSize * currentGridSize * currentGridSize
        let bufferSize = Int(calculatedGridTotal) * gridChannels * MemoryLayout<UInt32>.size
        gridBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)
    }

    // MARK: - MTKViewDelegate

    public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Update projection matrix for new aspect ratio
        let aspect = Float(size.width / size.height)
        let fov: Float = .pi / 4
        let near: Float = 0.1
        let far: Float = 100.0

        renderParams.viewProjection = perspectiveMatrix(fov: fov, aspect: aspect, near: near, far: far)
    }

    public func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let currentBuffer = useBufferA ? particleBuffer : particleBufferB,
              let gridBuf = gridBuffer else {
            return
        }

        // Update time
        simulationParams.globalTime += simulationParams.deltaTime
        simulationParams.frameIndex += 1
        renderParams.time = simulationParams.globalTime

        // Rotate camera
        cameraAngle += 0.005
        let cameraX = sin(cameraAngle) * cameraDistance
        let cameraZ = cos(cameraAngle) * cameraDistance
        renderParams.cameraPosition = SIMD3<Float>(cameraX, cameraHeight, cameraZ)

        // Update view matrix
        let viewMatrix = lookAtMatrix(
            eye: renderParams.cameraPosition,
            center: SIMD3<Float>(0, 0, 0),
            up: SIMD3<Float>(0, 1, 0)
        )
        let aspect = Float(view.drawableSize.width / view.drawableSize.height)
        let projectionMatrix = perspectiveMatrix(fov: .pi / 4, aspect: aspect, near: 0.1, far: 100)
        renderParams.viewProjection = projectionMatrix * viewMatrix

        // ==========================================
        // Compute pass: 3-stage pipeline
        // 1. Clear grid
        // 2. Accumulate particle data into grid
        // 3. Update particles (reads grid for 五行 forces)
        // ==========================================
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            let threadsPerGroup = MTLSize(width: 256, height: 1, depth: 1)

            // Stage 1: Clear grid
            if let clearPipeline = clearGridPipelineState {
                computeEncoder.setComputePipelineState(clearPipeline)
                computeEncoder.setBuffer(gridBuf, offset: 0, index: 0)
                computeEncoder.setBytes(&simulationParams, length: MemoryLayout<SimulationParams>.size, index: 1)

                let currentGridSize = simulationParams.currentGridSize
                let calculatedGridTotal = currentGridSize * currentGridSize * currentGridSize
                let gridElements = calculatedGridTotal * UInt32(gridChannels)
                let clearGroups = MTLSize(width: (Int(gridElements) + 255) / 256, height: 1, depth: 1)
                computeEncoder.dispatchThreadgroups(clearGroups, threadsPerThreadgroup: threadsPerGroup)
            }

            // Memory barrier: ensure clear completes before accumulate
            computeEncoder.memoryBarrier(scope: .buffers)

            // Stage 2: Accumulate particles into grid
            if let accumPipeline = accumulateGridPipelineState {
                computeEncoder.setComputePipelineState(accumPipeline)
                computeEncoder.setBuffer(currentBuffer, offset: 0, index: 0)
                computeEncoder.setBuffer(gridBuf, offset: 0, index: 1)
                computeEncoder.setBytes(&simulationParams, length: MemoryLayout<SimulationParams>.size, index: 2)

                let accumGroups = MTLSize(width: (particleCount + 255) / 256, height: 1, depth: 1)
                computeEncoder.dispatchThreadgroups(accumGroups, threadsPerThreadgroup: threadsPerGroup)
            }

            // Memory barrier: ensure accumulate completes before update reads grid
            computeEncoder.memoryBarrier(scope: .buffers)

            // Stage 3: Update particles (with grid-based 五行 interaction)
            if let computePipeline = computePipelineState {
                computeEncoder.setComputePipelineState(computePipeline)
                computeEncoder.setBuffer(currentBuffer, offset: 0, index: 0)
                computeEncoder.setBytes(&simulationParams, length: MemoryLayout<SimulationParams>.size, index: 1)
                computeEncoder.setBuffer(gridBuf, offset: 0, index: 2)

                let updateGroups = MTLSize(width: (particleCount + 255) / 256, height: 1, depth: 1)
                computeEncoder.dispatchThreadgroups(updateGroups, threadsPerThreadgroup: threadsPerGroup)
            }

            computeEncoder.endEncoding()
        }

        // Render pass
        guard let renderPassDescriptor = view.currentRenderPassDescriptor,
              let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor),
              let renderPipeline = renderPipelineState else {
            return
        }

        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1.0)
        renderPassDescriptor.colorAttachments[0].loadAction = .clear

        renderEncoder.setRenderPipelineState(renderPipeline)
        renderEncoder.setVertexBuffer(currentBuffer, offset: 0, index: 0)
        renderEncoder.setVertexBytes(&renderParams, length: MemoryLayout<RenderParams>.size, index: 1)
        renderEncoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        renderEncoder.endEncoding()

        // Present
        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }

        commandBuffer.commit()

        // Swap buffers
        useBufferA.toggle()

        // Periodically calculate element distribution (every 60 frames)
        if simulationParams.frameIndex % 60 == 0 {
            calculateElementDistribution()
        }
    }

    // MARK: - Element Distribution Analysis

    private func calculateElementDistribution() {
        guard let buffer = useBufferA ? particleBuffer : particleBufferB else { return }

        let particlePointer = buffer.contents().bindMemory(to: GPUParticle.self, capacity: particleCount)
        var distribution: [Float] = [0, 0, 0, 0, 0]  // wood, fire, earth, metal, water
        var totalMass: Float = 0
        var totalGeneration: Float = 0
        var totalAttractorMemory: Float = 0

        // Sample a subset for performance (every 10th particle)
        let stride = max(1, particleCount / 10000)
        var sampleCount: Float = 0

        for i in Swift.stride(from: 0, to: particleCount, by: stride) {
            let particle = particlePointer[i]
            let mass = particle.positionMass.w
            let weights = particle.elementWeights
            let waterWeight = max(0, 1.0 - weights.x - weights.y - weights.z - weights.w)

            distribution[0] += weights.x * mass  // wood
            distribution[1] += weights.y * mass  // fire
            distribution[2] += weights.z * mass  // earth
            distribution[3] += weights.w * mass  // metal
            distribution[4] += waterWeight * mass  // water
            totalMass += mass

            totalGeneration += particle.metadata.x
            totalAttractorMemory += particle.metadata.y
            sampleCount += 1
        }

        if totalMass > 0 {
            for i in 0..<5 {
                distribution[i] /= totalMass
            }
        }

        let avgGen = sampleCount > 0 ? totalGeneration / sampleCount : 0
        let avgMem = sampleCount > 0 ? totalAttractorMemory / sampleCount : 0

        DispatchQueue.main.async {
            self.onElementDistributionUpdate?(distribution)
            self.onGenerationUpdate?(avgGen, avgMem)
        }
    }

    // MARK: - Camera Control

    public func setCameraDistance(_ distance: Float) {
        cameraDistance = max(5, min(100, distance))
    }

    public func setCameraHeight(_ height: Float) {
        cameraHeight = height
    }

    public func setParticleScale(_ scale: Float) {
        renderParams.particleScale = max(1, min(10, scale))
    }

    public func setBifurcationIntensity(_ intensity: Float) {
        renderParams.bifurcationIntensity = max(0, min(2, intensity))
    }

    public func setGogyoStrength(_ strength: Float) {
        simulationParams.gogyoStrength = max(0, min(5, strength))
    }

    public func setTemperature(_ temp: Float) {
        simulationParams.temperature = max(0, min(10, temp))
    }

    public func setLatticeStrength(_ strength: Float) {
        simulationParams.latticeStrength = max(0, min(5, strength)) // Clamped to a reasonable range
    }

    public func setSphereRadius(_ radius: Float) {
        simulationParams.sphereRadius = max(0.1, min(20, radius))
    }

    public func setSphereAttractionStrength(_ strength: Float) {
        simulationParams.sphereAttractionStrength = max(0, min(1, strength))
    }

    public func setSphereRepulsionStrength(_ strength: Float) {
        simulationParams.sphereRepulsionStrength = max(0, min(1, strength))
    }

    public func setSphereLatticeEnabled(_ enabled: Bool) {
        simulationParams.sphereLatticeEnabled = enabled
    }

    public func setParticleCount(_ count: Int) {
        self.particleCount = max(1_000, min(250_000, count)) // Clamp to a reasonable range
    }

    public func setGridSize(_ size: UInt32) {
        simulationParams.currentGridSize = max(4, min(128, size)) // Clamp to a reasonable grid size
        simulationParams.gridTotal = simulationParams.currentGridSize * simulationParams.currentGridSize * simulationParams.currentGridSize
        initializeGridBuffer() // Recreate grid buffer with new size
    }


    // MARK: - Matrix Utilities

    private func perspectiveMatrix(fov: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let y = 1 / tan(fov * 0.5)
        let x = y / aspect
        let z = far / (near - far)
        let w = z * near

        return simd_float4x4(columns: (
            SIMD4<Float>(x, 0, 0, 0),
            SIMD4<Float>(0, y, 0, 0),
            SIMD4<Float>(0, 0, z, -1),
            SIMD4<Float>(0, 0, w, 0)
        ))
    }

    private func lookAtMatrix(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> simd_float4x4 {
        let z = simd_normalize(eye - center)
        let x = simd_normalize(simd_cross(up, z))
        let y = simd_cross(z, x)

        return simd_float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-simd_dot(x, eye), -simd_dot(y, eye), -simd_dot(z, eye), 1)
        ))
    }

    // MARK: - State Save/Load

    /// Export raw particle buffer data
    public func exportParticleData() -> Data? {
        // Read the most recently computed buffer
        let buffer = !useBufferA ? particleBuffer : particleBufferB
        guard let buf = buffer else { return nil }
        let size = MemoryLayout<GPUParticle>.stride * particleCount
        return Data(bytes: buf.contents(), count: size)
    }

    /// Import particle data from saved state
    public func importParticleData(_ data: Data, count: Int) {
        // Recreate buffers with correct count
        particleCount = count
        guard let bufA = particleBuffer, let bufB = particleBufferB else { return }
        let size = min(data.count, MemoryLayout<GPUParticle>.stride * count)
        data.withUnsafeBytes { rawPtr in
            guard let baseAddress = rawPtr.baseAddress else { return }
            memcpy(bufA.contents(), baseAddress, size)
            memcpy(bufB.contents(), baseAddress, size)
        }
    }

    public func getGlobalTime() -> Float { simulationParams.globalTime }
    public func setGlobalTime(_ t: Float) { simulationParams.globalTime = t }
    public func getFrameIndex() -> UInt32 { simulationParams.frameIndex }
    public func setFrameIndex(_ i: UInt32) { simulationParams.frameIndex = i }
}
