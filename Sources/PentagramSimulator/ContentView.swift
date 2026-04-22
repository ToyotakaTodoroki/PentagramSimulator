import SwiftUI
import MetalKit
#if os(macOS)
import AppKit
#endif

// MARK: - Simulation Save Format

struct SimulationSaveHeader: Codable {
    var particleCount: Int
    var globalTime: Float
    var frameIndex: UInt32
    var gogyoStrength: Float
    var temperature: Float
    var latticeStrength: Float
    var cameraDistance: Float
    var particleScale: Float
    var sphereRadius: Float
    var sphereAttractionStrength: Float
    var sphereRepulsionStrength: Float
    var sphereLatticeEnabled: Bool
    var targetWoodWeight: Float
    var targetFireWeight: Float
    var targetEarthWeight: Float
    var targetMetalWeight: Float
    var targetWaterWeight: Float
    var annealingEnabled: Bool
    var annealingRate: Float
    var currentGridSize: UInt32
    var bayesianOptEnabled: Bool
    var boEquilibriumWait: Float
}

// MARK: - Element Distribution (View-side struct)

struct ViewElementWeights {
    var wood: Float = 0.2
    var fire: Float = 0.2
    var earth: Float = 0.2
    var metal: Float = 0.2
    var water: Float = 0.2

    init() {}

    init(array: [Float]) {
        guard array.count >= 5 else { return }
        wood = array[0]
        fire = array[1]
        earth = array[2]
        metal = array[3]
        water = array[4]
    }
}

// MARK: - Metal View Representable

#if os(macOS)
struct MetalView: NSViewRepresentable {
    let renderer: ParticleRenderer

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = renderer
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}
}
#else
struct MetalView: UIViewRepresentable {
    let renderer: ParticleRenderer

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .depth32Float
        view.preferredFramesPerSecond = 60
        view.enableSetNeedsDisplay = false
        view.isPaused = false
        view.delegate = renderer
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}
}
#endif

// MARK: - Element Distribution View

struct ElementDistributionView: View {
    let distribution: ViewElementWeights

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("五行分布 (Element Distribution)")
                .font(.headline)
                .foregroundColor(.white)

            ElementBar(name: "木 Wood", value: distribution.wood, color: .green)
            ElementBar(name: "火 Fire", value: distribution.fire, color: .red)
            ElementBar(name: "土 Earth", value: distribution.earth, color: .yellow)
            ElementBar(name: "金 Metal", value: distribution.metal, color: .gray)
            ElementBar(name: "水 Water", value: distribution.water, color: .blue)
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(10)
    }
}

struct ElementBar: View {
    let name: String
    let value: Float
    let color: Color

    var body: some View {
        HStack {
            Text(name)
                .font(.caption)
                .foregroundColor(.white)
                .frame(width: 80, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(Color.white.opacity(0.2))
                        .frame(height: 12)

                    Rectangle()
                        .fill(color)
                        .frame(width: geometry.size.width * CGFloat(value), height: 12)
                }
                .cornerRadius(6)
            }
            .frame(height: 12)

            Text(String(format: "%.1f%%", value * 100))
                .font(.caption)
                .foregroundColor(.white)
                .frame(width: 50, alignment: .trailing)
        }
    }
}

// MARK: - Cycle Info View

struct CycleInfoView: View {
    let generation: Float
    let attractorMemory: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("循環情報 (Cycle Info)")
                .font(.headline)
                .foregroundColor(.white)

            HStack {
                Text("世代 Generation:")
                    .foregroundColor(.white.opacity(0.7))
                Text(String(format: "%.1f", generation))
                    .foregroundColor(.cyan)
            }
            .font(.caption)

            HStack {
                Text("アトラクター記憶:")
                    .foregroundColor(.white.opacity(0.7))
                Text(String(format: "%.3f", attractorMemory))
                    .foregroundColor(.purple)
            }
            .font(.caption)

