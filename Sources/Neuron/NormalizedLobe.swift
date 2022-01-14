//
//  File.swift
//  
//
//  Created by William Vabrinskas on 1/13/22.
//

import Foundation
import UIKit

public class NormalizedLobe: Lobe {
  private var normalizer: BatchNormalizer = .init()
  public var normalizerLearningParams: (beta: Float, gamma: Float) {
    return (normalizer.beta, normalizer.gamma)
  }
  
  public convenience init(model: LobeModel, learningRate: Float, beta: Float, gamma: Float) {
    self.init(model: model, learningRate: learningRate)
    self.normalizer = BatchNormalizer(gamma: gamma, beta: beta)
  }
  
  public convenience init(neurons: [Neuron], activation: Activation = .none, beta: Float, gamma: Float) {
    self.init(neurons: neurons, activation: activation)
    self.normalizer = BatchNormalizer(gamma: gamma, beta: beta)
  }
  
  override public init(model: LobeModel, learningRate: Float) {
    super.init(model: model, learningRate: learningRate)
    self.isNormalized = true
  }
  
  override public init(neurons: [Neuron], activation: Activation = .none) {
    super.init(neurons: neurons, activation: activation)
    self.isNormalized = true
  }
  
  public override func feed(inputs: [Float]) -> [Float] {
    let results = super.feed(inputs: inputs)
    let normalizedInputs = self.normalizer.normalize(activations: results)
    return normalizedInputs
  }
  
  public override func adjustWeights(_ constrain: ClosedRange<Float>? = nil) {
    for neuron in neurons {
      neuron.adjustWeights(constrain, normalizer: self.normalizer)
    }
  }
  
  public override func backpropagate(inputs: [Float], previousLayerCount: Int) -> [Float] {
    let inputs = normalizer.backward(gradient: inputs)
    return super.backpropagate(inputs: inputs, previousLayerCount: previousLayerCount)
  }
}