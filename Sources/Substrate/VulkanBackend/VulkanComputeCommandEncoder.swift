//
//  VulkanComputeCommandEncoder.swift
//  VkRenderer
//
//  Created by Thomas Roughton on 8/01/18.
//

#if canImport(Vulkan)
  @_implementationOnly import SubstrateCExtras
  import SubstrateUtilities
  import Vulkan

  struct VulkanComputePipelineDescriptor: Hashable {
    var descriptor: ComputePipelineDescriptor
    var layout: VkPipelineLayout
    var threadsPerThreadgroup: Size

    func withVulkanPipelineCreateInfo(pipelineReflection: VulkanPipelineReflection, stateCaches: VulkanStateCaches, _ withInfo: (inout VkComputePipelineCreateInfo) -> Void) {
      let specialisationInfo = stateCaches[descriptor.functionConstants, pipelineReflection: pipelineReflection] // TODO: also pass in threadsPerThreadgroup.
      let specialisationInfoPtr = specialisationInfo == nil ? nil : escapingPointer(to: &specialisationInfo!.info)

      let module = stateCaches.shaderLibrary.moduleForFunction(descriptor.function.name)!

      var stage = VkPipelineShaderStageCreateInfo()
      stage.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO
      stage.module = module.vkModule
      stage.stage = VK_SHADER_STAGE_COMPUTE_BIT
      stage.pSpecializationInfo = specialisationInfoPtr

      let entryPoint = module.entryPointForFunction(named: descriptor.function.name)
      entryPoint.withCString { cFuncName in
        stage.pName = cFuncName

        var pipelineInfo = VkComputePipelineCreateInfo()
        pipelineInfo.sType = VK_STRUCTURE_TYPE_COMPUTE_PIPELINE_CREATE_INFO

        pipelineInfo.stage = stage
        pipelineInfo.layout = self.layout

        withInfo(&pipelineInfo)
      }

      _fixLifetime(specialisationInfo)
    }
  }

  class VulkanComputeCommandEncoder: VulkanResourceBindingCommandEncoder {
    class PipelineState {
      let shaderLibrary: VulkanShaderLibrary

      init(shaderLibrary: VulkanShaderLibrary) {
        self.shaderLibrary = shaderLibrary
      }

      var hasChanged = true

      var descriptor: ComputePipelineDescriptor! = nil {
        didSet {
          let key = PipelineLayoutKey.compute(descriptor.function.name)
          pipelineReflection = shaderLibrary.reflection(for: key)
          _layout = nil

          hasChanged = true
        }
      }

      private var _layout: VkPipelineLayout! = nil

      var layout: VkPipelineLayout {
        if let layout = _layout {
          return layout
        }
        _layout = shaderLibrary.pipelineLayout(for: .compute(descriptor.function.name))
        return _layout
      }

      var pipelineReflection: VulkanPipelineReflection! = nil

      var threadsPerThreadgroup: Size = .init(width: 0, height: 0, depth: 0) {
        didSet {
          if oldValue != threadsPerThreadgroup {
            hasChanged = true
          }
        }
      }

      var vulkanPipelineDescriptor: VulkanComputePipelineDescriptor {
        return VulkanComputePipelineDescriptor(descriptor: descriptor,
                                               layout: layout,
                                               threadsPerThreadgroup: threadsPerThreadgroup)
      }
    }

    let device: VulkanDevice
    let commandBufferResources: VulkanCommandBuffer
    let resourceMap: VulkanPersistentResourceRegistry
    let stateCaches: VulkanStateCaches

    var pipelineState: PipelineState! = nil

    public init(device: VulkanDevice, commandBuffer: VulkanCommandBuffer, shaderLibrary: VulkanShaderLibrary, caches: VulkanStateCaches, resourceMap: VulkanPersistentResourceRegistry) {
      self.device = device
      commandBufferResources = commandBuffer
      stateCaches = caches
      self.resourceMap = resourceMap

      pipelineState = PipelineState(shaderLibrary: shaderLibrary)
    }

    var queueFamily: QueueFamily {
      return .compute
    }

    var bindPoint: VkPipelineBindPoint {
      return VK_PIPELINE_BIND_POINT_COMPUTE
    }

    var commandBuffer: VkCommandBuffer {
      return commandBufferResources.commandBuffer
    }

    var pipelineLayout: VkPipelineLayout {
      return pipelineState.layout
    }

    var pipelineReflection: VulkanPipelineReflection {
      return pipelineState.pipelineReflection
    }

    func prepareToDispatch() {
      if pipelineState.hasChanged {
        defer {
          self.pipelineState.hasChanged = false
        }

        let pipeline = stateCaches[pipelineState.vulkanPipelineDescriptor, pipelineReflection: pipelineState.pipelineReflection]

        vkCmdBindPipeline(commandBuffer, VK_PIPELINE_BIND_POINT_COMPUTE, pipeline)
      }
    }

    func executePass(_ pass: RenderPassRecord, resourceCommands: [CompactedResourceCommand<VulkanCompactedResourceCommandType>]) {
      var resourceCommandIndex = resourceCommands.binarySearch { $0.index < pass.commandRange!.lowerBound }

      for (i, command) in zip(pass.commandRange!, pass.commands) {
        checkResourceCommands(resourceCommands, resourceCommandIndex: &resourceCommandIndex, phase: .before, commandIndex: i)
        executeCommand(command)
        checkResourceCommands(resourceCommands, resourceCommandIndex: &resourceCommandIndex, phase: .after, commandIndex: i)
      }
    }

    func executeCommand(_ command: RenderGraphCommand) {
      switch command {
      case .insertDebugSignpost:
        break

      case .setLabel:
        break

      case .pushDebugGroup:
        break

      case .popDebugGroup:
        break

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

      case let .dispatchThreads(args):
        let threadsPerThreadgroup = args.pointee.threadsPerThreadgroup
        pipelineState.threadsPerThreadgroup = threadsPerThreadgroup
        prepareToDispatch()

        let threads = args.pointee.threads

        // Calculate how many threadgroups are required for this number of threads
        let threadgroupsPerGridX = (args.pointee.threads.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width
        let threadgroupsPerGridY = (args.pointee.threads.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height
        let threadgroupsPerGridZ = (args.pointee.threads.depth + threadsPerThreadgroup.depth - 1) / threadsPerThreadgroup.depth

        vkCmdDispatch(commandBuffer, UInt32(threadgroupsPerGridX), UInt32(threadgroupsPerGridY), UInt32(threadgroupsPerGridZ))

      case let .dispatchThreadgroups(args):
        pipelineState.threadsPerThreadgroup = args.pointee.threadsPerThreadgroup
        prepareToDispatch()

        vkCmdDispatch(commandBuffer, UInt32(args.pointee.threadgroupsPerGrid.width), UInt32(args.pointee.threadgroupsPerGrid.height), UInt32(args.pointee.threadgroupsPerGrid.depth))

      case let .dispatchThreadgroupsIndirect(args):
        pipelineState.threadsPerThreadgroup = args.pointee.threadsPerThreadgroup
        prepareToDispatch()

        let buffer = resourceMap[args.pointee.indirectBuffer]!
        vkCmdDispatchIndirect(commandBuffer, buffer.buffer.vkBuffer, VkDeviceSize(args.pointee.indirectBufferOffset) + VkDeviceSize(buffer.offset))

      case let .setComputePipelineDescriptor(descriptorPtr):
        pipelineState.descriptor = descriptorPtr.takeUnretainedValue().pipelineDescriptor

      case .setStageInRegion:
        fatalError("Unimplemented.")

      case .setThreadgroupMemoryLength:
        fatalError("Unimplemented.")

      default:
        fatalError()
      }
    }
  }

#endif // canImport(Vulkan)
