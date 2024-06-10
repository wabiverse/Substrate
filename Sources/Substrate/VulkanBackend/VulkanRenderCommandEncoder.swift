//
//  VulkanRenderCommandEncoder.swift
//  VkRenderer
//
//  Created by Thomas Roughton on 8/01/18.
//

#if canImport(Vulkan)
  @_implementationOnly import SubstrateCExtras
  import SubstrateUtilities
  import Vulkan

  struct DynamicStateCreateInfo {
    let buffer: FixedSizeBuffer<VkDynamicState>
    var info: VkPipelineDynamicStateCreateInfo

    init(states: FixedSizeBuffer<VkDynamicState>) {
      buffer = states
      info = VkPipelineDynamicStateCreateInfo()
      info.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO
      info.dynamicStateCount = UInt32(states.count)
      info.pDynamicStates = UnsafePointer(states.buffer)
    }

    //
    static let `default` = DynamicStateCreateInfo(states: [VK_DYNAMIC_STATE_VIEWPORT,
                                                           VK_DYNAMIC_STATE_SCISSOR,
                                                           VK_DYNAMIC_STATE_DEPTH_BIAS,
                                                           VK_DYNAMIC_STATE_BLEND_CONSTANTS,
                                                           VK_DYNAMIC_STATE_STENCIL_REFERENCE,

                                                           VK_DYNAMIC_STATE_CULL_MODE_EXT,
                                                           VK_DYNAMIC_STATE_FRONT_FACE_EXT,
                                                           VK_DYNAMIC_STATE_PRIMITIVE_TOPOLOGY_EXT,
                                                           VK_DYNAMIC_STATE_PRIMITIVE_RESTART_ENABLE_EXT,
//                                                           VK_DYNAMIC_STATE_DEPTH_TEST_ENABLE_EXT,
//                                                           VK_DYNAMIC_STATE_DEPTH_WRITE_ENABLE_EXT,
//                                                           VK_DYNAMIC_STATE_DEPTH_COMPARE_OP_EXT,
//                                                           VK_DYNAMIC_STATE_STENCIL_TEST_ENABLE_EXT,
//                                                           VK_DYNAMIC_STATE_STENCIL_OP_EXT,
      ])
  }

  struct VulkanRenderPipelineDescriptor: Hashable {
    let shaderLibrary: VulkanShaderLibrary
    let compatibleRenderPass: VulkanCompatibleRenderPass

    var hasChanged: Bool = false
    var pipelineReflection: VulkanPipelineReflection! = nil

    var descriptor: RenderPipelineDescriptor! = nil {
      didSet {
        let key = PipelineLayoutKey.graphics(vertexShader: descriptor.vertexFunction.name, fragmentShader: descriptor.fragmentFunction.name)
        pipelineReflection = shaderLibrary.reflection(for: key)
        layout = shaderLibrary.pipelineLayout(for: .graphics(vertexShader: descriptor.vertexFunction.name, fragmentShader: descriptor.fragmentFunction.name))
        hasChanged = true
      }
    }

    var primitiveType: PrimitiveType? = nil // Triangles, lines, or points; the exact subtype is set dynamically.
    var depthStencil: DepthStencilDescriptor? = nil { didSet { hasChanged = hasChanged || depthStencil != oldValue } }
    var layout: VkPipelineLayout! = nil { didSet { hasChanged = hasChanged || layout != oldValue } }

    var subpassIndex: Int = 0 { didSet { hasChanged = hasChanged || subpassIndex != oldValue } }

    init(shaderLibrary: VulkanShaderLibrary, compatibleRenderPass: VulkanCompatibleRenderPass) {
      self.shaderLibrary = shaderLibrary
      self.compatibleRenderPass = compatibleRenderPass
    }

    func hash(into hasher: inout Hasher) {
      hasher.combine(descriptor)
      hasher.combine(depthStencil)
      hasher.combine(layout)

      hasher.combine(subpassIndex)
      hasher.combine(compatibleRenderPass)
    }

    static func == (lhs: VulkanRenderPipelineDescriptor, rhs: VulkanRenderPipelineDescriptor) -> Bool {
      guard lhs.descriptor == rhs.descriptor else { return false }
      guard lhs.primitiveType == rhs.primitiveType else { return false }
      guard lhs.layout == rhs.layout else { return false }
      guard lhs.subpassIndex == rhs.subpassIndex else { return false }

      guard lhs.compatibleRenderPass == rhs.compatibleRenderPass else {
        return false
      }

      return true
    }

    func withVulkanPipelineCreateInfo(renderPass: VulkanRenderPass, stateCaches: VulkanStateCaches, _ withInfo: (inout VkGraphicsPipelineCreateInfo) -> Void) {
      var functionNames = [FixedSizeBuffer<CChar>]()

      var stages = [VkPipelineShaderStageCreateInfo]()

      for (function, stageFlag) in [(descriptor.vertexFunction, VK_SHADER_STAGE_VERTEX_BIT), (descriptor.fragmentFunction, VK_SHADER_STAGE_FRAGMENT_BIT)] {
        let name = function.name
        guard !name.isEmpty else { continue }
        let module = stateCaches.shaderLibrary.moduleForFunction(name)!

        let specialisationInfo = stateCaches[function.constants, pipelineReflection: pipelineReflection]
        let specialisationInfoPtr = specialisationInfo == nil ? nil : escapingPointer(to: &specialisationInfo!.info)

        let entryPoint = module.entryPointForFunction(named: name)
        let cEntryPoint = entryPoint.withCString { cString -> FixedSizeBuffer<CChar> in
          let buffer = FixedSizeBuffer(capacity: name.utf8.count + 1, defaultValue: 0 as CChar)
          buffer.buffer.assign(from: cString, count: name.utf8.count)
          return buffer
        }

        functionNames.append(cEntryPoint)

        var stage = VkPipelineShaderStageCreateInfo()
        stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
        stage.pName = UnsafePointer(cEntryPoint.buffer)
        stage.stage = stageFlag
        stage.pSpecializationInfo = specialisationInfoPtr
        stage.module = module.vkModule
        stages.append(stage)
      }

      let vertexInputState = stateCaches[descriptor.vertexDescriptor]

      var inputAssemblyState = VkPipelineInputAssemblyStateCreateInfo()
      inputAssemblyState.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO
      inputAssemblyState.topology = VkPrimitiveTopology(primitiveType)

      var rasterisationState = VkPipelineRasterizationStateCreateInfo()
      rasterisationState.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO
      rasterisationState.depthClampEnable = VkBool32(depthStencil?.depthClipMode == .clamp)
      rasterisationState.rasterizerDiscardEnable = VkBool32(!descriptor.isRasterizationEnabled)
      rasterisationState.polygonMode = VkPolygonMode(descriptor.fillMode)
      rasterisationState.depthBiasEnable = true
      rasterisationState.depthBiasConstantFactor = 0
      rasterisationState.depthBiasClamp = 0.0
      rasterisationState.depthBiasSlopeFactor = 0
      rasterisationState.lineWidth = 1.0

      let sampleCount = compatibleRenderPass.attachments[0].sampleCount
      let multisampleState = VkPipelineMultisampleStateCreateInfo(descriptor, sampleCount: sampleCount)

      let depthStencilState: VkPipelineDepthStencilStateCreateInfo
      if let depthStencil = depthStencil {
        depthStencilState = VkPipelineDepthStencilStateCreateInfo(descriptor: depthStencil, referenceValue: 0)
      } else {
        var dsState = VkPipelineDepthStencilStateCreateInfo()
        dsState.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO
        dsState.depthTestEnable = false
        dsState.depthWriteEnable = false
        depthStencilState = dsState
      }

      let colorBlendState = ColorBlendStateCreateInfo(descriptor: descriptor, colorAttachmentIndices: compatibleRenderPass.subpasses[subpassIndex].colorAttachmentIndices)

      let dynamicState = DynamicStateCreateInfo.default

      var viewportState = VkPipelineViewportStateCreateInfo() // overridden by dynamic state.
      viewportState.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO
      viewportState.viewportCount = 1
      viewportState.scissorCount = 1

      var tesselationState = VkPipelineTessellationStateCreateInfo()
      tesselationState.sType = VK_STRUCTURE_TYPE_PIPELINE_TESSELLATION_STATE_CREATE_INFO

      var states = (vertexInputState, inputAssemblyState, rasterisationState, multisampleState, depthStencilState, colorBlendState, dynamicState, tesselationState, viewportState)
      withExtendedLifetime(states) {
        stages.withUnsafeBufferPointer { stages in
          var pipelineInfo = VkGraphicsPipelineCreateInfo()
          pipelineInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO

          pipelineInfo.stageCount = UInt32(stages.count)
          pipelineInfo.pStages = stages.baseAddress

          pipelineInfo.layout = self.layout

          pipelineInfo.pVertexInputState = escapingPointer(to: &states.0.info)
          pipelineInfo.pInputAssemblyState = escapingPointer(to: &states.1)
          pipelineInfo.pRasterizationState = escapingPointer(to: &states.2)
          pipelineInfo.pMultisampleState = escapingPointer(to: &states.3)
          pipelineInfo.pDepthStencilState = escapingPointer(to: &states.4)
          pipelineInfo.pColorBlendState = escapingPointer(to: &states.5.info)
          pipelineInfo.pDynamicState = escapingPointer(to: &states.6.info)
          pipelineInfo.pTessellationState = escapingPointer(to: &states.7)
          pipelineInfo.pViewportState = escapingPointer(to: &states.8)

          pipelineInfo.renderPass = renderPass.vkPass
          pipelineInfo.subpass = UInt32(self.subpassIndex)

          withInfo(&pipelineInfo)
        }
      }
    }
  }

  class VulkanRenderCommandEncoder: VulkanResourceBindingCommandEncoder {
    let device: VulkanDevice
    let stateCaches: VulkanStateCaches
    let commandBufferResources: VulkanCommandBuffer
    let renderTarget: VulkanRenderTargetDescriptor
    let resourceMap: VulkanPersistentResourceRegistry

    var renderPass: VulkanRenderPass! = nil
    var currentDrawRenderPass: DrawRenderPass! = nil
    var pipelineDescriptor: VulkanRenderPipelineDescriptor

    var boundVertexBuffers = [Buffer?](repeating: nil, count: 8)
    var enqueuedBindings = [RenderGraphCommand]()

    var subpass: VulkanSubpass? = nil

    var currentPrimitiveType: PrimitiveType? = nil
    var currentWinding: Winding? = nil

    public init?(device: VulkanDevice, renderTarget: VulkanRenderTargetDescriptor, commandBufferResources: VulkanCommandBuffer, shaderLibrary: VulkanShaderLibrary, caches: VulkanStateCaches, resourceMap: VulkanPersistentResourceRegistry) {
      self.device = device
      self.renderTarget = renderTarget
      self.commandBufferResources = commandBufferResources
      stateCaches = caches
      self.resourceMap = resourceMap

      pipelineDescriptor = VulkanRenderPipelineDescriptor(shaderLibrary: shaderLibrary, compatibleRenderPass: renderTarget.compatibleRenderPass!)
    }

    var queueFamily: QueueFamily {
      return .graphics
    }

    var bindPoint: VkPipelineBindPoint {
      return VK_PIPELINE_BIND_POINT_GRAPHICS
    }

    var commandBuffer: VkCommandBuffer {
      return commandBufferResources.commandBuffer
    }

    var pipelineLayout: VkPipelineLayout {
      return pipelineDescriptor.layout
    }

    var pipelineReflection: VulkanPipelineReflection {
      return pipelineDescriptor.pipelineReflection
    }

    func prepareToDraw() {
      assert(pipelineDescriptor.descriptor != nil, "No render pipeline descriptor is set.")

      if pipelineDescriptor.hasChanged {
        defer {
          self.pipelineDescriptor.hasChanged = false
        }

        // Bind the pipeline before binding any resources.

        let pipeline = stateCaches[pipelineDescriptor,
                                   renderPass: renderPass!]
        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline)
      }

      for binding in enqueuedBindings {
        switch binding {
        case let .setArgumentBuffer(args):
          let bindingPath = args.pointee.bindingPath

          let argumentBuffer = args.pointee.argumentBuffer
          let vkArgumentBuffer = resourceMap[argumentBuffer]

          var set: VkDescriptorSet? = vkArgumentBuffer.descriptorSet
          vkCmdBindDescriptorSets(commandBuffer, bindPoint, pipelineLayout, bindingPath.set, 1, &set, 0, nil)

        case let .setBytes(args):
          let bindingPath = args.pointee.bindingPath
          let bytes = args.pointee.bytes
          let length = args.pointee.length

          let resourceInfo = pipelineReflection[bindingPath]

          switch resourceInfo.type {
          case .pushConstantBuffer:
            assert(resourceInfo.bindingRange.count == length, "The push constant size and the setBytes length must match.")
            vkCmdPushConstants(commandBuffer, pipelineLayout, VkShaderStageFlags(resourceInfo.accessedStages), resourceInfo.bindingRange.lowerBound, length, bytes)

          default:
            fatalError("Need to implement VK_EXT_inline_uniform_block or else fall back to a temporary staging buffer")
          }

        case let .setBufferOffset(args):
          fatalError("Currently unimplemented on Vulkan; should use vkCmdPushDescriptorSetKHR when implemented.")

        case let .setBuffer(args):
          fatalError("Currently unimplemented on Vulkan; should use vkCmdPushDescriptorSetKHR when implemented.")

        case let .setTexture(args):
          fatalError("Currently unimplemented on Vulkan; should use vkCmdPushDescriptorSetKHR when implemented.")

        case let .setSamplerState(args):
          fatalError("Currently unimplemented on Vulkan; should use vkCmdPushDescriptorSetKHR when implemented.")

        default:
          preconditionFailure()
        }
      }
      enqueuedBindings.removeAll(keepingCapacity: true)
    }

    private func beginPass(_ pass: RenderPassRecord) async throws {
      let drawPass = pass.pass as! DrawRenderPass
      currentDrawRenderPass = drawPass
      subpass = renderTarget.subpassForPassIndex(pass.passIndex)

      pipelineDescriptor.subpassIndex = subpass!.index

      let renderTargetSize = renderTarget.descriptor.size
      let renderTargetRect = VkRect2D(offset: VkOffset2D(x: 0, y: 0), extent: VkExtent2D(width: UInt32(renderTargetSize.width), height: UInt32(renderTargetSize.height)))

      if pass == renderTarget.renderPasses.first { // Set up the render target.
        renderPass = try await VulkanRenderPass(device: device, descriptor: renderTarget, resourceMap: resourceMap)
        commandBufferResources.renderPasses.append(renderPass)
        let framebuffer = try await VulkanFramebuffer(descriptor: renderTarget, renderPass: renderPass, device: device, resourceMap: resourceMap)
        commandBufferResources.framebuffers.append(framebuffer)

        var clearValues = [VkClearValue]()
        if renderTarget.descriptor.depthAttachment != nil || renderTarget.descriptor.stencilAttachment != nil {
          clearValues.append(VkClearValue(depthStencil: VkClearDepthStencilValue(depth: Float(renderTarget.clearDepth), stencil: renderTarget.clearStencil)))
        }

        for clearColor in renderTarget.clearColors {
          clearValues.append(VkClearValue(color: clearColor))
        }

        clearValues.withUnsafeBufferPointer { clearValues in
          var beginInfo = VkRenderPassBeginInfo()
          beginInfo.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO
          beginInfo.renderPass = renderPass.vkPass
          beginInfo.renderArea = renderTargetRect
          beginInfo.framebuffer = framebuffer.framebuffer
          beginInfo.clearValueCount = UInt32(clearValues.count)
          beginInfo.pClearValues = clearValues.baseAddress

          vkCmdBeginRenderPass(self.commandBuffer, &beginInfo, VK_SUBPASS_CONTENTS_INLINE)
        }
      }

      // TODO: We can infer which properties need to be dynamic and avoid this step.
      // For now, assume that all properties that are dynamic in Metal should also be
      // dynamic in Vulkan, and set sensible defaults.

      // See: https://www.khronos.org/registry/vulkan/specs/1.0/man/html/VkDynamicState.html
      // There's also a new extended dynamic state extension in 1.2 which might be worth
      // looking at.

      var viewport = VkViewport(x: 0, y: Float(renderTargetRect.extent.height), width: Float(renderTargetRect.extent.width), height: -Float(renderTargetRect.extent.height), minDepth: 0, maxDepth: 1)
      vkCmdSetViewport(commandBuffer, 0, 1, &viewport)

      var scissor = renderTargetRect
      vkCmdSetScissor(commandBuffer, 0, 1, &scissor)

      vkCmdSetStencilReference(commandBuffer, VkStencilFaceFlags(VK_STENCIL_FRONT_AND_BACK), 0)

      vkCmdSetDepthBias(commandBuffer, 0.0, 0.0, 0.0)
    }

    /// Ends a pass and returns whether the command encoder is still valid.
    private func endPass(_ pass: RenderPassRecord) -> Bool {
      if pass == renderTarget.renderPasses.last {
        vkCmdEndRenderPass(commandBuffer)
        return false
      } else {
        let nextSubpass = renderTarget.subpassForPassIndex(pass.passIndex + 1)
        if nextSubpass !== subpass {
          vkCmdNextSubpass(commandBuffer, VK_SUBPASS_CONTENTS_INLINE)
        }
      }
      return true
    }

    func executePass(_ pass: RenderPassRecord, resourceCommands: [CompactedResourceCommand<VulkanCompactedResourceCommandType>], passRenderTarget _: RenderTargetDescriptor) async {
      var resourceCommandIndex = resourceCommands.binarySearch { $0.index < pass.commandRange!.lowerBound }

      let firstCommandIndex = pass.commandRange!.first!
      let lastCommandIndex = pass.commandRange!.last!

      // Check for any commands that need to be executed before the render pass.
      checkResourceCommands(resourceCommands, resourceCommandIndex: &resourceCommandIndex, phase: .before, commandIndex: firstCommandIndex)

      try! await beginPass(pass)

      // FIXME: need to insert this logic:
//        if passRenderTarget.depthAttachment == nil && passRenderTarget.stencilAttachment == nil, (self.renderPassDescriptor.depthAttachment.texture != nil || self.renderPassDescriptor.stencilAttachment.texture != nil) {
//            encoder.setDepthStencilState(stateCaches.defaultDepthState) // The render pass unexpectedly has a depth/stencil attachment, so make sure the depth stencil state is set to the default.
//        }

      for (i, command) in zip(pass.commandRange!, pass.commands) {
        if i > firstCommandIndex {
          checkResourceCommands(resourceCommands, resourceCommandIndex: &resourceCommandIndex, phase: .before, commandIndex: i)
        }

        executeCommand(command)

        if i < lastCommandIndex {
          checkResourceCommands(resourceCommands, resourceCommandIndex: &resourceCommandIndex, phase: .after, commandIndex: i)
        }
      }

      _ = endPass(pass)

      // Check for any commands that need to be executed after the render pass.
      checkResourceCommands(resourceCommands, resourceCommandIndex: &resourceCommandIndex, phase: .after, commandIndex: lastCommandIndex)
    }

    func setPrimitiveType(_ primitiveType: PrimitiveType) {
      guard primitiveType != currentPrimitiveType else {
        return
      }

      let oldDescriptorType = pipelineDescriptor.primitiveType
      switch primitiveType {
      case .triangle, .triangleStrip:
        pipelineDescriptor.primitiveType = .triangle
      case .line, .lineStrip:
        pipelineDescriptor.primitiveType = .line
      case .point:
        pipelineDescriptor.primitiveType = .point
      }
      if pipelineDescriptor.primitiveType != oldDescriptorType {
        prepareToDraw()
      }

      vkCmdSetPrimitiveTopologyEXT(commandBuffer, VkPrimitiveTopology(primitiveType))

      let primitiveRestartEnabled: Bool
      switch primitiveType {
      case .triangle, .line, .point:
        primitiveRestartEnabled = false
      default:
        primitiveRestartEnabled = true
        // Disable primitive restart for list topologies
      }
      vkCmdSetPrimitiveRestartEnableEXT(commandBuffer, primitiveRestartEnabled ? 1 : 0)

      currentPrimitiveType = primitiveType
    }

    func executeCommand(_ command: RenderCommandEncoder)
    {
      // switch command {
      // case let .setVertexBuffer(buff, offset, index):
      //   boundVertexBuffers[Int(args.pointee.index)] = args.pointee.buffer
      //   guard let handle = args.pointee.buffer else { return }
      //   if let buffer = resourceMap[handle] {
      //     var vkBuffer = buffer.buffer.vkBuffer as VkBuffer?
      //     var offset = VkDeviceSize(args.pointee.offset) + VkDeviceSize(buffer.offset)
      //     vkCmdBindVertexBuffers(commandBuffer, args.pointee.index, 1, &vkBuffer, &offset)
      //   }

      // case let .setVertexBufferOffset(offset, index):
      //   let handle = boundVertexBuffers[Int(index)]!
      //   if let buffer = resourceMap[handle] {
      //     var vkBuffer = buffer.buffer.vkBuffer as VkBuffer?
      //     var offset = VkDeviceSize(offset) + VkDeviceSize(buffer.offset)
      //     vkCmdBindVertexBuffers(commandBuffer, index, 1, &vkBuffer, &offset)
      //   }

      // case .setArgumentBuffer, .setBytes,
      //      .setBufferOffset, .setBuffer, .setTexture, .setSamplerState:
      //   enqueuedBindings.append(command)

      // case let .setRenderPipelineDescriptor(descriptorPtr):
      //   let descriptor = descriptorPtr.takeUnretainedValue().value
      //   pipelineDescriptor.descriptor = descriptor

      // case let .drawPrimitives(args):
      //   setPrimitiveType(args.pointee.primitiveType)
      //   prepareToDraw()

      //   vkCmdDraw(commandBuffer, args.pointee.vertexCount, args.pointee.instanceCount, args.pointee.vertexStart, args.pointee.baseInstance)

      // case let .drawIndexedPrimitives(args):
      //   setPrimitiveType(args.pointee.primitiveType)

      //   let buffer = resourceMap[args.pointee.indexBuffer]!
      //   vkCmdBindIndexBuffer(commandBuffer, buffer.buffer.vkBuffer, VkDeviceSize(args.pointee.indexBufferOffset) + VkDeviceSize(buffer.offset), VkIndexType(args.pointee.indexType))

      //   prepareToDraw()

      //   vkCmdDrawIndexed(commandBuffer, args.pointee.indexCount, args.pointee.instanceCount, 0, args.pointee.baseVertex, args.pointee.baseInstance)

      // case let .setViewport(viewportPtr):
      //   var viewport = VkViewport(viewportPtr.pointee)
      //   vkCmdSetViewport(commandBuffer, 0, 1, &viewport)

      // case let .setFrontFacing(winding):
      //   vkCmdSetFrontFaceEXT(commandBuffer, VkFrontFace(winding))

      // case let .setCullMode(cullMode):
      //   vkCmdSetCullModeEXT(commandBuffer, VkCullModeFlags(cullMode))

      // case let .setDepthStencilDescriptor(descriptorPtr):
      //   pipelineDescriptor.depthStencil = descriptorPtr.takeUnretainedValue().value

      // case let .setScissorRect(scissorPtr):
      //   var scissor = VkRect2D(scissorPtr.pointee)
      //   vkCmdSetScissor(commandBuffer, 0, 1, &scissor)

      // case let .setDepthBias(args):
      //   vkCmdSetDepthBias(commandBuffer, args.pointee.depthBias, args.pointee.clamp, args.pointee.slopeScale)

      // case let .setStencilReferenceValue(value):
      //   vkCmdSetStencilReference(commandBuffer, VkStencilFaceFlags(VK_STENCIL_FRONT_AND_BACK), value)

      // case let .setStencilReferenceValues(front, back):
      //   vkCmdSetStencilReference(commandBuffer, VkStencilFaceFlags(VK_STENCIL_FACE_FRONT_BIT), front)
      //   vkCmdSetStencilReference(commandBuffer, VkStencilFaceFlags(VK_STENCIL_FACE_BACK_BIT), back)

      // default:
        fatalError("Unhandled command \(command)")
    }
  }

#endif // canImport(Vulkan)