            Text("(Attractor Memory)")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
        .padding()
        .background(Color.black.opacity(0.7))
        .cornerRadius(10)
    }
}

// MARK: - Main Content View

public struct ContentView: View {
    @StateObject private var viewModel = SimulationViewModel()
    @State private var showUI = true

    public init() {}

    public var body: some View {
        ZStack {
            // Metal rendering view
            if let renderer = viewModel.renderer {
                MetalView(renderer: renderer)
                    .ignoresSafeArea()
            } else {
                Color.black
                    .ignoresSafeArea()
                Text("Initializing Metal...")
                    .foregroundColor(.white)
            }

            // UI Overlay - minimal, corner-aligned
            if showUI {
                VStack {
                    HStack(alignment: .top) {
                        // Top-left: Title and element distribution
                        VStack(alignment: .leading, spacing: 8) {
                            Text("五行相転移")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundColor(.white.opacity(0.8))

                            ElementDistributionMini(distribution: viewModel.elementDistribution)
                        }
                        .padding(12)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)

                        Spacer()

                        // Top-right: Controls
                        VStack(alignment: .trailing, spacing: 6) {
                            HStack(spacing: 4) {
                                Text("Dist")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.cameraDistance, in: 10...60)
                                    .frame(width: 80)
                            }
                            HStack(spacing: 4) {
                                Text("Scale")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.particleScale, in: 1...8)
                                    .frame(width: 80)
                            }
                            HStack(spacing: 4) {
                                Text("五行")
                                    .font(.caption2)
                                    .foregroundColor(.yellow.opacity(0.8))
                                Slider(value: $viewModel.gogyoStrength, in: 0...5)
                                    .frame(width: 80)
                            }
                            HStack(spacing: 4) {
                                Text("Temp")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.temperature, in: 0...5) // Adjust range as needed
                                    .frame(width: 80)
                            }

                            Divider().frame(width: 80).background(Color.white.opacity(0.3))

                            HStack(spacing: 4) {
                                Text("T. Wood")
                                    .font(.caption2)
                                    .foregroundColor(.green.opacity(0.8))
                                Slider(value: $viewModel.targetWoodWeight, in: 0...1)
                                    .frame(width: 80)
                            }
                            HStack(spacing: 4) {
                                Text("T. Fire")
                                    .font(.caption2)
                                    .foregroundColor(.red.opacity(0.8))
                                Slider(value: $viewModel.targetFireWeight, in: 0...1)
                                    .frame(width: 80)
                            }
                            HStack(spacing: 4) {
                                Text("T. Earth")
                                    .font(.caption2)
                                    .foregroundColor(.yellow.opacity(0.8))
                                Slider(value: $viewModel.targetEarthWeight, in: 0...1)
                                    .frame(width: 80)
                            }
                            HStack(spacing: 4) {
                                Text("T. Metal")
                                    .font(.caption2)
                                    .foregroundColor(.gray.opacity(0.8))
                                Slider(value: $viewModel.targetMetalWeight, in: 0...1)
                                    .frame(width: 80)
                            }
                            HStack(spacing: 4) {
                                Text("T. Water")
                                    .font(.caption2)
                                    .foregroundColor(.blue.opacity(0.8))
                                Slider(value: $viewModel.targetWaterWeight, in: 0...1)
                                    .frame(width: 80)
                            }

                            Divider().frame(width: 80).background(Color.white.opacity(0.3))

                            Toggle(isOn: $viewModel.annealingEnabled) {
                                Text("Anneal")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                            }.frame(width: 80)

                            HStack(spacing: 4) {
                                Text("Rate")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.annealingRate, in: 0.001...0.1)
                                    .frame(width: 80)
                            }

                            Toggle(isOn: $viewModel.bayesianOptEnabled) {
                                Text("BO")
                                    .font(.caption2)
                                    .foregroundColor(.orange.opacity(0.8))
                            }.frame(width: 80)

                            HStack(spacing: 4) {
                                Text("Wait")
                                    .font(.caption2)
                                    .foregroundColor(.orange.opacity(0.6))
                                Slider(value: $viewModel.boEquilibriumWait, in: 2...15)
                                    .frame(width: 80)
                            }

                            if viewModel.bayesianOptEnabled {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("BO: \(viewModel.boObservationCount) obs")
                                        .font(.caption2)
                                        .foregroundColor(.orange.opacity(0.7))
                                    Text("Best: \(String(format: "%.2f", viewModel.boBestEnergy))")
                                        .font(.caption2)
                                        .foregroundColor(.orange.opacity(0.7))
                                }
                            }

