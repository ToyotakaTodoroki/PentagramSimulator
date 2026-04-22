import Foundation
import simd

// MARK: - Five Elements Definition

/// The five elements (五行) as computational states
public enum Element: Int, CaseIterable {
    case wood = 0   // 木 - Vibration, primordial chaos
    case fire = 1   // 火 - Radiation, energy diffusion
    case earth = 2  // 土 - Stability, gravitational convergence
    case metal = 3  // 金 - Crystallization, information compression
    case water = 4  // 水 - Dissolution, strange attractor emergence

    /// The element this one generates (相生 - Sōsei)
    var generates: Element {
        Element(rawValue: (rawValue + 1) % 5)!
    }

    /// The element this one overcomes (相剋 - Sōkoku)
    var overcomes: Element {
        Element(rawValue: (rawValue + 2) % 5)!
    }

    /// The element that generates this one
    var generatedBy: Element {
        Element(rawValue: (rawValue + 4) % 5)!
    }

    /// The element that overcomes this one
    var overcomedBy: Element {
        Element(rawValue: (rawValue + 3) % 5)!
    }

    /// Base color in HSV space (hue component)
    var baseHue: Float {
        switch self {
        case .wood:  return 0.33  // Green
        case .fire:  return 0.0   // Red
        case .earth: return 0.12  // Yellow-Orange
        case .metal: return 0.6   // Silver-Blue
        case .water: return 0.7   // Deep Blue
        }
    }

    /// Characteristic Lyapunov exponent tendency
    /// Positive = chaotic, Negative = stable, Near-zero = edge of chaos
    var lyapunovTendency: Float {
        switch self {
        case .wood:  return 0.8   // High chaos (primordial)
        case .fire:  return 0.5   // Moderate chaos (expanding)
        case .earth: return -0.3  // Converging
        case .metal: return -0.8  // Highly ordered
        case .water: return 0.3   // Strange attractor (bounded chaos)
        }
    }
}

// MARK: - Particle State

/// A particle's state vector in the five-element space
public struct ElementWeights: Equatable {
    public var wood: Float
    public var fire: Float
    public var earth: Float
    public var metal: Float
    public var water: Float

    public init(wood: Float = 0, fire: Float = 0, earth: Float = 0, metal: Float = 0, water: Float = 0) {
        self.wood = wood
        self.fire = fire
        self.earth = earth
        self.metal = metal
        self.water = water
    }

    public init(dominant: Element, purity: Float = 1.0) {
        let noise = (1.0 - purity) / 4.0
        self.wood = dominant == .wood ? purity : noise
        self.fire = dominant == .fire ? purity : noise
        self.earth = dominant == .earth ? purity : noise
        self.metal = dominant == .metal ? purity : noise
        self.water = dominant == .water ? purity : noise
    }

    /// Convert to SIMD vector for GPU
    public var simd: SIMD4<Float> {
        // Pack into float4: wood, fire, earth, metal (water derived from normalization)
        SIMD4<Float>(wood, fire, earth, metal)
    }

    /// The dominant element
    public var dominant: Element {
        let values = [wood, fire, earth, metal, water]
        let maxIndex = values.enumerated().max(by: { $0.element < $1.element })!.offset
        return Element(rawValue: maxIndex)!
    }

    /// Normalize so weights sum to 1
    public mutating func normalize() {
        let sum = wood + fire + earth + metal + water
        guard sum > 0 else { return }
        wood /= sum
        fire /= sum
        earth /= sum
        metal /= sum
        water /= sum
    }

    /// Fractal dimension estimate (information density)
    /// Higher = more complex internal structure
    public var fractalDimension: Float {
        // Using correlation dimension approximation via entropy
        let weights = [wood, fire, earth, metal, water].map { max($0, Float(1e-10)) }
        let entropy = -weights.reduce(Float(0)) { $0 + $1 * log2($1) }
        // Map entropy to dimension (0 = point, ~1.6 = pure chaos)
        return entropy / log2(5.0) * 2.0
    }

    /// Information content (negentropy)
    public var informationDensity: Float {
        let maxEntropy = log2(Float(5.0))
        let weights = [wood, fire, earth, metal, water].map { max($0, Float(1e-10)) }
        let entropy = -weights.reduce(Float(0)) { $0 + $1 * log2($1) }
        return 1.0 - (entropy / maxEntropy)
    }

