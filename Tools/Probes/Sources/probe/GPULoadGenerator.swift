import Foundation
import Metal
import Darwin

/// 用 Metal compute 制造可控的 GPU 负载。
///
/// 作用只有一个：在阶段一做「真值对照」——如果采样器在 GPU 真忙时上升、
/// 在空闲时回落，并且与占空比大致成正比，就说明读数不是噪声。
final class GPULoadGenerator {

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private let output: MTLBuffer
    private let threadCount = 262_144

    private static let kernelSource = """
    #include <metal_stdlib>
    using namespace metal;

    kernel void spin(device float *out [[buffer(0)]],
                     constant uint &iters [[buffer(1)]],
                     uint gid [[thread_position_in_grid]]) {
        float x = float(gid & 1023u) * 0.001f;
        float y = x + 1.0f;
        for (uint i = 0; i < iters; ++i) {
            x = fma(x, 1.0000001f, 0.0000001f);
            y = fma(y, 0.9999999f, 0.0000002f);
        }
        out[gid] = x + y;
    }
    """

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else { return nil }
        self.device = device
        self.queue = queue

        do {
            let library = try device.makeLibrary(source: Self.kernelSource, options: nil)
            guard let fn = library.makeFunction(name: "spin") else { return nil }
            self.pipeline = try device.makeComputePipelineState(function: fn)
        } catch {
            FileHandle.standardError.write("Metal 编译失败: \(error)\n".data(using: .utf8)!)
            return nil
        }

        guard let buffer = device.makeBuffer(length: threadCount * MemoryLayout<Float>.stride, options: .storageModeShared) else {
            return nil
        }
        self.output = buffer
    }

    var deviceName: String { device.name }

    /// 执行一次 dispatch，返回耗时（秒）。iterations 控制单次工作量。
    @discardableResult
    func burst(iterations: UInt32) -> Double {
        guard let cmd = queue.makeCommandBuffer(),
              let enc = cmd.makeComputeCommandEncoder() else { return 0 }
        enc.setComputePipelineState(pipeline)
        enc.setBuffer(output, offset: 0, index: 0)
        var iters = iterations
        enc.setBytes(&iters, length: MemoryLayout<UInt32>.size, index: 1)
        let tg = MTLSize(width: 64, height: 1, depth: 1)
        let grid = MTLSize(width: threadCount, height: 1, depth: 1)
        enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
        enc.endEncoding()
        let start = CFAbsoluteTimeGetCurrent()
        cmd.commit()
        cmd.waitUntilCompleted()
        return CFAbsoluteTimeGetCurrent() - start
    }

    /// 校准：找出使单次 dispatch 约等于 targetMs 的迭代次数。
    func calibrate(targetMs: Double) -> UInt32 {
        var iters: UInt32 = 2_000
        var elapsed = burst(iterations: iters)
        var guardCount = 0
        while elapsed * 1000 < targetMs && guardCount < 12 {
            let scale = max(1.2, min(8.0, targetMs / max(elapsed * 1000, 0.5)))
            iters = UInt32(min(Double(iters) * scale, 200_000_000))
            elapsed = burst(iterations: iters)
            guardCount += 1
        }
        return iters
    }
}
