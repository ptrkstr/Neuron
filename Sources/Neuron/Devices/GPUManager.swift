import Foundation
import Metal
import MetalPerformanceShaders
import Accelerate
import NumSwift

fileprivate extension Tensor {
  func asTexture(device: MTLDevice, commandQueue: MTLCommandQueue, size: TensorSize) -> MTLTexture? {
    guard  let commandBuffer = commandQueue.makeCommandBuffer(),
           let encoder = commandBuffer.makeBlitCommandEncoder() else { return nil }
    
    let width = size.columns
    let height = size.rows
    let depth = size.depth
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: width, height: height, mipmapped: false)
    descriptor.arrayLength = depth
    descriptor.textureType = .type2DArray
    
    guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
    let bytesPerRow = MemoryLayout<Float>.stride * width
    let region = MTLRegionMake2D(0, 0, width, height)
    let bufferSize = bytesPerRow * height * depth
    guard let buffer = device.makeBuffer(length: bufferSize, options: []) else { return nil }
    let bufferPointer = buffer.contents().bindMemory(to: Float.self, capacity: bufferSize/MemoryLayout<Float>.stride)
    for i in 0..<depth {
      for j in 0..<height {
        for k in 0..<width {
          bufferPointer[i*height*width + j*width + k] = value[i][j][k]
        }
      }
    }
    
    for i in 0..<depth {
      encoder.copy(from: buffer,
                   sourceOffset: bytesPerRow * height * i,
                   sourceBytesPerRow: bytesPerRow,
                   sourceBytesPerImage: bytesPerRow * height,
                   sourceSize: region.size,
                   to: texture,
                   destinationSlice: i,
                   destinationLevel: 0,
                   destinationOrigin: region.origin)
    }
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    return texture
  }

}

fileprivate extension MTLTexture {
  func get3d(commandQueue: MTLCommandQueue, device: MTLDevice) -> [[[Float]]] {
    guard  let commandBuffer = commandQueue.makeCommandBuffer(),
           let encoder = commandBuffer.makeBlitCommandEncoder() else { return [] }
    
    let width = width
    let height = height
    let depth = arrayLength
    let bytesPerRow = MemoryLayout<Float>.stride * width
    let region = MTLRegionMake2D(0, 0, width, height)
    var array3D = [[[Float]]](repeating: [[Float]](repeating: [Float](repeating: 0.0, count: width), count: height), count: depth)
    let bufferSize = bytesPerRow * height * depth
    guard let buffer = device.makeBuffer(length: bufferSize, options: []) else { return array3D }
    
    encoder.synchronize(resource: self)
    for i in 0..<depth {
      encoder.copy(from: self,
                   sourceSlice: i,
                   sourceLevel: 0,
                   sourceOrigin: region.origin,
                   sourceSize: region.size,
                   to: buffer,
                   destinationOffset: bytesPerRow * height * i,
                   destinationBytesPerRow: bytesPerRow,
                   destinationBytesPerImage: bytesPerRow * height)
    }
    
    encoder.endEncoding()
    commandBuffer.commit()
    commandBuffer.waitUntilCompleted()
    let bufferPointer = buffer.contents().bindMemory(to: Float.self, capacity: bufferSize/MemoryLayout<Float>.stride)
    for i in 0..<depth {
      for j in 0..<height {
        for k in 0..<width {
          array3D[i][j][k] = bufferPointer[i*height*width + j*width + k]
        }
      }
    }
    return array3D
  }
}

public typealias DataType = [[CFloat]]
public typealias ResultType = CFloat

public class GPUManager {
  public enum MetalFunction: String {
    case activation, derivate, conv2d, conv2d_array
  }
  
  private var currentRunningPipelines: [MTLComputePipelineState] = []
  private var device: MTLDevice? = MTLCreateSystemDefaultDevice()
  
  @Atomic
  private var textures: [Int: MTLTexture] = [:]
  
  lazy var queue = self.device?.makeCommandQueue()
  lazy var cmds = queue?.makeCommandBuffer()
  
  private func getFunction(_ function: MetalFunction) -> MTLFunction? {
    return try? device?.makeDefaultLibrary(bundle: Bundle.module).makeFunction(name: function.rawValue)
  }
  