    subscript(element: Element) -> Float {
        get {
            switch element {
            case .wood:  return wood
            case .fire:  return fire
            case .earth: return earth
            case .metal: return metal
            case .water: return water
            }
        }
        set {
            switch element {
            case .wood:  wood = newValue
            case .fire:  fire = newValue
            case .earth: earth = newValue
            case .metal: metal = newValue
            case .water: water = newValue
            }
        }
    }
}

// MARK: - Particle

/// A particle in the five-element system
public struct Particle {
    public var position: SIMD3<Float>
    public var velocity: SIMD3<Float>
    public var elementWeights: ElementWeights
    public var mass: Float
    public var age: Float  // Cycles completed
    public var generation: Int  // How many wood→water cycles
    public var attractorMemory: Float  // Accumulated strange attractor information

    public init(
        position: SIMD3<Float> = .zero,
        velocity: SIMD3<Float> = .zero,
        elementWeights: ElementWeights = ElementWeights(dominant: .wood),
        mass: Float = 1.0,
        age: Float = 0,
        generation: Int = 0,
        attractorMemory: Float = 0
    ) {
        self.position = position
        self.velocity = velocity
        self.elementWeights = elementWeights
        self.mass = mass
        self.age = age
        self.generation = generation
        self.attractorMemory = attractorMemory
    }

    /// Predictability based on mass (larger = more linear/deterministic)
    public var predictability: Float {
        // Law of large numbers: larger aggregates are more predictable
        let massContribution = tanh(mass / 10.0)
        // But water state reduces predictability
        let waterChaos = elementWeights.water * 0.5
        return max(0, massContribution - waterChaos)
    }

    /// Whether this particle carries "crystalline memory" from previous cycles
    public var hasAttractorMemory: Bool {
        generation > 0 && attractorMemory > 0.1
    }
}

// MARK: - Element System

/// The core system managing five-element state transitions
public class ElementSystem {

    // MARK: - Configuration

    public struct Configuration {
        public var particleCount: Int = 100_000
        public var transitionRate: Float = 0.1
        public var interactionRadius: Float = 0.5
        public var dissipationRate: Float = 0.01
        public var attractorStrength: Float = 0.5

        /// Sōsei (相生) generation rate
        public var generationRate: Float = 0.15

        /// Sōkoku (相剋) destruction threshold
        public var destructionThreshold: Float = 0.3

        public init() {}
    }

    // MARK: - Properties

    public var configuration: Configuration
    public private(set) var particles: [Particle]
    public private(set) var globalTime: Float = 0

    /// System-wide element distribution
    public var elementDistribution: ElementWeights {
        var total = ElementWeights()
        for particle in particles {
            total.wood += particle.elementWeights.wood * particle.mass
            total.fire += particle.elementWeights.fire * particle.mass
            total.earth += particle.elementWeights.earth * particle.mass
            total.metal += particle.elementWeights.metal * particle.mass
            total.water += particle.elementWeights.water * particle.mass
        }
        total.normalize()
        return total
    }

    /// Average generation (cycle count) of particles
    public var averageGeneration: Float {
        guard !particles.isEmpty else { return 0 }
        return Float(particles.reduce(0) { $0 + $1.generation }) / Float(particles.count)
    }