                            HStack(spacing: 4) {
                                Text("Lattice")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.latticeStrength, in: 0...5)
                                    .frame(width: 80)
                            }

                            Divider().frame(width: 80).background(Color.white.opacity(0.3))

                            Toggle(isOn: $viewModel.sphereLatticeEnabled) {
                                Text("Sphere")
                                    .font(.caption2)
                                    .foregroundColor(.cyan.opacity(0.8))
                            }.frame(width: 80)

                            HStack(spacing: 4) {
                                Text("Radius")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.sphereRadius, in: 1...15)
                                    .frame(width: 80)
                            }

                            HStack(spacing: 4) {
                                Text("S_Attr")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.sphereAttractionStrength, in: 0...2) // Increased range
                                    .frame(width: 80)
                            }

                            HStack(spacing: 4) {
                                Text("S_Rep")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: $viewModel.sphereRepulsionStrength, in: 0...2) // Increased range
                                    .frame(width: 80)
                            }

                            Divider().frame(width: 80).background(Color.white.opacity(0.3))

                            HStack(spacing: 4) {
                                Text("Count")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: Binding(get: {
                                    Float(self.viewModel.controllableParticleCount)
                                }, set: {
                                    self.viewModel.controllableParticleCount = Int($0)
                                }), in: 1_000...250_000, step: 1_000)
                                    .frame(width: 80)
                            }

                            Divider().frame(width: 80).background(Color.white.opacity(0.3))

                            HStack(spacing: 4) {
                                Text("Grid")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.6))
                                Slider(value: Binding(get: {
                                    Float(self.viewModel.currentGridSize)
                                }, set: {
                                    self.viewModel.currentGridSize = UInt32($0)
                                }), in: 4...64, step: 4) // Range 4 to 64, step 4
                                    .frame(width: 80)
                            }

                            Divider().frame(width: 80).background(Color.white.opacity(0.3))

                            HStack(spacing: 8) {
                                Button("Save") { viewModel.saveSimulation() }
                                    .font(.caption2)
                                    .foregroundColor(.cyan)
                                Button("Load") { viewModel.loadSimulation() }
                                    .font(.caption2)
                                    .foregroundColor(.cyan)
                            }
                        }
                        .padding(10)
                        .background(Color.black.opacity(0.5))
                        .cornerRadius(8)
                    }
                    .padding(16)

                    Spacer()

                    // Bottom-right: Generation info
                    HStack {
                        Spacer()
                        HStack(spacing: 12) {
                            Text("Gen: \(String(format: "%.1f", viewModel.averageGeneration))")
                            Text("Mem: \(String(format: "%.2f", viewModel.systemAttractorMemory))")
                        }
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.6))
                        .padding(8)
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(6)
                    }
                    .padding(16)
                }
            }

            // Toggle UI hint
            VStack {
                Spacer()
                HStack {
                    Text("Press H to toggle UI")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.3))
                        .padding(4)
                    Spacer()
                }
                .padding(.leading, 16)
                .padding(.bottom, 4)
            }
        }
        .onAppear {
            viewModel.initialize()
        }
        #if os(macOS)
        .onKeyPress("h") {
            showUI.toggle()
            return .handled
        }
        .onKeyPress(.escape) {
            NSApp.terminate(nil)
            return .handled
        }
        #endif
    }
}

