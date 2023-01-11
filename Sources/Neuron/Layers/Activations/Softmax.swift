//
//  File.swift
//  
//
//  Created by William Vabrinskas on 4/30/22.
//

import Foundation
import NumSwift

/// Performs a Softmax activation.
public final class Softmax: ActivationLayer {
  public var encodingType: EncodingType = .softmax
  public var device: Device = CPU()
  public var biasEnabled: Bool = true
  public var trainable: Bool = true
  public var type: Activation = .softmax
  public var inputSize: TensorSize = TensorSize(array: []){
    didSet {
      outputSize = inputSize
    }
  }
  public var outputSize: TensorSize = TensorSize(array: [])
  public var weights: Tensor = Tensor()
  public var biases: Tensor = Tensor()
  public var initializer: Initializer?
  
  enum CodingKeys: String, CodingKey {
    case inputSize,
         type
  }
  
  convenience public init(from decoder: Decoder) throws {
    self.init()
    let container = try decoder.container(keyedBy: CodingKeys.self)
    self.inputSize = try container.decodeIfPresent(TensorSize.self, forKey: .inputSize) ?? TensorSize(array: [])
    self.outputSize = inputSize
  }
  
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(inputSize, forKey: .inputSize)
    try container.encode(encodingType, forKey: .type)
  }
  
  /// Default initializer for a Softmax activation.
  /// - Parameter inputSize: Optional input size at this layer. If this is the first layer you will need to set this.
  public init(inputSize: TensorSize = TensorSize(array: [])) {
    self.inputSize = inputSize
  }
  
  public func forward(tensor: Tensor) -> Tensor {
    let context = TensorContext { inputs, gradient in
      return (Tensor(gradient.value), Tensor())
    }
    
    let flatTensor = tensor.value[safe: 0]?[safe: 0] ?? [] //softmax requires 1D flat tensor
    var activationResult: [Tensor.Scalar] = []
    
    for i in 0..<flatTensor.count {
      activationResult.append(calculate(index: i, outputs: flatTensor))
    }
    
    let out = Tensor(activationResult, context: context)
    out.label = type.asString()
    return out
  }
  
  private func calculate(index: Int, outputs: [Tensor.Scalar]) -> Tensor.Scalar {
    let max = outputs.max() ?? 1
    var sum: Float = 0
    outputs.forEach { (output) in
      sum += pow(Float(Darwin.M_E), output - max)
    }
    
    return pow(Float(Darwin.M_E), outputs[index] - max) / sum
  }
  
  public func apply(gradients: Optimizer.Gradient){
    //no op
  }
}