  private func pipelineIfExists(type: MetalFunction) -> MTLComputePipelineState? {
    return self.currentRunningPipelines.filter({ $0.label == type.rawValue }).first
  }
  
  private func addPipeline(for type: MetalFunction) -> MTLComputePipelineState? {
    guard let device = self.device,
          let function = getFunction(type) else {
      return nil
    }
    
    do {
      let descriptor = MTLComputePipelineDescriptor()
      descriptor.label = type.rawValue
      descriptor.computeFunction = function
      
      let pipeline = try device.makeComputePipelineState(descriptor: descriptor,
                                                         options: [],
                                                         reflection: nil)
      
      self.currentRunningPipelines.append(pipeline)
      return pipeline
      
    } catch {
      print(error)
      return nil
    }
  }
  
  public func commit() -> [Tensor] {
    cmds?.commit()
    cmds?.waitUntilCompleted()
    return []
  }
  
  private func conv2dOutputSize(padding: NumSwift.ConvPadding,
                                strides: (rows: Int, columns: Int),
                                filterCount: Int,
                                filterSize: (rows: Int, columns: Int),
                                inputSize: (rows: Int, columns: Int, depth: Int)) -> TensorSize {
    let paddingValue = padding.extra(inputSize: (inputSize.rows, inputSize.columns), filterSize: filterSize)
    
    let rows = (((inputSize.rows + (paddingValue.top + paddingValue.bottom)) - (filterSize.rows - 1) - 1) / strides.rows) + 1
    let columns = (((inputSize.columns + (paddingValue.left + paddingValue.right)) - (filterSize.columns - 1) - 1) / strides.columns) + 1
    
    return TensorSize(array: [columns, rows, filterCount])
  }
  
  // returns a 3D tensor where each element is conv on the input with a filter
  public func conv2d(_ input: [[Tensor.Scalar]],
                     filter: [[Tensor.Scalar]],
                     padding: NumSwift.ConvPadding,
                     filterSize: (rows: Int, columns: Int),
                     strides: (rows: Int, columns: Int),
                     inputSize: (rows: Int, columns: Int, depth: Int)) -> Tensor {
    
    let outputSize = conv2dOutputSize(padding: padding,
                                      strides: strides,
                                      filterCount: 1,
                                      filterSize: filterSize,
                                      inputSize: inputSize)
    
    guard let device = device else {
      return Tensor()
    }
    
    let function: MetalFunction = .conv2d_array
    let pipeline: MTLComputePipelineState? = self.pipelineIfExists(type: function) ?? self.addPipeline(for: function)
    
    
    let newEncoder = cmds?.makeComputeCommandEncoder()
    
    guard let encoder = newEncoder, let pipelineStrong = pipeline else {
      return Tensor()
    }
    
    encoder.setComputePipelineState(pipelineStrong)
    
    let w = pipelineStrong.threadExecutionWidth
    let h = pipelineStrong.maxTotalThreadsPerThreadgroup / w
    let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
    
    let threadgroupsPerGrid = MTLSize(width: outputSize.columns / 2,
                                      height: outputSize.rows / 2,
                                      depth: outputSize.depth)
    
    var inSize = SIMD2(CUnsignedInt(inputSize.rows), CUnsignedInt(inputSize.columns))
    var outSize = SIMD2(CUnsignedInt(outputSize.rows), CUnsignedInt(outputSize.columns))
    var kSize = SIMD2(CUnsignedInt(filterSize.rows), CUnsignedInt(filterSize.columns))
    var strides = SIMD2(CUnsignedInt(strides.rows), CUnsignedInt(strides.columns))
    var padding = padding == .same ? 1 : 0
    
    encoder.setBytes(&inSize, length: MemoryLayout<SIMD2<CUnsignedInt>>.size, index: 3)
    encoder.setBytes(&outSize, length: MemoryLayout<SIMD2<CUnsignedInt>>.size, index: 4)
    encoder.setBytes(&kSize, length: MemoryLayout<SIMD2<CUnsignedInt>>.size, index: 5)
    encoder.setBytes(&strides, length: MemoryLayout<SIMD2<CUnsignedInt>>.size, index: 6)
    encoder.setBytes(&padding, length: MemoryLayout<Int>.size, index: 7)
    
    // output texture
    var filtersFlat: [Float] = filter.flatten()
    var flatInput: [Float] = input.flatten()
    
    guard let filterBuffer = device.makeBuffer(bytes: &filtersFlat,
                                               length: MemoryLayout<Float>.stride * filtersFlat.count,
                                               options: []),
          
            let outputBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride * outputSize.columns * outputSize.rows,
                                                 options: []),
          