    /// System-wide attractor memory (accumulated wisdom)
    public var systemAttractorMemory: Float {
        guard !particles.isEmpty else { return 0 }
        return particles.reduce(0) { $0 + $1.attractorMemory } / Float(particles.count)
    }

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
        self.particles = []
        initializeParticles()
    }

    private func initializeParticles() {
        particles = (0..<configuration.particleCount).map { _ in
            // Start with primordial wood (naive random)
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
            return Particle(
                position: position,
                velocity: velocity,
                elementWeights: ElementWeights(dominant: .wood, purity: Float.random(in: 0.6...0.9)),
                mass: Float.random(in: 0.5...2.0),
                age: 0,
                generation: 0,
                attractorMemory: 0
            )
        }
    }

    // MARK: - Update Logic

    /// Main update step (CPU-side, for reference/debugging)
    public func update(deltaTime: Float) {
        globalTime += deltaTime

        for i in particles.indices {
            updateParticle(at: i, deltaTime: deltaTime)
        }
    }

    private func updateParticle(at index: Int, deltaTime: Float) {
        var particle = particles[index]

        // Age the particle
        particle.age += deltaTime

        // Apply element-specific dynamics
        let dominant = particle.elementWeights.dominant

        switch dominant {
        case .wood:
            applyWoodDynamics(to: &particle, deltaTime: deltaTime)
        case .fire:
            applyFireDynamics(to: &particle, deltaTime: deltaTime)
        case .earth:
            applyEarthDynamics(to: &particle, deltaTime: deltaTime)
        case .metal:
            applyMetalDynamics(to: &particle, deltaTime: deltaTime)
        case .water:
            applyWaterDynamics(to: &particle, deltaTime: deltaTime)
        }

        // Apply state transition (Sōsei - generation)
        applyStateTransition(to: &particle, deltaTime: deltaTime)

        // Update position
        particle.position += particle.velocity * deltaTime

        // Normalize weights
        particle.elementWeights.normalize()

        particles[index] = particle
    }

    // MARK: - Element-Specific Dynamics

    /// Wood (木): Primordial random vibration
    private func applyWoodDynamics(to particle: inout Particle, deltaTime: Float) {
        // Upward vector tendency (growth)
        particle.velocity.y += 0.1 * deltaTime

        // Random vibration (noise)
        if particle.generation == 0 {
            // Primordial wood: simple white noise
            particle.velocity += SIMD3<Float>(
                Float.random(in: -0.5...0.5),
                Float.random(in: -0.5...0.5),
                Float.random(in: -0.5...0.5)
            ) * deltaTime
        } else {
            // Reborn wood: strange attractor-like noise (fractal character)
            let attractorNoise = strangeAttractorNoise(
                position: particle.position,
                time: globalTime,
                memory: particle.attractorMemory
            )
            particle.velocity += attractorNoise * deltaTime * 0.5
        }

        // Negative entropy absorption (self-organization tendency)
        let speed = simd_length(particle.velocity)
        if speed > 2.0 {
            particle.velocity *= 0.95  // Damping to prevent runaway
        }
    }

    /// Fire (火): Energy radiation and diffusion
    private func applyFireDynamics(to particle: inout Particle, deltaTime: Float) {
        // High energy: amplify velocity
        let speed = simd_length(particle.velocity)
        if speed < 3.0 {
            particle.velocity *= 1.0 + 0.1 * deltaTime
        }

        // Thermal fluctuation (maximized randomness)
        particle.velocity += SIMD3<Float>(
            Float.random(in: -1.0...1.0),
            Float.random(in: -1.0...1.0),
            Float.random(in: -1.0...1.0)
        ) * deltaTime * 0.8

        // Outward expansion
        let direction = simd_normalize(particle.position)
        particle.velocity += direction * 0.05 * deltaTime
    }

    /// Earth (土): Gravitational convergence
    private func applyEarthDynamics(to particle: inout Particle, deltaTime: Float) {
        // Pull toward center (attractor convergence)
        let toCenter = -particle.position
        let distance = simd_length(toCenter)
        if distance > 0.1 {
            let attraction = simd_normalize(toCenter) * configuration.attractorStrength
            particle.velocity += attraction * deltaTime
        }

        // Velocity damping (stabilization)
        particle.velocity *= 1.0 - 0.1 * deltaTime

        // Mass accumulation
        particle.mass += 0.01 * deltaTime
    }

    /// Metal (金): Crystallization and information compression
    private func applyMetalDynamics(to particle: inout Particle, deltaTime: Float) {
        // Quantize position toward lattice (crystalline structure)
        let gridSize: Float = 1.0
        let targetPosition = SIMD3<Float>(
            round(particle.position.x / gridSize) * gridSize,
            round(particle.position.y / gridSize) * gridSize,
            round(particle.position.z / gridSize) * gridSize
        )
        let toTarget = targetPosition - particle.position
        particle.velocity += toTarget * 0.3 * deltaTime

        // Strong damping (predictability)
        particle.velocity *= 1.0 - 0.2 * deltaTime

        // Information accumulation (stored in attractor memory for next cycle)
        particle.attractorMemory += particle.elementWeights.informationDensity * deltaTime * 0.1
    }

    /// Water (水): Dissolution with information preservation
    private func applyWaterDynamics(to particle: inout Particle, deltaTime: Float) {
        // Apply the noise function for Metal→Water transition (information fragmentation)
        let fragmentationNoise = metalToWaterFragmentation(
            particle: particle,
            time: globalTime
        )
        particle.velocity += fragmentationNoise * deltaTime

        // Strange attractor orbit (Lorenz-like)
        let attractorVelocity = lorenzAttractorStep(
            position: particle.position,
            sigma: 10.0 + particle.attractorMemory * 2.0,
            rho: 28.0,
            beta: 8.0 / 3.0
        )
        particle.velocity = simd_mix(
            particle.velocity,
            attractorVelocity * 0.1,
            SIMD3<Float>(repeating: 0.3 * deltaTime)
        )

        // Mass dissolution (but information preserved)
        particle.mass *= 1.0 - 0.05 * deltaTime
        if particle.mass < 0.1 {
            particle.mass = 0.1
        }
    }

    // MARK: - State Transition (Sōsei 相生)

    private func applyStateTransition(to particle: inout Particle, deltaTime: Float) {
        let dominant = particle.elementWeights.dominant
        let next = dominant.generates

        // Transition rate based on age and configuration
        let transitionAmount = configuration.generationRate * deltaTime * (1.0 + particle.age * 0.1)

        // Transfer weight to next element
        particle.elementWeights[dominant] -= transitionAmount
        particle.elementWeights[next] += transitionAmount

        // Special handling for water→wood transition (rebirth)
        if dominant == .water && particle.elementWeights.wood > particle.elementWeights.water {
            particle.generation += 1
            particle.age = 0
            // Preserve attractor memory for the new cycle
        }
    }

    // MARK: - Collision Handling (Sōkoku 相剋)

    /// Handle collision between two particles
    public func handleCollision(particle1Index: Int, particle2Index: Int) {
        var p1 = particles[particle1Index]
        var p2 = particles[particle2Index]

        let d1 = p1.elementWeights.dominant
        let d2 = p2.elementWeights.dominant

        // Check for Sōkoku relationship
        if d1.overcomes == d2 {
            // p1 overcomes p2
            resolveOvercoming(victor: &p1, defeated: &p2)
        } else if d2.overcomes == d1 {
            // p2 overcomes p1
            resolveOvercoming(victor: &p2, defeated: &p1)
        } else {
            // No Sōkoku: simple elastic collision
            let normal = simd_normalize(p2.position - p1.position)
            let relativeVelocity = p1.velocity - p2.velocity
            let velocityAlongNormal = simd_dot(relativeVelocity, normal)

            if velocityAlongNormal > 0 { return }  // Moving apart

            let restitution: Float = 0.8
            let impulse = -(1 + restitution) * velocityAlongNormal / (1/p1.mass + 1/p2.mass)

            p1.velocity += impulse / p1.mass * normal
            p2.velocity -= impulse / p2.mass * normal
        }

        // Collision reveals underlying chaos (even in "stable" particles)
        revealUnderlyingChaos(particle: &p1)
        revealUnderlyingChaos(particle: &p2)

        particles[particle1Index] = p1
        particles[particle2Index] = p2
    }

    /// Resolve Sōkoku (overcoming) relationship
    private func resolveOvercoming(victor: inout Particle, defeated: inout Particle) {
        // The one with lower fractal dimension is absorbed
        let victorDensity = victor.elementWeights.fractalDimension
        let defeatedDensity = defeated.elementWeights.fractalDimension

        if victorDensity > defeatedDensity {
            // Victor absorbs defeated's mass and some information
            victor.mass += defeated.mass * 0.5
            victor.attractorMemory += defeated.attractorMemory * 0.3

            // Defeated is fragmented toward water state
            defeated.elementWeights.water += 0.3
            defeated.mass *= 0.5
            defeated.velocity *= 1.5  // Scatter
        } else {
            // Upset! Defeated has denser information structure
            // Both are disturbed, revealing underlying chaos
            victor.elementWeights.water += 0.2
            defeated.elementWeights[defeated.elementWeights.dominant.generates] += 0.2
        }
    }

    /// Collision reveals the strange attractor nature hidden in "linear" particles
    private func revealUnderlyingChaos(particle: inout Particle) {
        // Even highly ordered particles have hidden complexity
        // Collision is a perturbation that reveals this

        let perturbation = particle.mass * 0.1  // Larger = more hidden complexity

        // Add chaotic component to velocity
        let chaosReveal = strangeAttractorNoise(
            position: particle.position,
            time: globalTime,
            memory: particle.attractorMemory + perturbation
        )

        particle.velocity += chaosReveal * perturbation

        // Slightly shift toward water (dissolution of certainty)
        particle.elementWeights.water += perturbation * 0.05
        particle.elementWeights.normalize()
    }

    // MARK: - Noise Functions

    /// Strange attractor noise for reborn wood particles
    private func strangeAttractorNoise(position: SIMD3<Float>, time: Float, memory: Float) -> SIMD3<Float> {
        // Rössler attractor-based noise with memory modulation
        let a: Float = 0.2 + memory * 0.1
        let b: Float = 0.2
        let c: Float = 5.7

        let x = position.x + sin(time * 0.1)
        let y = position.y + cos(time * 0.13)
        let z = position.z

        let dx = -y - z
        let dy = x + a * y
        let dz = b + z * (x - c)

        return SIMD3<Float>(dx, dy, dz) * 0.01
    }

    /// Metal to Water fragmentation noise
    /// This expresses the "information fragmentation" during the Metal→Water transition
    private func metalToWaterFragmentation(particle: Particle, time: Float) -> SIMD3<Float> {
        // The crystalline structure (Metal) breaks apart into strange attractor orbits (Water)
        // Key insight: information is preserved but distributed fractally

        let metalWeight = particle.elementWeights.metal
        let waterWeight = particle.elementWeights.water
        let transitionPhase = waterWeight / max(metalWeight + waterWeight, 0.001)

        // During early transition: structured fragmentation (preserving lattice memory)
        // During late transition: full strange attractor behavior

        let structuredComponent = SIMD3<Float>(
            sin(particle.position.x * 3.14159 + time),
            sin(particle.position.y * 3.14159 + time * 1.1),
            sin(particle.position.z * 3.14159 + time * 0.9)
        ) * (1.0 - transitionPhase)

        let chaoticComponent = lorenzAttractorStep(
            position: particle.position * 0.1,
            sigma: 10.0,
            rho: 28.0 + particle.attractorMemory * 5.0,  // Memory affects attractor shape
            beta: 8.0 / 3.0
        ) * transitionPhase

        // Fractal dimension scaling: higher memory = finer fragmentation
        let fragmentationScale = 0.5 + particle.attractorMemory * 0.5

        return (structuredComponent + chaoticComponent) * fragmentationScale
    }

    /// Lorenz attractor step
    private func lorenzAttractorStep(position: SIMD3<Float>, sigma: Float, rho: Float, beta: Float) -> SIMD3<Float> {
        let dx = sigma * (position.y - position.x)
        let dy = position.x * (rho - position.z) - position.y
        let dz = position.x * position.y - beta * position.z
        return SIMD3<Float>(dx, dy, dz)
    }

    // MARK: - GPU Data Preparation

    /// Prepare particle data for GPU transfer
    public func prepareGPUData() -> ([SIMD4<Float>], [SIMD4<Float>], [SIMD4<Float>]) {
        var positions: [SIMD4<Float>] = []
        var velocities: [SIMD4<Float>] = []
        var properties: [SIMD4<Float>] = []  // weights.xy, mass, age

        for particle in particles {
            positions.append(SIMD4<Float>(particle.position, particle.mass))
            velocities.append(SIMD4<Float>(particle.velocity, particle.age))

            let w = particle.elementWeights
            properties.append(SIMD4<Float>(w.wood, w.fire, w.earth, w.metal))
        }

        return (positions, velocities, properties)
    }
}

// MARK: - Quaternion Transition

/// Quaternion-based smooth transition between element states
public struct ElementQuaternion {
    public var q: simd_quatf

    public init(from: Element, to: Element, progress: Float) {
        // Map elements to 5D rotation (projected to quaternion)
        let fromAngle = Float(from.rawValue) * (2 * .pi / 5)
        let toAngle = Float(to.rawValue) * (2 * .pi / 5)

        let fromQ = simd_quatf(angle: fromAngle, axis: SIMD3<Float>(0, 1, 0))
        let toQ = simd_quatf(angle: toAngle, axis: SIMD3<Float>(0, 1, 0))

        self.q = simd_slerp(fromQ, toQ, progress)
    }

    /// Apply rotation to particle velocity
    public func apply(to velocity: SIMD3<Float>) -> SIMD3<Float> {
        q.act(velocity)
    }
}
