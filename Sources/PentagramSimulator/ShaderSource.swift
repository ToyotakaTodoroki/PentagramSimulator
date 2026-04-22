import Foundation

/// Metal shader source code for runtime compilation
public let metalShaderSource = """
#include <metal_stdlib>
using namespace metal;

// MARK: - Constants

constant float PI = 3.14159265359;
constant float TWO_PI = 6.28318530718;

// Element indices
constant int WOOD = 0;
constant int FIRE = 1;
constant int EARTH = 2;
constant int METAL_ELEM = 3;
constant int WATER = 4;

// Grid constants for 五行 interaction
constant uint DEFAULT_GRID_SIZE = 32; // Default grid size
constant float GRID_EXTENT = 15.0;
constant uint GRID_CHANNELS = 6; // wood, fire, earth, metal, water, count

// ==========================================
// 五行 Continuous Interaction Matrix
// ==========================================
// GOGYO[i][j] = force that element i feels from density of element j
// Based on angular model:
//   diff 0 (0°)   self   → weak cohesion  +0.05
//   diff 1 (72°)  +相生  → attraction     +0.20
//   diff 4 (288°) -相生  → attraction     +0.15
//   diff 2 (144°) +相剋  → repulsion      -0.50
//   diff 3 (216°) -相剋  → repulsion      -0.35
//
constant float GOGYO[5][5] = {
    //  wood   fire   earth  metal  water       ← density of
    {  0.05,  0.20, -0.50, -0.35,  0.15 },  // wood feels
    {  0.15,  0.05,  0.20, -0.50, -0.35 },  // fire feels
    { -0.35,  0.15,  0.05,  0.20, -0.50 },  // earth feels
    { -0.50, -0.35,  0.15,  0.05,  0.20 },  // metal feels
    {  0.20, -0.50, -0.35,  0.15,  0.05 },  // water feels
};

// MARK: - Data Structures

struct Particle {
    float4 positionMass;    // xyz: position, w: mass
    float4 velocityAge;     // xyz: velocity, w: age
    float4 elementWeights;  // wood, fire, earth, metal (water = 1 - sum)
    float4 metadata;        // x: generation, y: attractorMemory, z: predictability, w: unused
};

struct SimulationParams {
    float deltaTime;
    float globalTime;
    float transitionRate;
    float attractorStrength;
    float interactionRadius;
    float generationRate;
    uint particleCount;
    uint frameIndex;
    float gogyoStrength;    // base 五行 interaction strength
    float temperature;      // annealing temperature (high=chaos, low=order)
    float latticeStrength;  // strength of lattice-forming forces

    // Sphere Lattice parameters
    float sphereRadius;
    float sphereAttractionStrength;
    float sphereRepulsionStrength;
    bool sphereLatticeEnabled;

    // Localized Regions parameters
    uint numSpatialRegions;

    // Configurable Grid Size
    uint currentGridSize;
    uint gridTotal;
};

// MARK: - Spatial Region Structure
struct SpatialRegion {
    float3 center;
    float radius;
    float gogyoStrength;
    float temperature;
    float latticeStrength;
    // Add other parameters you want to localize here
};

struct RenderParams {
    float4x4 viewProjection;
    float3 cameraPosition;
    float time;
    float particleScale;
    float bifurcationIntensity;
    float2 _padding;
};

// MARK: - Random Number Generation

float hash(float n) {
    return fract(sin(n) * 43758.5453123);
}

float hash3(float3 p) {
    return fract(sin(dot(p, float3(12.9898, 78.233, 45.543))) * 43758.5453);
}

float3 hash33(float3 p) {
    float3 q = float3(
        dot(p, float3(127.1, 311.7, 74.7)),
        dot(p, float3(269.5, 183.3, 246.1)),
        dot(p, float3(113.5, 271.9, 124.6))
    );
    return fract(sin(q) * 43758.5453);
}

// MARK: - Noise Functions

float simplex3D(float3 p) {
    float3 s = floor(p + dot(p, float3(1.0/3.0)));
    float3 x = p - s + dot(s, float3(1.0/6.0));
    float3 e = step(float3(0.0), x - x.yzx);
    float3 i1 = e * (1.0 - e.zxy);
    float3 i2 = 1.0 - e.zxy * (1.0 - e);
    float3 x1 = x - i1 + 1.0/6.0;
    float3 x2 = x - i2 + 1.0/3.0;
    float3 x3 = x - 0.5;
    float4 w, d;
    w.x = dot(x, x);
    w.y = dot(x1, x1);
    w.z = dot(x2, x2);
    w.w = dot(x3, x3);
    w = max(0.6 - w, 0.0);
    d.x = dot(hash33(s) - 0.5, x);
    d.y = dot(hash33(s + i1) - 0.5, x1);
    d.z = dot(hash33(s + i2) - 0.5, x2);
    d.w = dot(hash33(s + 1.0) - 0.5, x3);
    w *= w;
    w *= w;
    d *= w;
    return dot(d, float4(52.0));
}

float fbm(float3 p, int octaves) {
    float value = 0.0;
    float amplitude = 0.5;
    float frequency = 1.0;
    for (int i = 0; i < octaves; i++) {
        value += amplitude * simplex3D(p * frequency);
        amplitude *= 0.5;
        frequency *= 2.0;
    }
    return value;
}

// MARK: - Strange Attractor Functions

float3 lorenzStep(float3 p, float sigma, float rho, float beta) {
    float dx = sigma * (p.y - p.x);
    float dy = p.x * (rho - p.z) - p.y;
    float dz = p.x * p.y - beta * p.z;
    return float3(dx, dy, dz);
}

float3 rosslerStep(float3 p, float a, float b, float c) {
    float dx = -p.y - p.z;
    float dy = p.x + a * p.y;
    float dz = b + p.z * (p.x - c);
    return float3(dx, dy, dz);
}

float3 thomasStep(float3 p, float b) {
    float dx = sin(p.y) - b * p.x;
    float dy = sin(p.z) - b * p.y;
    float dz = sin(p.x) - b * p.z;
    return float3(dx, dy, dz);
}

// MARK: - Metal to Water Fragmentation Noise

float3 metalToWaterFragmentation(float3 position, float metalWeight, float waterWeight,
                                   float attractorMemory, float time) {
    float transitionPhase = waterWeight / max(metalWeight + waterWeight, 0.001);

    float3 structuredComponent = float3(
        sin(position.x * PI + time),
        sin(position.y * PI + time * 1.1),
        sin(position.z * PI + time * 0.9)
    ) * (1.0 - transitionPhase);

    float rhoModified = 28.0 + attractorMemory * 5.0;
    float3 chaoticComponent = lorenzStep(
        position * 0.1,
        10.0,
        rhoModified,
        8.0 / 3.0
    ) * transitionPhase;

    float fragmentationScale = 0.5 + attractorMemory * 0.5;

    float3 thomasInfluence = thomasStep(position * 0.05, 0.208 - attractorMemory * 0.01);
    chaoticComponent += thomasInfluence * attractorMemory * 0.3;

    return (structuredComponent + chaoticComponent) * fragmentationScale;
}

// MARK: - Primordial vs Reborn Wood Noise

float3 primordialWoodNoise(float3 position, float time, uint particleId) {
    float3 seed = position + float3(float(particleId) * 0.001, time * 0.1, 0.0);
    return (hash33(seed) - 0.5) * 2.0;
}

float3 rebornWoodNoise(float3 position, float time, float attractorMemory) {
    float a = 0.2 + attractorMemory * 0.1;
    float b = 0.2;
    float c = 5.7 + attractorMemory * 0.5;

    float3 p = position + float3(sin(time * 0.1), cos(time * 0.13), 0.0);
    float3 rossler = rosslerStep(p * 0.1, a, b, c);

    float fractalDetail = fbm(position * (1.0 + attractorMemory), int(3 + attractorMemory * 2));

    return rossler * 0.01 + float3(fractalDetail) * 0.1;
}

// MARK: - Grid Helper Functions

uint3 worldToGrid(float3 pos, uint currentGridSize) {
    float3 norm = clamp((pos + GRID_EXTENT) / (2.0 * GRID_EXTENT), 0.0, 1.0 - 0.001);
    return uint3(norm * float(currentGridSize));
}

float3 gridToWorld(int3 cell, uint currentGridSize) {
    return (float3(cell) + 0.5) / float(currentGridSize) * (2.0 * GRID_EXTENT) - GRID_EXTENT;
}

uint gridFlatIndex(uint3 cell, uint currentGridSize) {
    return (cell.x + cell.y * currentGridSize + cell.z * currentGridSize * currentGridSize) * GRID_CHANNELS;
}

// MARK: - Grid Compute Kernels

kernel void clearGrid(
    device atomic_uint* grid [[buffer(0)]],
    constant SimulationParams& params [[buffer(1)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.gridTotal * GRID_CHANNELS) return;
    atomic_store_explicit(&grid[id], 0, memory_order_relaxed);
}

kernel void accumulateGrid(
    device const Particle* particles [[buffer(0)]],
    device atomic_uint* grid [[buffer(1)]],
    constant SimulationParams& params [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) return;

    Particle p = particles[id];
    float3 pos = p.positionMass.xyz;
    float4 w = p.elementWeights;
    float waterW = max(0.0, 1.0 - w.x - w.y - w.z - w.w);

    uint3 cell = worldToGrid(pos, params.currentGridSize);
    uint idx = gridFlatIndex(cell, params.currentGridSize);

    // Quantize weights (x256) and accumulate atomically
    atomic_fetch_add_explicit(&grid[idx + 0], uint(w.x * 256.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&grid[idx + 1], uint(w.y * 256.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&grid[idx + 2], uint(w.z * 256.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&grid[idx + 3], uint(w.w * 256.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&grid[idx + 4], uint(waterW * 256.0), memory_order_relaxed);
    atomic_fetch_add_explicit(&grid[idx + 5], 1, memory_order_relaxed);
}

// MARK: - Compute Kernel: Particle Update

kernel void updateParticles(
    device Particle* particles [[buffer(0)]],
    constant SimulationParams& params [[buffer(1)]],
    device const uint* grid [[buffer(2)]],
    uint id [[thread_position_in_grid]]
) {
    if (id >= params.particleCount) return;

    Particle p = particles[id];

    float3 position = p.positionMass.xyz;
    float mass = p.positionMass.w;
    float3 velocity = p.velocityAge.xyz;
    float age = p.velocityAge.w;
    float4 weights = p.elementWeights;
    float generation = p.metadata.x;
    float attractorMemory = p.metadata.y;

    float waterWeight = max(0.0, 1.0 - weights.x - weights.y - weights.z - weights.w);

    // Temperature parameters
    float T = max(params.temperature, 0.01);
    float invT = 1.0 / T;

    // My element weights as array
    float myW[5] = { weights.x, weights.y, weights.z, weights.w, waterWeight };

    // Dominant element (still needed for element-specific dynamics)
    float maxWeight = weights.x;
    int dominant = WOOD;
    if (weights.y > maxWeight) { maxWeight = weights.y; dominant = FIRE; }
    if (weights.z > maxWeight) { maxWeight = weights.z; dominant = EARTH; }
    if (weights.w > maxWeight) { maxWeight = weights.w; dominant = METAL_ELEM; }
    if (waterWeight > maxWeight) { maxWeight = waterWeight; dominant = WATER; }

    float predictability = tanh(mass / 10.0) - waterWeight * 0.5;
    predictability = clamp(predictability, 0.0, 1.0);
    p.metadata.z = predictability;

    age += params.deltaTime;

    // ==========================================
    // 五行 Continuous Grid Interaction
    // ==========================================
    // Precompute response vector:
    // response[j] = how strongly I react to density of element j
    // This blends ALL my element weights through the GOGYO matrix
    // → continuous "fog-like" angular force
    float response[5] = { 0, 0, 0, 0, 0 };
    for (int i = 0; i < 5; i++) {
        if (myW[i] < 0.01) continue;
        for (int j = 0; j < 5; j++) {
            response[j] += myW[i] * GOGYO[i][j];
        }
    }

    uint3 myCell = worldToGrid(position, params.currentGridSize);
    float3 gogyoForce = float3(0.0);

    for (int dx = -1; dx <= 1; dx++) {
        for (int dy = -1; dy <= 1; dy++) {
            for (int dz = -1; dz <= 1; dz++) {
                int3 nc = int3(myCell) + int3(dx, dy, dz);
                if (nc.x < 0 || nc.x >= int(params.currentGridSize) ||
                    nc.y < 0 || nc.y >= int(params.currentGridSize) ||
                    nc.z < 0 || nc.z >= int(params.currentGridSize)) continue;

                uint nIdx = gridFlatIndex(uint3(nc), params.currentGridSize);
                uint count = grid[nIdx + 5];
                if (count == 0) continue;

                // De-quantize element densities
                float densities[5];
                densities[0] = float(grid[nIdx + 0]) / 256.0;
                densities[1] = float(grid[nIdx + 1]) / 256.0;
                densities[2] = float(grid[nIdx + 2]) / 256.0;
                densities[3] = float(grid[nIdx + 3]) / 256.0;
                densities[4] = float(grid[nIdx + 4]) / 256.0;

                // Direction from me to cell center
                float3 cellCenter = gridToWorld(nc, params.currentGridSize);
                float3 toCell = cellCenter - position;
                float dist = length(toCell);
                if (dist < 0.01) continue;
                float3 dir = toCell / dist;

                // Inverse-square falloff
                float falloff = 1.0 / (1.0 + dist * dist);

                // Continuous force: dot(response, density)
                float forceScale = 0.0;
                for (int j = 0; j < 5; j++) {
                    forceScale += response[j] * densities[j];
                }

                gogyoForce += dir * forceScale * falloff;
            }
        }
    }

    // 五行 force scaled by gogyoStrength / temperature
    // Low temp → strong interaction (crystallization)
    // High temp → weak interaction (dissolution)
    velocity += gogyoForce * params.gogyoStrength * invT * params.deltaTime;

    // ==========================================
    // Sphere Lattice Forces
    // ==========================================
    if (params.sphereLatticeEnabled) {
        float distToCenter = length(position);
        float3 dirToCenter = (distToCenter > 0.001) ? normalize(position) : float3(0.0, 1.0, 0.0); // Avoid div by zero

        // Force to attract/repel to sphereRadius
        float deviation = distToCenter - params.sphereRadius;
        velocity -= dirToCenter * deviation * params.sphereAttractionStrength * 5.0 * params.deltaTime; // Increased multiplier

        // Stronger repulsion if inside a small inner radius (to prevent collapse)
        if (distToCenter < params.sphereRadius * 0.5) {
            velocity += dirToCenter * params.sphereRepulsionStrength * 20.0 * params.deltaTime; // Increased multiplier
        }
        // Additional repulsion if very close to center
        if (distToCenter < 0.5) {
             velocity += dirToCenter * 40.0 * params.sphereRepulsionStrength * params.deltaTime; // Increased multiplier
        }
    }

    // ==========================================
    // Element-specific dynamics (scaled by temperature)
    // ==========================================
    float3 elementForce = float3(0.0);

    if (dominant == WOOD) {
        elementForce.y += 0.1;

        if (generation < 0.5) {
            elementForce += primordialWoodNoise(position, params.globalTime, id) * 0.5;
        } else {
            elementForce += rebornWoodNoise(position, params.globalTime, attractorMemory) * 0.5;
        }

        float speed = length(velocity);
        if (speed > 2.0) {
            velocity *= 0.95;
        }
    }
    else if (dominant == FIRE) {
        float speed = length(velocity);
        if (speed < 3.0 && speed > 0.0) {
            velocity *= 1.0 + 0.1 * params.deltaTime;
        }

        elementForce += (hash33(position + params.globalTime) - 0.5) * 1.6;

        if (length(position) > 0.1) {
            elementForce += normalize(position) * 0.05;
        }
    }
    else if (dominant == EARTH) {
        float dist = length(position);
        if (dist > 0.1) {
            elementForce -= normalize(position) * params.attractorStrength;
        }

        velocity *= 1.0 - 0.1 * params.deltaTime;

        mass += 0.01 * params.deltaTime;
    }
    else if (dominant == METAL_ELEM) {
        if (params.sphereLatticeEnabled) {
            // Spherical lattice: try to quantize angles
            float r = length(position);
            if (r > 0.01) {
                float theta = acos(position.y / r); // polar angle
                float phi = atan2(position.z, position.x); // azimuthal angle

                // Quantize angles
                float quantizedTheta = round(theta / (PI / params.latticeStrength)) * (PI / params.latticeStrength);
                float quantizedPhi = round(phi / (TWO_PI / params.latticeStrength)) * (TWO_PI / params.latticeStrength);

                // Convert back to Cartesian and apply force
                float3 targetPosition = float3(
                    r * sin(quantizedTheta) * cos(quantizedPhi),
                    r * cos(quantizedTheta),
                    r * sin(quantizedTheta) * sin(quantizedPhi)
                );
                float3 toTarget = targetPosition - position;
                elementForce += toTarget * 0.3 * params.latticeStrength; // latticeStrength influences snapping force
            }
        } else {
            // Existing Cartesian lattice formation
            float gridSize = 1.0;
            float3 targetPosition = round(position / gridSize) * gridSize;
            float3 toTarget = targetPosition - position;
            elementForce += toTarget * 0.3 * params.deltaTime;
        }

        velocity *= 1.0 - 0.2 * params.deltaTime;

        float informationDensity = 1.0 - (-weights.x * log(max(weights.x, 0.0001))
                                          - weights.y * log(max(weights.y, 0.0001))
                                          - weights.z * log(max(weights.z, 0.0001))
                                          - weights.w * log(max(weights.w, 0.0001))) / log(5.0);
        attractorMemory += informationDensity * params.deltaTime * 0.1;
    }
    else if (dominant == WATER) {
        float3 fragNoise = metalToWaterFragmentation(
            position, weights.w, waterWeight, attractorMemory, params.globalTime
        );
        elementForce += fragNoise;

        float3 attractorVel = lorenzStep(position * 0.1, 10.0 + attractorMemory * 2.0, 28.0, 8.0/3.0);
        velocity = mix(velocity, attractorVel * 0.1, 0.3 * params.deltaTime);

        mass *= 1.0 - 0.05 * params.deltaTime;
        mass = max(mass, 0.1);
    }

    // Element forces scaled by temperature (more chaos when hot)
    velocity += elementForce * params.deltaTime * (0.3 + T * 0.7);

    // ==========================================
    // Thermal noise (Brownian motion from temperature)
    // ==========================================
    float3 thermalNoise = (hash33(position * 3.7 + float3(float(id) * 0.001, params.globalTime * 0.37, 0.0)) - 0.5);
    velocity += thermalNoise * T * 0.8 * params.deltaTime;

    // ==========================================
    // Temperature-dependent damping
    // Low temp → more damping → freezing
    // High temp → less damping → free movement
    // ==========================================
    float dampingRate = 0.02 + 0.08 * invT * min(invT, 3.0);
    dampingRate = clamp(dampingRate, 0.01, 0.3);
    velocity *= 1.0 - dampingRate * params.deltaTime;

    // ==========================================
    // State transition (相生 cycle)
    // ==========================================
    float transitionAmount = params.generationRate * params.deltaTime * (1.0 + age * 0.1);
    // Temperature accelerates transitions (thermal excitation)
    transitionAmount *= (0.5 + T * 0.5);

    if (dominant == WOOD) {
        weights.x -= transitionAmount;
        weights.y += transitionAmount;
    } else if (dominant == FIRE) {
        weights.y -= transitionAmount;
        weights.z += transitionAmount;
    } else if (dominant == EARTH) {
        weights.z -= transitionAmount;
        weights.w += transitionAmount;
    } else if (dominant == METAL_ELEM) {
        weights.w -= transitionAmount;
    } else if (dominant == WATER) {
        weights.x += transitionAmount;

        if (weights.x > waterWeight) {
            generation += 1.0;
            age = 0.0;
        }
    }

    weights = clamp(weights, 0.0, 1.0);

    // ==========================================
    // Position update and boundary
    // ==========================================
    position += velocity * params.deltaTime;

    float boundary = 15.0;
    if (abs(position.x) > boundary) velocity.x *= -0.8;
    if (abs(position.y) > boundary) velocity.y *= -0.8;
    if (abs(position.z) > boundary) velocity.z *= -0.8;
    position = clamp(position, -boundary, boundary);

    p.positionMass = float4(position, mass);
    p.velocityAge = float4(velocity, age);
    p.elementWeights = weights;
    p.metadata.x = generation;
    p.metadata.y = attractorMemory;

    particles[id] = p;
}

// MARK: - Vertex Shader

struct VertexOut {
    float4 position [[position]];
    float4 color;
    float pointSize [[point_size]];
    float3 worldPosition;
    float4 elementWeights;
    float generation;
    float attractorMemory;
    float predictability;
};

vertex VertexOut particleVertex(
    device const Particle* particles [[buffer(0)]],
    constant RenderParams& params [[buffer(1)]],
    uint vertexId [[vertex_id]]
) {
    Particle p = particles[vertexId];

    float3 position = p.positionMass.xyz;
    float mass = p.positionMass.w;
    float4 weights = p.elementWeights;
    float generation = p.metadata.x;
    float attractorMemory = p.metadata.y;
    float predictability = p.metadata.z;
    float waterWeight = max(0.0, 1.0 - weights.x - weights.y - weights.z - weights.w);

    VertexOut out;
    out.position = params.viewProjection * float4(position, 1.0);
    out.worldPosition = position;
    out.elementWeights = float4(weights.xyz, waterWeight);
    out.generation = generation;
    out.attractorMemory = attractorMemory;
    out.predictability = predictability;

    out.pointSize = params.particleScale * (1.0 + mass * 0.5);

    float3 woodColor = float3(0.2, 0.8, 0.3);
    float3 fireColor = float3(1.0, 0.3, 0.1);
    float3 earthColor = float3(0.9, 0.7, 0.2);
    float3 metalColor = float3(0.8, 0.8, 0.9);
    float3 waterColor = float3(0.2, 0.4, 0.9);

    float3 color = woodColor * weights.x +
                   fireColor * weights.y +
                   earthColor * weights.z +
                   metalColor * weights.w +
                   waterColor * waterWeight;

    float transitionIntensity = 1.0 - (max(weights.x, max(weights.y, max(weights.z, max(weights.w, waterWeight)))));
    if (transitionIntensity > 0.3 * params.bifurcationIntensity) {
        float hueShift = sin(params.time * 10.0 + position.x + position.y) * transitionIntensity;
        float3 shifted = float3(
            color.x * cos(hueShift) - color.y * sin(hueShift),
            color.x * sin(hueShift) + color.y * cos(hueShift),
            color.z
        );
        color = mix(color, abs(shifted), transitionIntensity * 0.5);
    }

    float generationGlow = 1.0 + generation * 0.1;
    color *= generationGlow;

    if (attractorMemory > 0.1) {
        float iridescence = sin(attractorMemory * 10.0 + params.time) * 0.1;
        color += float3(iridescence, iridescence * 0.5, -iridescence);
    }

    out.color = float4(color, 0.8);

    return out;
}

// MARK: - Fragment Shader

fragment float4 particleFragment(
    VertexOut in [[stage_in]],
    float2 pointCoord [[point_coord]]
) {
    float2 centerOffset = pointCoord - 0.5;
    float dist = length(centerOffset);

    float sharpness = mix(0.2, 0.45, in.predictability);
    float alpha = 1.0 - smoothstep(sharpness, 0.5, dist);

    if (in.generation > 0.5) {
        float ringCount = floor(in.generation);
        float ringPattern = sin(dist * ringCount * 20.0) * 0.5 + 0.5;
        alpha *= 0.8 + ringPattern * 0.2;
    }

    if (in.attractorMemory > 0.2) {
        float fractalEdge = fbm(float3(pointCoord * 10.0, in.attractorMemory), 3);
        alpha *= 0.9 + fractalEdge * 0.2;
    }

    if (alpha < 0.01) discard_fragment();

    return float4(in.color.rgb, in.color.a * alpha);
}
"""
