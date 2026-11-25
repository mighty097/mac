import MetalKit

// MARK: - GPU data layout (must match the Metal structs below, 32-bit floats only)

/// One snowflake quad. All values are in view points, origin at the bottom-left corner.
struct SnowGPUInstance {
    var cx: Float
    var cy: Float
    var hw: Float
    var hh: Float
    var rotation: Float
    var alpha: Float
    var softness: Float
    var pad: Float = 0
}

/// One vertex of the snowdrift mesh. Color is straight (non-premultiplied) RGBA.
struct DriftVertex {
    var x: Float
    var y: Float
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

struct DriftColor {
    var r: Float
    var g: Float
    var b: Float
    var a: Float
}

/// Everything the renderer needs to draw one frame.
struct SnowFrameOutput {
    var particles: [SnowGPUInstance] = []
    var drift: [DriftVertex] = []

    mutating func reset() {
        particles.removeAll(keepingCapacity: true)
        drift.removeAll(keepingCapacity: true)
    }
}

private struct SnowUniforms {
    var viewport: SIMD2<Float>
}

// MARK: - Metal shader source (compiled at launch; CI also compiles it with `xcrun metal`)

enum SnowShaders {
    static let source = """
#include <metal_stdlib>
using namespace metal;

struct SnowParticle {
    float cx;
    float cy;
    float hw;
    float hh;
    float rotation;
    float alpha;
    float softness;
    float pad;
};

struct SnowUniforms {
    float2 viewport;
};

struct SnowVertexOut {
    float4 position [[position]];
    float2 uv;
    float alpha;
    float softness;
};

vertex SnowVertexOut snowVertex(
    uint vertexID [[vertex_id]],
    uint instanceID [[instance_id]],
    const device SnowParticle* particles [[buffer(0)]],
    constant SnowUniforms& uniforms [[buffer(1)]]
) {
    const float2 corners[6] = {
        float2(-1.0, -1.0), float2(1.0, -1.0), float2(-1.0, 1.0),
        float2(-1.0, 1.0), float2(1.0, -1.0), float2(1.0, 1.0)
    };
    SnowParticle particle = particles[instanceID];
    float2 corner = corners[vertexID];
    float cosine = cos(particle.rotation);
    float sine = sin(particle.rotation);
    float2 local = float2(corner.x * particle.hw, corner.y * particle.hh);
    float2 rotated = float2(
        local.x * cosine - local.y * sine,
        local.x * sine + local.y * cosine
    );
    float2 point = float2(particle.cx, particle.cy) + rotated;
    SnowVertexOut output;
    output.position = float4(
        point.x / uniforms.viewport.x * 2.0 - 1.0,
        point.y / uniforms.viewport.y * 2.0 - 1.0,
        0.0,
        1.0
    );
    output.uv = corner;
    output.alpha = particle.alpha;
    output.softness = particle.softness;
    return output;
}

fragment half4 snowFragment(SnowVertexOut input [[stage_in]]) {
    float distanceFromCenter = length(input.uv);
    float2 lobeA = input.uv - float2(-0.20, 0.10);
    float2 lobeB = input.uv - float2(0.18, -0.17);
    float core = exp(-distanceFromCenter * distanceFromCenter * mix(3.0, 4.6, input.softness));
    float lobe = max(exp(-dot(lobeA, lobeA) * 15.0) * 0.24,
                     exp(-dot(lobeB, lobeB) * 18.0) * 0.18);
    float innerEdge = mix(0.40, 0.64, input.softness);
    float feather = 1.0 - smoothstep(innerEdge, 1.0, distanceFromCenter);
    float alpha = min(1.0, feather * (core + lobe) * input.alpha);
    half3 snowColor = half3(0.94, 0.975, 1.0);
    return half4(snowColor * half(alpha), half(alpha));
}

struct DriftVertexIn {
    float x;
    float y;
    float r;
    float g;
    float b;
    float a;
};

struct DriftVertexOut {
    float4 position [[position]];
    float4 color;
};

vertex DriftVertexOut driftVertex(
    uint vertexID [[vertex_id]],
    const device DriftVertexIn* vertices [[buffer(0)]],
    constant SnowUniforms& uniforms [[buffer(1)]]
) {
    DriftVertexIn item = vertices[vertexID];
    DriftVertexOut output;
    output.position = float4(
        item.x / uniforms.viewport.x * 2.0 - 1.0,
        item.y / uniforms.viewport.y * 2.0 - 1.0,
        0.0,
        1.0
    );
    output.color = float4(item.r, item.g, item.b, item.a);
    return output;
}

fragment half4 driftFragment(DriftVertexOut input [[stage_in]]) {
    float alpha = clamp(input.color.a, 0.0, 1.0);
    return half4(half3(input.color.rgb * alpha), half(alpha));
}
"""
}

// MARK: - Metal view

/// Transparent MTKView. It drives the frame loop (display-synchronised), asks `onFrame`
/// to run the simulation, then draws snowdrifts (triangle mesh) and snowflakes (instanced quads).
final class SnowMetalView: MTKView, MTKViewDelegate {
    var onFrame: (() -> Void)?

