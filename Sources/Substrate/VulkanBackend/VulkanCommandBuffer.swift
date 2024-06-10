//
//  VulkanCommandBuffer.swift
//  VkRenderer
//
//  Created by Thomas Roughton on 10/01/18.
//

#if canImport(Vulkan)
  import Dispatch
  import Foundation
  @_implementationOnly import SubstrateCExtras
  import SubstrateUtilities
  import Vulkan

  // Represents all resources that are associated with a particular command buffer
  // and should be freed once the command buffer has finished execution.
  final class VulkanCommandBuffer: BackendCommandBuffer {
    typealias Backend = VulkanBackend

    struct Error: Swift.Error {
      public var result: VkResult
    }

    static let semaphoreSignalQueue = DispatchQueue(label: "Vulkan Semaphore Signal Queue")

    let backend: VulkanBackend
    let queue: VulkanDeviceQueue
    let commandBuffer: VkCommandBuffer
    let commandInfo: FrameCommandInfo<VulkanRenderTargetDescriptor>
    let resourceMap: VulkanPersistentResourceRegistry
    let compactedResourceCommands: [CompactedResourceCommand<VulkanCompactedResourceCommandType>]

    var renderPasses = [VulkanRenderPass]()
    var framebuffers = [VulkanFramebuffer]()

    var waitSemaphores = [ResourceSemaphore]()
    var waitSemaphoreWaitValues = ExpandingBuffer<UInt64>()
    var signalSemaphores = [VkSemaphore?]()
    var signalSemaphoreSignalValues = ExpandingBuffer<UInt64>()

    var presentSwapchains = [VulkanSwapchain]()

    init(backend: VulkanBackend,
         queue: VulkanDeviceQueue,
         commandInfo: FrameCommandInfo<VulkanRenderTargetDescriptor>,
         resourceMap: VulkanPersistentResourceRegistry,
         compactedResourceCommands: [CompactedResourceCommand<VulkanCompactedResourceCommandType>])
    {
      self.backend = backend
      self.queue = queue
      commandBuffer = queue.allocateCommandBuffer()
      self.commandInfo = commandInfo
      self.resourceMap = resourceMap
      self.compactedResourceCommands = compactedResourceCommands

      var beginInfo = VkCommandBufferBeginInfo()
      beginInfo.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
      beginInfo.flags = VkCommandBufferUsageFlags(VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT)
      vkBeginCommandBuffer(commandBuffer, &beginInfo).check()
    }

    deinit {
      self.queue.depositCommandBuffer(self.commandBuffer)
    }

    var gpuStartTime: Double {
      return 0.0
    }

    var gpuEndTime: Double {
      return 0.0
    }

    func encodeCommands(encoderIndex: Int) async {
      let encoderInfo = commandInfo.commandEncoders[encoderIndex]

      switch encoderInfo.type {
      case .draw:
        let renderTargetsDescriptor = commandInfo.commandEncoderRenderTargets[encoderIndex]!
        guard let renderEncoder = VulkanRenderCommandEncoder(device: backend.device, renderTarget: renderTargetsDescriptor, commandBufferResources: self, shaderLibrary: backend.shaderLibrary, caches: backend.stateCaches, resourceMap: resourceMap) else {
          if _isDebugAssertConfiguration() {
            print("Warning: skipping passes for encoder \(encoderIndex) since the drawable for the render target could not be retrieved.")
          }
          return
        }

        for passRecord in commandInfo.passes[encoderInfo.passRange] {
          await renderEncoder.executePass(passRecord, resourceCommands: compactedResourceCommands, passRenderTarget: (passRecord.pass as! DrawRenderPass).renderTargetsDescriptor)
        }

      case .compute:
        let computeEncoder = VulkanComputeCommandEncoder(device: backend.device, commandBuffer: self, shaderLibrary: backend.shaderLibrary, caches: backend.stateCaches, resourceMap: resourceMap)

        for passRecord in commandInfo.passes[encoderInfo.passRange] {
          computeEncoder.executePass(passRecord, resourceCommands: compactedResourceCommands)
        }

      case .blit:
        let blitEncoder = VulkanBlitCommandEncoder(device: backend.device, commandBuffer: self, resourceMap: resourceMap)

        for passRecord in commandInfo.passes[encoderInfo.passRange] {
          blitEncoder.executePass(passRecord, resourceCommands: compactedResourceCommands)
        }

      case .external, .accelerationStructure, .cpu:
        break
      }
    }

    func waitForEvent(_ event: VkSemaphore, value: UInt64) {
      // TODO: wait for more fine-grained pipeline stages.
      waitSemaphores.append(ResourceSemaphore(vkSemaphore: event, stages: VK_PIPELINE_STAGE_ALL_COMMANDS_BIT))
      waitSemaphoreWaitValues.append(value)
    }

    func signalEvent(_ event: VkSemaphore, value: UInt64) {
      signalSemaphores.append(event)
      signalSemaphoreSignalValues.append(value)
    }

    func presentSwapchains(resourceRegistry: VulkanTransientResourceRegistry, onPresented: @Sendable ((Texture, OpaquePointer?) -> Void)?) {
      if onPresented != nil {
        assertionFailure("onPresented is not implemented for Vulkan.")
      }

      // Only contains drawables applicable to the render passes in the command buffer...
      presentSwapchains.append(contentsOf: resourceRegistry.frameSwapchains)
      // because we reset the list after each command buffer submission.
      resourceRegistry.clearSwapchains()
    }

    func commit(onCompletion: @escaping (VulkanCommandBuffer) -> Void) {
      vkEndCommandBuffer(commandBuffer).check()

      var submitInfo = VkSubmitInfo()
      submitInfo.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO

      submitInfo.commandBufferCount = 1

      let waitSemaphores = self.waitSemaphores.map { $0.vkSemaphore as VkSemaphore? } + presentSwapchains.map { $0.acquisitionSemaphore }
      waitSemaphoreWaitValues.append(repeating: 0, count: presentSwapchains.count)

      var waitDstStageMasks = self.waitSemaphores.map { VkPipelineStageFlags($0.stages) }
      waitDstStageMasks.append(contentsOf: repeatElement(VK_PIPELINE_STAGE_ALL_GRAPHICS_BIT.flags, count: presentSwapchains.count))

      // Add a binary semaphore to signal for each presentation swapchain.
      let signalTimelineSemaphoreCount = signalSemaphores.count
      signalSemaphores.append(contentsOf: presentSwapchains.map { $0.presentationSemaphore })
      signalSemaphoreSignalValues.append(repeating: 0, count: presentSwapchains.count)

      var timelineInfo = VkTimelineSemaphoreSubmitInfo()
      timelineInfo.sType = VK_STRUCTURE_TYPE_TIMELINE_SEMAPHORE_SUBMIT_INFO
      timelineInfo.pNext = nil
      timelineInfo.waitSemaphoreValueCount = UInt32(waitSemaphores.count)
      timelineInfo.pWaitSemaphoreValues = UnsafePointer(waitSemaphoreWaitValues.buffer)
      timelineInfo.signalSemaphoreValueCount = UInt32(signalSemaphores.count)
      timelineInfo.pSignalSemaphoreValues = UnsafePointer(signalSemaphoreSignalValues.buffer)

      withUnsafePointer(to: commandBuffer as VkCommandBuffer?) { commandBufferPtr in
        submitInfo.pCommandBuffers = commandBufferPtr
        submitInfo.signalSemaphoreCount = UInt32(self.signalSemaphores.count)

        waitSemaphores.withUnsafeBufferPointer { waitSemaphores in
          submitInfo.pWaitSemaphores = waitSemaphores.baseAddress
          submitInfo.waitSemaphoreCount = UInt32(waitSemaphores.count)
          waitDstStageMasks.withUnsafeBufferPointer { waitDstStageMasks in
            submitInfo.pWaitDstStageMask = waitDstStageMasks.baseAddress

            self.signalSemaphores.withUnsafeBufferPointer { signalSemaphores in
              submitInfo.pSignalSemaphores = signalSemaphores.baseAddress

              withUnsafePointer(to: timelineInfo) { timelineInfo in
                submitInfo.pNext = UnsafeRawPointer(timelineInfo)

                vkQueueSubmit(self.queue.vkQueue, 1, &submitInfo, nil).check()
              }
            }
          }
        }
      }

      if !presentSwapchains.isEmpty {
        for drawable in presentSwapchains {
          drawable.submit() // TODO: implement onPresented.
        }
      }

      Self.semaphoreSignalQueue.async {
        self.signalSemaphores.withUnsafeBufferPointer { signalSemaphores in
          var waitInfo = VkSemaphoreWaitInfo()
          waitInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_WAIT_INFO
          waitInfo.pSemaphores = signalSemaphores.baseAddress
          waitInfo.pValues = UnsafePointer(self.signalSemaphoreSignalValues.buffer)
          waitInfo.semaphoreCount = UInt32(signalTimelineSemaphoreCount)
          let timeout: UInt64 = 10_000_000_000 // 10s
          let result = vkWaitSemaphores(self.queue.device.vkDevice, &waitInfo, timeout)
          if result != VK_SUCCESS {
            self.error = Error(result: result)
          }
        }
        onCompletion(self)
      }
    }

    private(set) var error: Swift.Error?
  }

#endif // canImport(Vulkan)