// MARK: - Mini Element Distribution (Compact)

struct ElementDistributionMini: View {
    let distribution: ViewElementWeights

    var body: some View {
        HStack(spacing: 3) {
            ElementDot(value: distribution.wood, color: .green)
            ElementDot(value: distribution.fire, color: .red)
            ElementDot(value: distribution.earth, color: .yellow)
            ElementDot(value: distribution.metal, color: .gray)
            ElementDot(value: distribution.water, color: .blue)
        }
    }
}

struct ElementDot: View {
    let value: Float
    let color: Color

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8 + CGFloat(value) * 20, height: 8 + CGFloat(value) * 20)
            .opacity(0.4 + Double(value) * 0.6)
    }
}

// MARK: - Control Panel

struct ControlPanel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            content
        }
        .padding(10)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
}

// MARK: - Legend View

struct LegendView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("凡例 Legend")
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.white)

            LegendItem(color: .green, text: "木 Wood - 振動")
            LegendItem(color: .red, text: "火 Fire - 放射")
            LegendItem(color: .yellow, text: "土 Earth - 安定")
            LegendItem(color: .gray, text: "金 Metal - 結晶")
            LegendItem(color: .blue, text: "水 Water - 溶解")
        }
        .padding(10)
        .background(Color.black.opacity(0.6))
        .cornerRadius(8)
    }
}

struct LegendItem: View {
    let color: Color
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)

            Text(text)
                .font(.caption2)
                .foregroundColor(.white.opacity(0.8))
        }
    }
}

// MARK: - View Model

@MainActor
class SimulationViewModel: ObservableObject {
    @Published var renderer: ParticleRenderer?
    @Published var elementDistribution = ViewElementWeights()
    @Published var averageGeneration: Float = 0
    @Published var systemAttractorMemory: Float = 0

    @Published var cameraDistance: Float = 30 {
        didSet { renderer?.setCameraDistance(cameraDistance) }
    }

    @Published var cameraHeight: Float = 10 {
        didSet { renderer?.setCameraHeight(cameraHeight) }
    }

    @Published var particleScale: Float = 3 {
        didSet { renderer?.setParticleScale(particleScale) }
    }

    @Published var bifurcationIntensity: Float = 1 {
        didSet { renderer?.setBifurcationIntensity(bifurcationIntensity) }
    }

    @Published var gogyoStrength: Float = 1 {
        didSet { renderer?.setGogyoStrength(gogyoStrength) }
    }

    @Published var temperature: Float = 0.5 { // Default temperature
        didSet { renderer?.setTemperature(temperature) }
    }

    // Target weights for simulated annealing
    @Published var targetWoodWeight: Float = 0.2
    @Published var targetFireWeight: Float = 0.2
    @Published var targetEarthWeight: Float = 0.2
    @Published var targetMetalWeight: Float = 0.2
    @Published var targetWaterWeight: Float = 0.2

    // Simulated Annealing Parameters
    @Published var annealingEnabled: Bool = false
    @Published var annealingRate: Float = 0.01

    @Published var latticeStrength: Float = 1.0 {
        didSet { renderer?.setLatticeStrength(latticeStrength) }
    }

    // Sphere Lattice Parameters
    @Published var sphereRadius: Float = 5.0 {
        didSet { renderer?.setSphereRadius(sphereRadius) }
    }
    @Published var sphereAttractionStrength: Float = 0.1 {
        didSet { renderer?.setSphereAttractionStrength(sphereAttractionStrength) }
    }
    @Published var sphereRepulsionStrength: Float = 0.05 {
        didSet { renderer?.setSphereRepulsionStrength(sphereRepulsionStrength) }
    }
    @Published var sphereLatticeEnabled: Bool = false {
        didSet { renderer?.setSphereLatticeEnabled(sphereLatticeEnabled) }
    }