    private let commandQueue: MTLCommandQueue
    private let particlePipeline: MTLRenderPipelineState
    private let driftPipeline: MTLRenderPipelineState
    private var particleBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var driftBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var slot = 0
    private var particleCount = 0
    private var driftCount = 0

    init?(size: CGSize) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: SnowShaders.source, options: nil),
              let particleVertex = library.makeFunction(name: "snowVertex"),
              let particleFragment = library.makeFunction(name: "snowFragment"),
              let driftVertex = library.makeFunction(name: "driftVertex"),
              let driftFragment = library.makeFunction(name: "driftFragment") else {
            return nil
        }

        let particleDescriptor = MTLRenderPipelineDescriptor()
        particleDescriptor.vertexFunction = particleVertex
        particleDescriptor.fragmentFunction = particleFragment
        let driftDescriptor = MTLRenderPipelineDescriptor()
        driftDescriptor.vertexFunction = driftVertex
        driftDescriptor.fragmentFunction = driftFragment

        for descriptor in [particleDescriptor, driftDescriptor] {
            let attachment = descriptor.colorAttachments[0]!
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            attachment.sourceRGBBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        }

        guard let particleState = try? device.makeRenderPipelineState(descriptor: particleDescriptor),
              let driftState = try? device.makeRenderPipelineState(descriptor: driftDescriptor) else {
            return nil
        }

        commandQueue = queue
        particlePipeline = particleState
        driftPipeline = driftState
        super.init(frame: CGRect(origin: .zero, size: size), device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColorMake(0, 0, 0, 0)
        framebufferOnly = true
        // The view runs its own display-synchronised loop; start()/stop() toggle `isPaused`.
        isPaused = true
        enableSetNeedsDisplay = false
        wantsLayer = true
        layer?.isOpaque = false
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Copies one frame of geometry into a GPU buffer (three buffers rotate so the GPU never reads one being written).
    func submit(_ output: SnowFrameOutput) {
        slot = (slot + 1) % 3
        particleCount = output.particles.count
        driftCount = output.drift.count
        if particleCount > 0 {
            upload(output.particles, into: &particleBuffers[slot])
            if particleBuffers[slot] == nil { particleCount = 0 }
        }
        if driftCount > 0 {
            upload(output.drift, into: &driftBuffers[slot])
            if driftBuffers[slot] == nil { driftCount = 0 }
        }
    }

    private func upload<T>(_ items: [T], into buffer: inout MTLBuffer?) {
        let length = MemoryLayout<T>.stride * items.count
        if buffer == nil || (buffer?.length ?? 0) < length {
            buffer = device?.makeBuffer(length: max(4096, length * 2), options: .storageModeShared)
        }
        guard let target = buffer else { return }
        items.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                target.contents().copyMemory(from: base, byteCount: raw.count)
            }
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        onFrame?()
        render()
    }

    private func render() {
        guard let pass = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        var uniforms = SnowUniforms(viewport: SIMD2<Float>(Float(bounds.width), Float(bounds.height)))

        if driftCount > 0, let buffer = driftBuffers[slot] {
            encoder.setRenderPipelineState(driftPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SnowUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: driftCount)
        }

        if particleCount > 0, let buffer = particleBuffers[slot] {
            encoder.setRenderPipelineState(particlePipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SnowUniforms>.stride, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: particleCount)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
