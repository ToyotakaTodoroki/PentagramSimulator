import Foundation

// MARK: - Parameter Space

/// All tunable simulation parameters packed as a vector
public struct ParameterSet {
    public var values: [Float]

    public static let definitions: [(name: String, min: Float, max: Float)] = [
        ("gogyoStrength",            0,  5),
        ("latticeStrength",          0,  5),
        ("sphereRadius",             1, 15),
        ("sphereAttractionStrength", 0,  2),
        ("sphereRepulsionStrength",  0,  2),
        ("targetWood",               0,  1),
        ("targetFire",               0,  1),
        ("targetEarth",              0,  1),
        ("targetMetal",              0,  1),
        ("targetWater",              0,  1),
    ]

    public static var dimensions: Int { definitions.count }

    public init(values: [Float]) {
        self.values = values
    }

    /// Normalize all values to [0, 1]
    public var normalized: [Float] {
        zip(values, Self.definitions).map { v, d in
            (v - d.min) / (d.max - d.min)
        }
    }

    /// Reconstruct from [0, 1] normalized values
    public static func fromNormalized(_ norm: [Float]) -> ParameterSet {
        ParameterSet(values: zip(norm, definitions).map { n, d in
            n * (d.max - d.min) + d.min
        })
    }

    /// Uniformly random parameters within defined ranges
    public static func random() -> ParameterSet {
        ParameterSet(values: definitions.map { Float.random(in: $0.min...$0.max) })
    }

    /// Perturb a random subset of parameters (for SA)
    /// - count: number of parameters to perturb (higher temperature → more params)
    public func perturbed(temperature: Float, count: Int = 2) -> ParameterSet {
        var newValues = values
        let indices = Array(0..<Self.dimensions).shuffled().prefix(count)
        for i in indices {
            let d = Self.definitions[i]
            let range = d.max - d.min
            let scale = range * temperature * 0.15
            let delta = Float.random(in: -1...1) * scale
            newValues[i] = Swift.min(d.max, Swift.max(d.min, newValues[i] + delta))
        }
        return ParameterSet(values: newValues)
    }
}

// MARK: - Gaussian Process

public class GaussianProcess {
    public struct Observation {
        public let x: [Float]  // normalized [0,1]
        public let y: Float    // energy (lower = better)
    }

    public private(set) var observations: [Observation] = []
    public var lengthScale: Float = 0.3
    public var signalVariance: Float = 1.0
    public var noiseVariance: Float = 0.05

    private var cachedL: [Float]?
    private var cachedAlpha: [Float]?
    private var cacheValid = false

    public init() {}

    public func addObservation(x: [Float], y: Float) {
        observations.append(Observation(x: x, y: y))
        cacheValid = false
    }

    public func predict(at xStar: [Float]) -> (mean: Float, variance: Float) {
        let n = observations.count
        guard n > 0 else { return (0, signalVariance) }

        rebuildCacheIfNeeded()
        guard let L = cachedL, let alpha = cachedAlpha else {
            return (0, signalVariance)
        }

        // k* vector
        let kStar = (0..<n).map { kernel(observations[$0].x, xStar) }

        // mean = k*^T alpha
        let mean = zip(kStar, alpha).reduce(Float(0)) { $0 + $1.0 * $1.1 }

        // variance = k** - v^T v  where L v = k*
        let v = forwardSolve(L, kStar, n: n)
        let vTv = v.reduce(Float(0)) { $0 + $1 * $1 }
        let variance = Swift.max(kernel(xStar, xStar) - vTv, 1e-6)

        return (mean, variance)
    }

    public var bestObservation: Observation? {
        observations.min(by: { $0.y < $1.y })
    }

    public func reset() {
        observations.removeAll()
        cacheValid = false
        cachedL = nil
        cachedAlpha = nil
    }

    // MARK: - Private

    private func kernel(_ x1: [Float], _ x2: [Float]) -> Float {
        var sqDist: Float = 0
        for i in 0..<Swift.min(x1.count, x2.count) {
            let d = x1[i] - x2[i]
            sqDist += d * d
        }
        return signalVariance * exp(-sqDist / (2 * lengthScale * lengthScale))
    }

    private func rebuildCacheIfNeeded() {
        guard !cacheValid else { return }
        let n = observations.count
        guard n > 0 else { return }

        // Build K + sigma^2 I
        var K = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n {
                K[i * n + j] = kernel(observations[i].x, observations[j].x)
            }
            K[i * n + i] += noiseVariance
        }