    // Controllable Particle Count
    @Published var controllableParticleCount: Int = 100_000 {
        didSet { renderer?.setParticleCount(controllableParticleCount) }
    }

    // Configurable Grid Size
    @Published var currentGridSize: UInt32 = 32 {
        didSet { renderer?.setGridSize(currentGridSize) }
    }

    // Bayesian Optimization
    @Published var bayesianOptEnabled: Bool = false
    @Published var boObservationCount: Int = 0
    @Published var boBestEnergy: Float = .infinity
    @Published var boEquilibriumWait: Float = 5.0

    private var annealingTimer: Timer?
    private var currentParams: ParameterSet?
    private var currentEnergy: Float = 0.0
    private var annealingStep: Int = 0

    // Bayesian Optimization internals
    private var bayesianOptimizer = BayesianOptimizer()
    private var boTimer: Timer?
    private var boWaitingForEquilibrium = false
    private var boWaitStartTime = Date()
    private var boProposedParams: ParameterSet?

    var particleCount: Int { renderer?.particleCount ?? 0 }

    func initialize() {
        // Create a temporary MTKView to initialize the renderer
        let tempView = MTKView()
        guard let renderer = ParticleRenderer(metalKitView: tempView) else {
            print("Failed to create renderer")
            return
        }

        renderer.onElementDistributionUpdate = { [weak self] distribution in
            self?.elementDistribution = ViewElementWeights(array: distribution)
            self?.updateEnergy() // Recalculate energy when distribution updates
        }

        renderer.onGenerationUpdate = { [weak self] avgGen, avgMem in
            self?.averageGeneration = avgGen
            self?.systemAttractorMemory = avgMem
        }

        self.renderer = renderer

        // Initialize annealing parameters
        self.currentParams = self.extractParameterSet()

        // Setup annealing timer
        annealingTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.annealSimulation()
            }
        }

        // Setup BO timer (checks every 1 second)
        boTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.bayesianOptStep()
            }
        }
    }

    private func annealSimulation() {
        guard annealingEnabled else { return }

        // Initialize parameter tracking if needed
        if currentParams == nil {
            currentParams = extractParameterSet()
        }

        annealingStep += 1

        let timeFactor = Float(annealingStep) * annealingRate

        // Oscillating temperature
        let baseTemp = 0.5 * (1.0 + sin(timeFactor * 0.5))
        let energyInfluence = (currentEnergy / 10.0).clamped(to: 0...1)
        let maxOscillationTemp = 0.5 + 0.5 * energyInfluence
        let minOscillationTemp = 0.01 + 0.2 * (1.0 - energyInfluence)
        self.temperature = minOscillationTemp + (maxOscillationTemp - minOscillationTemp) * baseTemp

        guard let params = currentParams else { return }

        // Perturb random subset of ALL parameters
        // Higher temperature → perturb more parameters simultaneously
        let perturbCount = max(1, min(ParameterSet.dimensions, Int(self.temperature * 3) + 1))
        let newParams = params.perturbed(temperature: self.temperature, count: perturbCount)

        // Evaluate: temporarily apply new params
        let oldEnergy = currentEnergy
        let savedParams = extractParameterSet()
        applyParameterSet(newParams)
        let newEnergy = calculateEnergy()
        applyParameterSet(savedParams) // Revert

        // Metropolis-Hastings acceptance
        let deltaEnergy = newEnergy - oldEnergy
        let acceptProb = exp(-deltaEnergy / max(self.temperature, 0.01))

        if deltaEnergy < 0 || Float.random(in: 0...1) < acceptProb {
            currentParams = newParams
            currentEnergy = newEnergy
            applyParameterSet(newParams) // Accept
        }
    }

    private func updateEnergy() {
        currentEnergy = calculateEnergy()
    }

    private func calculateEnergy() -> Float {
        var energy: Float = 0.0

        // Energy based on deviation from target element weights
        energy += abs(elementDistribution.wood - targetWoodWeight)
        energy += abs(elementDistribution.fire - targetFireWeight)
        energy += abs(elementDistribution.earth - targetEarthWeight)
        energy += abs(elementDistribution.metal - targetMetalWeight)
        energy += abs(elementDistribution.water - targetWaterWeight)

        // Normalize sum of target weights to avoid bias if user inputs very small or large numbers
        let targetSum = targetWoodWeight + targetFireWeight + targetEarthWeight + targetMetalWeight + targetWaterWeight
        if targetSum > 0 {
            energy /= targetSum
        }

        // Incorporate generation and attractor memory into energy function
        // (Assuming we want to maximize these, so they contribute negatively to energy)
        energy -= averageGeneration * 0.1 // Higher generation is better
        energy -= systemAttractorMemory * 0.5 // Higher memory is better

        // Add some "cost" for high temperature if we want to encourage low-temp states
        energy += self.temperature * 0.1

        return energy
    }

    // MARK: - Parameter Set Helpers

    private func extractParameterSet() -> ParameterSet {
        ParameterSet(values: [
            gogyoStrength,
            latticeStrength,
            sphereRadius,
            sphereAttractionStrength,
            sphereRepulsionStrength,
            targetWoodWeight,
            targetFireWeight,
            targetEarthWeight,
            targetMetalWeight,
            targetWaterWeight,
        ])
    }

    private func applyParameterSet(_ params: ParameterSet) {
        let v = params.values
        guard v.count >= ParameterSet.dimensions else { return }
        gogyoStrength = v[0]
        latticeStrength = v[1]
        sphereRadius = v[2]
        sphereAttractionStrength = v[3]
        sphereRepulsionStrength = v[4]
        targetWoodWeight = v[5]
        targetFireWeight = v[6]
        targetEarthWeight = v[7]
        targetMetalWeight = v[8]
        targetWaterWeight = v[9]
    }

    // MARK: - Save/Load Simulation

    func saveSimulation() {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "sim_gen\(Int(averageGeneration))_mem\(Int(systemAttractorMemory)).pent"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.performSave(to: url)
            }
        }
        #endif
    }

    func loadSimulation() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                self?.performLoad(from: url)
            }
        }
        #endif
    }

    private func performSave(to url: URL) {
        guard let renderer = renderer else { return }
        guard let particleData = renderer.exportParticleData() else { return }

        let header = SimulationSaveHeader(
            particleCount: renderer.particleCount,
            globalTime: renderer.getGlobalTime(),
            frameIndex: renderer.getFrameIndex(),
            gogyoStrength: gogyoStrength,
            temperature: temperature,
            latticeStrength: latticeStrength,
            cameraDistance: cameraDistance,
            particleScale: particleScale,
            sphereRadius: sphereRadius,
            sphereAttractionStrength: sphereAttractionStrength,
            sphereRepulsionStrength: sphereRepulsionStrength,
            sphereLatticeEnabled: sphereLatticeEnabled,
            targetWoodWeight: targetWoodWeight,
            targetFireWeight: targetFireWeight,
            targetEarthWeight: targetEarthWeight,
            targetMetalWeight: targetMetalWeight,
            targetWaterWeight: targetWaterWeight,
            annealingEnabled: annealingEnabled,
            annealingRate: annealingRate,
            currentGridSize: currentGridSize,
            bayesianOptEnabled: bayesianOptEnabled,
            boEquilibriumWait: boEquilibriumWait
        )

        guard let headerJson = try? JSONEncoder().encode(header) else { return }

        var data = Data()
        // Magic bytes
        data.append(contentsOf: "PENTASIM".utf8)
        // Version
        var version: UInt32 = 1
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        // Header JSON size
        var headerSize = UInt32(headerJson.count)
        withUnsafeBytes(of: &headerSize) { data.append(contentsOf: $0) }
        // Header JSON
        data.append(headerJson)
        // Particle data
        data.append(particleData)

        do {
            try data.write(to: url)
            print("Saved: \(url.lastPathComponent) (\(particleData.count / 1024)KB particles)")
        } catch {
            print("Save failed: \(error)")
        }
    }

    private func performLoad(from url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            print("Load failed: cannot read file")
            return
        }
        guard data.count >= 16 else {
            print("Load failed: file too small")
            return
        }

        // Verify magic
        guard String(data: data[0..<8], encoding: .utf8) == "PENTASIM" else {
            print("Load failed: invalid magic")
            return
        }

        // Version
        let version = data[8..<12].withUnsafeBytes { $0.load(as: UInt32.self) }
        guard version == 1 else {
            print("Load failed: unsupported version \(version)")
            return
        }

        // Header size
        let headerSize = Int(data[12..<16].withUnsafeBytes { $0.load(as: UInt32.self) })
        let headerEnd = 16 + headerSize
        guard data.count >= headerEnd else {
            print("Load failed: truncated header")
            return
        }

        // Parse header
        guard let header = try? JSONDecoder().decode(SimulationSaveHeader.self, from: data[16..<headerEnd]) else {
            print("Load failed: invalid header JSON")
            return
        }

        // Particle data
        let particleData = Data(data[headerEnd...])

        // Apply all parameters
        gogyoStrength = header.gogyoStrength
        temperature = header.temperature
        latticeStrength = header.latticeStrength
        cameraDistance = header.cameraDistance
        particleScale = header.particleScale
        sphereRadius = header.sphereRadius
        sphereAttractionStrength = header.sphereAttractionStrength
        sphereRepulsionStrength = header.sphereRepulsionStrength
        sphereLatticeEnabled = header.sphereLatticeEnabled
        targetWoodWeight = header.targetWoodWeight
        targetFireWeight = header.targetFireWeight
        targetEarthWeight = header.targetEarthWeight
        targetMetalWeight = header.targetMetalWeight
        targetWaterWeight = header.targetWaterWeight
        annealingEnabled = header.annealingEnabled
        annealingRate = header.annealingRate
        currentGridSize = header.currentGridSize
        bayesianOptEnabled = header.bayesianOptEnabled
        boEquilibriumWait = header.boEquilibriumWait
        controllableParticleCount = header.particleCount

        // Import particles
        renderer?.importParticleData(particleData, count: header.particleCount)
        renderer?.setGlobalTime(header.globalTime)
        renderer?.setFrameIndex(header.frameIndex)

        // Reset SA state to match loaded params
        currentParams = extractParameterSet()
        currentEnergy = calculateEnergy()

        print("Loaded: \(url.lastPathComponent) (gen=\(header.globalTime), \(header.particleCount) particles)")
    }

    // MARK: - Bayesian Optimization Step

    private func bayesianOptStep() {
        guard bayesianOptEnabled else {
            boWaitingForEquilibrium = false
            return
        }

        if !boWaitingForEquilibrium {
            // Propose new parameters via BO
            let proposed = bayesianOptimizer.propose()
            applyParameterSet(proposed)
            currentParams = proposed // SA will explore from here
            boProposedParams = proposed
            boWaitStartTime = Date()
            boWaitingForEquilibrium = true
        } else {
            // Check if equilibrium wait has elapsed
            let elapsed = Float(Date().timeIntervalSince(boWaitStartTime))
            if elapsed >= boEquilibriumWait {
                // Record the actual current state (SA may have refined it)
                let energy = calculateEnergy()
                let actualParams = extractParameterSet()
                bayesianOptimizer.record(params: actualParams, energy: energy)
                boObservationCount = bayesianOptimizer.observationCount
                if let best = bayesianOptimizer.bestEnergy {
                    boBestEnergy = best
                }
                boWaitingForEquilibrium = false
            }
        }
    }
}

// MARK: - Preview

#Preview {
    ContentView()
}

// MARK: - Extension for Clamping
extension Float {
    func clamped(to range: ClosedRange<Float>) -> Float {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