            let inputBuffer = device.makeBuffer(bytes: &flatInput,
                                                length: MemoryLayout<Float>.stride * flatInput.count,
                                                options: []) else {
      return Tensor()
    }
    
    encoder.setBuffer(inputBuffer, offset: 0, index: 0)
    encoder.setBuffer(outputBuffer, offset: 0, index: 1)
    encoder.setBuffer(filterBuffer, offset: 0, index: 2)
    
    encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    encoder.endEncoding()
    
    cmds?.commit()
    cmds?.waitUntilCompleted()
    
    // this is slow
    let rowBytes =  outputSize.columns * MemoryLayout<Float>.stride
    let byteCount = outputSize.rows * rowBytes
    let totalSize = outputSize.rows * outputSize.columns
    
    let values = Array(UnsafeBufferPointer(start: outputBuffer.contents().bindMemory(to: Float.self,
                                                                                     capacity: byteCount),
                                           count: totalSize)).reshape(columns: outputSize.columns)
    return Tensor(values)
  }
  
  public func activate(_ num: [Float],
                       _ activationType: Activation,
                       derivate: Bool = false) -> [Float] {
    var data = num
    
    guard let device = self.device else {
      return num
    }
    
    let function: MetalFunction = derivate ? .derivate : .activation
    
    let pipeline: MTLComputePipelineState? = self.pipelineIfExists(type: function) ?? self.addPipeline(for: function)
    
    guard let dataBuffer = device.makeBuffer(bytes: &data,
                                             length: MemoryLayout<Float>.stride * data.count,
                                             options: []),
          
            let resultsBuffer = device.makeBuffer(length: MemoryLayout<Float>.stride * data.count,
                                                  options: []) else {
      return num
    }
    
    let newEncoder = cmds?.makeComputeCommandEncoder()
    
    guard let encoder = newEncoder, let pipelineStrong = pipeline else {
      return num
    }
    
    var activation = CUnsignedInt(activationType.index())
    
    encoder.setComputePipelineState(pipelineStrong)
    
    encoder.setBuffer(dataBuffer, offset: 0, index: 0)
    encoder.setBuffer(resultsBuffer, offset: 0, index: 1)
    encoder.setBytes(&activation, length: MemoryLayout<CUnsignedInt>.size, index: 2)
    
    switch activationType {
    case .leakyRelu(let limit):
      var limit = Float(limit)
      encoder.setBytes(&limit, length: MemoryLayout<Float>.size, index: 3)
    default:
      break
    }
    
    let w = pipelineStrong.threadExecutionWidth
    let h = pipelineStrong.maxTotalThreadsPerThreadgroup / w
    let threadsPerThreadgroup = MTLSizeMake(w, h, 1)
    
    let threadgroupsPerGrid = MTLSize(width: data.count / 2,
                                      height: 1,
                                      depth: 1)
    
    encoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
    encoder.endEncoding()
    
    //execution step
    cmds?.commit()
    cmds?.waitUntilCompleted()
    
    let values = Array(UnsafeBufferPointer(start: resultsBuffer.contents().bindMemory(to: Float.self,
                                                                                      capacity: MemoryLayout<Float>.size * num.count),
                                           count: num.count))
    
    return values
  }
  
  func activate(_ input: Tensor,
                inputSize: TensorSize,
                activationType: Activation,
                derivate: Bool = false) -> Tensor {
    
    guard let device = self.device, let queue = queue else {
      return Tensor()
    }
    
    let inputTexture = input.asTexture(device: device, commandQueue: queue, size: inputSize)
    
    print(inputTexture?.get3d(commandQueue: queue, device: device))
    // inputTexture?.get(device: device, commandQueue: queue, size: inputSize)
    return Tensor()
  }
  
}