        // Cholesky decomposition (with jitter fallback)
        if let L = choleskyDecompose(K, n: n) {
            cachedL = L
        } else {
            // Add jitter and retry
            for i in 0..<n { K[i * n + i] += 0.1 }
            guard let L = choleskyDecompose(K, n: n) else { return }
            cachedL = L
        }

        guard let L = cachedL else { return }
        let y = observations.map { $0.y }
        let z = forwardSolve(L, y, n: n)
        cachedAlpha = backwardSolve(L, z, n: n)
        cacheValid = true
    }

    private func choleskyDecompose(_ A: [Float], n: Int) -> [Float]? {
        var L = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0...i {
                var sum: Float = 0
                for k in 0..<j { sum += L[i * n + k] * L[j * n + k] }
                if i == j {
                    let diag = A[i * n + i] - sum
                    guard diag > 0 else { return nil }
                    L[i * n + j] = sqrt(diag)
                } else {
                    L[i * n + j] = (A[i * n + j] - sum) / L[j * n + j]
                }
            }
        }
        return L
    }

    private func forwardSolve(_ L: [Float], _ b: [Float], n: Int) -> [Float] {
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var sum: Float = 0
            for j in 0..<i { sum += L[i * n + j] * x[j] }
            x[i] = (b[i] - sum) / L[i * n + i]
        }
        return x
    }

    private func backwardSolve(_ L: [Float], _ b: [Float], n: Int) -> [Float] {
        var x = [Float](repeating: 0, count: n)
        for i in stride(from: n - 1, through: 0, by: -1) {
            var sum: Float = 0
            for j in (i + 1)..<n { sum += L[j * n + i] * x[j] }
            x[i] = (b[i] - sum) / L[i * n + i]
        }
        return x
    }
}

// MARK: - Bayesian Optimizer

public class BayesianOptimizer {
    public let gp = GaussianProcess()

    /// Number of random candidates for acquisition function maximization
    public var candidateCount: Int = 200

    /// Exploration-exploitation trade-off (xi parameter for EI)
    public var explorationWeight: Float = 0.01

    public init() {}

    /// Propose next parameter set to evaluate
    public func propose() -> ParameterSet {
        // Initial exploration phase: random proposals
        if gp.observations.count < 5 {
            return ParameterSet.random()
        }

        guard let best = gp.bestObservation else {
            return ParameterSet.random()
        }

        // Maximize Expected Improvement via random + local refinement
        var bestEI: Float = -Float.infinity
        var bestCandidate = [Float](repeating: 0.5, count: ParameterSet.dimensions)

        // Global random search
        for _ in 0..<candidateCount {
            let candidate = (0..<ParameterSet.dimensions).map { _ in Float.random(in: 0...1) }
            let ei = expectedImprovement(at: candidate, bestY: best.y)
            if ei > bestEI {
                bestEI = ei
                bestCandidate = candidate
            }
        }

        // Local refinement around best candidate
        for _ in 0..<50 {
            let refined = bestCandidate.map { v in
                Swift.min(1, Swift.max(0, v + Float.random(in: -0.05...0.05)))
            }
            let ei = expectedImprovement(at: refined, bestY: best.y)
            if ei > bestEI {
                bestEI = ei
                bestCandidate = refined
            }
        }

        return ParameterSet.fromNormalized(bestCandidate)
    }

    /// Record an observation (parameter set → energy)
    public func record(params: ParameterSet, energy: Float) {
        gp.addObservation(x: params.normalized, y: energy)
    }

    public func reset() {
        gp.reset()
    }

    public var observationCount: Int { gp.observations.count }

    public var bestEnergy: Float? {
        gp.bestObservation?.y
    }

    public var bestParams: ParameterSet? {
        guard let best = gp.bestObservation else { return nil }
        return ParameterSet.fromNormalized(best.x)
    }

    // MARK: - Private

    private func expectedImprovement(at x: [Float], bestY: Float) -> Float {
        let (mean, variance) = gp.predict(at: x)
        let std = sqrt(variance)
        guard std > 1e-8 else { return 0 }

        let improvement = bestY - mean - explorationWeight
        let z = improvement / std
        return improvement * normalCDF(z) + std * normalPDF(z)
    }

    private func normalCDF(_ x: Float) -> Float {
        0.5 * (1.0 + Float(erf(Double(x) / sqrt(2.0))))
    }

    private func normalPDF(_ x: Float) -> Float {
        exp(-0.5 * x * x) / sqrt(2.0 * Float.pi)
    }
}
