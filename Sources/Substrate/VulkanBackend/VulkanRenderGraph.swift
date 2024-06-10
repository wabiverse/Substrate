//
//  VulkanRenderGraph.swift
//  VkRenderer
//
//  Created by Joseph Bennett on 2/01/18.
//

#if canImport(Vulkan)
  import Dispatch
  @_implementationOnly import SubstrateCExtras
  import SubstrateUtilities
  import Vulkan

  extension VkImageSubresourceRange {
    func overlaps(with otherRange: VkImageSubresourceRange) -> Bool {
      let layersOverlap = (baseArrayLayer ..< (baseArrayLayer + layerCount)).overlaps(otherRange.baseArrayLayer ..< otherRange.baseArrayLayer + otherRange.layerCount)
      let levelsOverlap = (baseMipLevel ..< (baseMipLevel + levelCount)).overlaps(otherRange.baseMipLevel ..< (otherRange.baseMipLevel + otherRange.levelCount))
      return layersOverlap && levelsOverlap
    }
  }

  extension Array where Element == VkImageMemoryBarrier {
    mutating func appendBarrier(_ barrier: VkImageMemoryBarrier) {
      assert(!contains(where: { $0.image == barrier.image && $0.subresourceRange.overlaps(with: barrier.subresourceRange) }), "Trying to add barrier \(barrier) but \(first(where: { $0.image == barrier.image && $0.subresourceRange.overlaps(with: barrier.subresourceRange) })!) already exists")
      append(barrier)
    }

    mutating func appendBarriers(_ barriers: [VkImageMemoryBarrier]) {
      for barrier in barriers {
        assert(!contains(where: { $0.image == barrier.image && $0.subresourceRange.overlaps(with: barrier.subresourceRange) }), "Trying to add barrier \(barrier) but \(first(where: { $0.image == barrier.image && $0.subresourceRange.overlaps(with: barrier.subresourceRange) })!) already exists")
      }
      append(contentsOf: barriers)
    }
  }

  extension VulkanBackend {
    func processImageSubresourceRanges(_ activeMask: inout SubresourceMask, textureDescriptor: TextureDescriptor, allocator: AllocatorType, action: (VkImageSubresourceRange) -> Void) {
      var subresourceRange = VkImageSubresourceRange(aspectMask: textureDescriptor.pixelFormat.aspectFlags, baseMipLevel: 0, levelCount: UInt32(textureDescriptor.mipmapLevelCount), baseArrayLayer: 0, layerCount: UInt32(textureDescriptor.arrayLength))
      for level in 0 ..< textureDescriptor.mipmapLevelCount {
        for slice in 0 ..< textureDescriptor.slicesPerLevel {
          if activeMask[slice: slice, level: level, descriptor: textureDescriptor] {
            subresourceRange.baseArrayLayer = UInt32(slice)
            subresourceRange.baseMipLevel = UInt32(level)

            let endSlice = (0 ..< textureDescriptor.slicesPerLevel).dropFirst(slice + 1).first(where: { !activeMask[slice: $0, level: level, descriptor: textureDescriptor] }) ?? textureDescriptor.slicesPerLevel
            subresourceRange.layerCount = UInt32(endSlice - slice)

            let endLevel = (0 ..< textureDescriptor.mipmapLevelCount).dropFirst(level + 1).first(where: { testLevel in
              !(slice ..< endSlice).allSatisfy { activeMask[slice: $0, level: testLevel, descriptor: textureDescriptor] }
            }) ?? textureDescriptor.mipmapLevelCount

            subresourceRange.levelCount = UInt32(endLevel - level)
            assert(endLevel - level <= textureDescriptor.mipmapLevelCount)

            for l in level ..< endLevel {
              for s in slice ..< endSlice {
                activeMask[slice: s, level: l, descriptor: textureDescriptor, allocator: allocator] = false
              }
            }
            action(subresourceRange)
          }
        }
      }
    }

    func generateEventCommands(queue: Queue, resourceMap: VulkanPersistentResourceRegistry, frameCommandInfo: FrameCommandInfo<VulkanRenderTargetDescriptor>, commandGenerator: ResourceCommandGenerator<VulkanBackend>, compactedResourceCommands: inout [CompactedResourceCommand<VulkanCompactedResourceCommandType>]) {
      // MARK: - Generate the events

      let dependencies: DependencyTable<FineDependency?> = commandGenerator.commandEncoderDependencies

      let commandEncoderCount = frameCommandInfo.commandEncoders.count
      let reductionMatrix = dependencies.transitiveReduction(hasDependency: { $0 != nil })

      let allocator = ThreadLocalTagAllocator(tag: .renderGraphResourceCommandArrayTag)

      for sourceIndex in 0 ..< commandEncoderCount { // sourceIndex always points to the producing pass.
        let dependentRange = min(sourceIndex + 1, commandEncoderCount) ..< commandEncoderCount

        var signalStages: VkPipelineStageFlagBits = []
        var signalIndex = -1
        for dependentIndex in dependentRange where reductionMatrix.dependency(from: dependentIndex, on: sourceIndex) {
          let dependency = dependencies.dependency(from: dependentIndex, on: sourceIndex)!

          for (resource, producingUsage, _) in dependency.resources {
            let pixelFormat = Texture(resource)?.descriptor.pixelFormat ?? .invalid
            let isDepthOrStencil = pixelFormat.isDepth || pixelFormat.isStencil
            signalStages.formUnion(producingUsage.type.shaderStageMask(isDepthOrStencil: isDepthOrStencil, stages: producingUsage.stages))
          }

          signalIndex = max(signalIndex, dependency.signal.index)
        }

        if signalIndex < 0 { continue }

        for dependentIndex in dependentRange where reductionMatrix.dependency(from: dependentIndex, on: sourceIndex) {
          let dependency = dependencies.dependency(from: dependentIndex, on: sourceIndex)!
          var destinationStages: VkPipelineStageFlagBits = []

          var bufferBarriers = [VkBufferMemoryBarrier]()
          var imageBarriers = [VkImageMemoryBarrier]()

//                assert(self.device.queueFamilyIndex(queue: queue, encoderType: sourceEncoderType) == self.device.queueFamilyIndex(queue: queue, encoderType: destinationEncoderType), "Queue ownership transfers must be handled with a pipeline barrier rather than an event")

          for (resource, producingUsage, consumingUsage) in dependency.resources {
            var isDepthOrStencil = false

            if let buffer = Buffer(resource) {
              var barrier = VkBufferMemoryBarrier()
              barrier.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
              barrier.buffer = resourceMap[buffer]!.buffer.vkBuffer
              barrier.offset = 0
              barrier.size = VK_WHOLE_SIZE
              if case let .buffer(rangeA) = producingUsage.activeRange, case let .buffer(rangeB) = consumingUsage.activeRange {
                let range = min(rangeA.lowerBound, rangeB.lowerBound) ..< max(rangeA.upperBound, rangeB.upperBound)
                barrier.offset = VkDeviceSize(range.lowerBound)
                barrier.size = VkDeviceSize(range.count)
              }
              barrier.srcAccessMask = producingUsage.type.accessMask(isDepthOrStencil: false).flags
              barrier.dstAccessMask = consumingUsage.type.accessMask(isDepthOrStencil: false).flags
              barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
              barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
              bufferBarriers.append(barrier)
            } else if let texture = Texture(resource) {
              let textureDescriptor = texture.descriptor
              let pixelFormat = textureDescriptor.pixelFormat
              isDepthOrStencil = pixelFormat.isDepth || pixelFormat.isStencil

              let image = resourceMap[texture]!.image

              var barrier = VkImageMemoryBarrier()
              barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
              barrier.image = image.vkImage
              barrier.srcAccessMask = producingUsage.type.accessMask(isDepthOrStencil: isDepthOrStencil).flags
              barrier.dstAccessMask = consumingUsage.type.accessMask(isDepthOrStencil: isDepthOrStencil).flags
              barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
              barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
              barrier.oldLayout = image.layout(commandIndex: producingUsage.commandRange.last!, subresourceRange: producingUsage.activeRange)
              barrier.newLayout = image.layout(commandIndex: consumingUsage.commandRange.first!, subresourceRange: consumingUsage.activeRange)

              if !producingUsage.isWrite, !consumingUsage.isWrite, barrier.oldLayout == barrier.newLayout {
                continue // This would only be a layout transition barrrier, and we don't need to transition layouts.
              }

              if producingUsage.type.isRenderTarget || consumingUsage.type.isRenderTarget {
                // Handle this through a subpass dependency.
                // TODO: when we support queue ownership transfers, we may also need a pipeline barrier here.
                var subpassDependency = VkSubpassDependency()
                let renderTargetsDescriptor: VulkanRenderTargetDescriptor
                if producingUsage.type.isRenderTarget {
                  // We transitioned to the new layout at the end of the previous render pass.
                  // Add a subpass dependency and continue.
                  barrier.oldLayout = barrier.newLayout
                  renderTargetsDescriptor = frameCommandInfo.commandEncoderRenderTargets[sourceIndex]!
                  subpassDependency.srcSubpass = UInt32(renderTargetsDescriptor.subpasses.last!.index)
                  subpassDependency.dstSubpass = VK_SUBPASS_EXTERNAL
                } else {
                  // The layout transition will be handled by the next render pass.
                  // Add a subpass dependency and continue.
                  barrier.newLayout = barrier.oldLayout
                  renderTargetsDescriptor = frameCommandInfo.commandEncoderRenderTargets[dependentIndex]!
                  subpassDependency.srcSubpass = VK_SUBPASS_EXTERNAL
                  subpassDependency.dstSubpass = 0
                }

                subpassDependency.srcStageMask = producingUsage.type.shaderStageMask(isDepthOrStencil: isDepthOrStencil, stages: producingUsage.stages).flags
                subpassDependency.srcAccessMask = barrier.srcAccessMask
                subpassDependency.dstStageMask = consumingUsage.type.shaderStageMask(isDepthOrStencil: isDepthOrStencil, stages: consumingUsage.stages).flags
                subpassDependency.dstAccessMask = barrier.dstAccessMask

                renderTargetsDescriptor.addDependency(subpassDependency)
                continue
              } else {
                let previousUsage = texture.usages.lazy.filter { $0.affectsGPUBarriers }.prefix(while: { !$0.commandRange.contains(consumingUsage.commandRange.first!) }).last
                if let previousUsage = previousUsage, !previousUsage.isWrite {
                  // There were other reads before consumingUsage, of which the first would have performed the layout transition; therefore, we don't need to transition here.
                  barrier.oldLayout = barrier.newLayout
                }
              }
              barrier.subresourceRange = VkImageSubresourceRange(aspectMask: textureDescriptor.pixelFormat.aspectFlags, baseMipLevel: 0, levelCount: UInt32(textureDescriptor.mipmapLevelCount), baseArrayLayer: 0, layerCount: UInt32(textureDescriptor.arrayLength))

              switch (producingUsage.activeRange, consumingUsage.activeRange) {
              case let (.texture(mask), .fullResource),
                   let (.fullResource, .texture(mask)):
                if mask.value == .max {
                  imageBarriers.appendBarrier(barrier)
                } else {
                  var activeMask = SubresourceMask(source: mask, subresourceCount: textureDescriptor.subresourceCount, allocator: AllocatorType(allocator))
                  processImageSubresourceRanges(&activeMask, textureDescriptor: textureDescriptor, allocator: AllocatorType(allocator)) {
                    barrier.subresourceRange = $0
                    imageBarriers.appendBarrier(barrier)
                  }
                }

              case let (.texture(maskA), .texture(maskB)):
                var activeMask = SubresourceMask(source: maskA, subresourceCount: textureDescriptor.subresourceCount, allocator: AllocatorType(allocator))
                activeMask.formIntersection(with: maskB, subresourceCount: textureDescriptor.subresourceCount, allocator: AllocatorType(allocator))

                processImageSubresourceRanges(&activeMask, textureDescriptor: textureDescriptor, allocator: AllocatorType(allocator)) {
                  barrier.subresourceRange = $0
                  imageBarriers.appendBarrier(barrier)
                }

              case (.fullResource, .fullResource):
                imageBarriers.appendBarrier(barrier)
              default:
                fatalError()
              }

            } else {
              fatalError()
            }

            destinationStages.formUnion(consumingUsage.type.shaderStageMask(isDepthOrStencil: isDepthOrStencil, stages: consumingUsage.stages))
          }

          if signalStages.isEmpty || destinationStages.isEmpty {
            // Everything has been handled by either pipeline barriers or subpass dependencies, so we don't need a vkCmdWaitEvents.
            continue
          }

          let label = "Encoder \(sourceIndex) Event"
          let sourceEncoder = frameCommandInfo.commandEncoders[sourceIndex]
          let fence = VulkanEventHandle(label: label, queue: queue)

          fence.commandBufferIndex = frameCommandInfo.globalCommandBufferIndex(frameIndex: frameCommandInfo.commandEncoders[dependentIndex].commandBufferIndex)

          if sourceEncoder.type == .draw {
            signalIndex = max(signalIndex, sourceEncoder.commandRange.last!) // We can't signal within a VkRenderPass instance.
          }

          compactedResourceCommands.append(CompactedResourceCommand<VulkanCompactedResourceCommandType>(command: .signalEvent(fence.event, afterStages: signalStages), index: signalIndex, order: .after))

          let bufferBarriersPtr: UnsafeMutablePointer<VkBufferMemoryBarrier> = allocator.allocate(capacity: bufferBarriers.count)
          bufferBarriersPtr.initialize(from: bufferBarriers, count: bufferBarriers.count)

          let imageBarriersPtr: UnsafeMutablePointer<VkImageMemoryBarrier> = allocator.allocate(capacity: imageBarriers.count)
          imageBarriersPtr.initialize(from: imageBarriers, count: imageBarriers.count)

          let command: VulkanCompactedResourceCommandType = .waitForEvents(UnsafeBufferPointer(start: fence.eventPointer, count: 1),
                                                                           sourceStages: signalStages, destinationStages: destinationStages,
                                                                           memoryBarriers: UnsafeBufferPointer<VkMemoryBarrier>(start: nil, count: 0),
                                                                           bufferMemoryBarriers: UnsafeBufferPointer<VkBufferMemoryBarrier>(start: bufferBarriersPtr, count: bufferBarriers.count),
                                                                           imageMemoryBarriers: UnsafeBufferPointer<VkImageMemoryBarrier>(start: imageBarriersPtr, count: imageBarriers.count))

          var waitIndex = dependency.wait.index
          let dependentEncoder = frameCommandInfo.commandEncoders[dependentIndex]
          if dependentEncoder.type == .draw {
            waitIndex = dependentEncoder.commandRange.first! // We can't wait within a VkRenderPass instance.
          }

          compactedResourceCommands.append(CompactedResourceCommand<VulkanCompactedResourceCommandType>(command: command, index: waitIndex, order: .before))
        }
      }
    }

    func compactResourceCommands(queue: Queue, resourceMap: VulkanPersistentResourceRegistry, commandInfo: FrameCommandInfo<VulkanRenderTargetDescriptor>, commandGenerator: ResourceCommandGenerator<VulkanBackend>, into compactedResourceCommands: inout [CompactedResourceCommand<VulkanCompactedResourceCommandType>]) {
      guard !commandGenerator.commands.isEmpty else { return }
      assert(compactedResourceCommands.isEmpty)

      generateEventCommands(queue: queue, resourceMap: resourceMap, frameCommandInfo: commandInfo, commandGenerator: commandGenerator, compactedResourceCommands: &compactedResourceCommands)

      let allocator = ThreadLocalTagAllocator(tag: .renderGraphResourceCommandArrayTag)

      var currentEncoderIndex = 0
      var currentPassIndex = 0

      var bufferBarriers = [VkBufferMemoryBarrier]()
      var imageBarriers = [VkImageMemoryBarrier]()

      var barrierAfterStages: VkPipelineStageFlagBits = []
      var barrierBeforeStages: VkPipelineStageFlagBits = []
      var barrierLastIndex: Int = .max

      let addBarrier: (inout [CompactedResourceCommand<VulkanCompactedResourceCommandType>]) -> Void = { compactedResourceCommands in
        let bufferBarriersPtr: UnsafeMutablePointer<VkBufferMemoryBarrier> = allocator.allocate(capacity: bufferBarriers.count)
        bufferBarriersPtr.initialize(from: bufferBarriers, count: bufferBarriers.count)

        let imageBarriersPtr: UnsafeMutablePointer<VkImageMemoryBarrier> = allocator.allocate(capacity: imageBarriers.count)
        imageBarriersPtr.initialize(from: imageBarriers, count: imageBarriers.count)

        let command: VulkanCompactedResourceCommandType = .pipelineBarrier(sourceStages: barrierAfterStages,
                                                                           destinationStages: barrierBeforeStages,
                                                                           dependencyFlags: VkDependencyFlagBits(rawValue: 0),
                                                                           memoryBarriers: UnsafeBufferPointer<VkMemoryBarrier>(start: nil, count: 0),
                                                                           bufferMemoryBarriers: UnsafeBufferPointer<VkBufferMemoryBarrier>(start: bufferBarriersPtr, count: bufferBarriers.count),
                                                                           imageMemoryBarriers: UnsafeBufferPointer<VkImageMemoryBarrier>(start: imageBarriersPtr, count: imageBarriers.count))

        compactedResourceCommands.append(.init(command: command, index: barrierLastIndex, order: .before))

        bufferBarriers.removeAll(keepingCapacity: true)
        imageBarriers.removeAll(keepingCapacity: true)
        barrierAfterStages = []
        barrierBeforeStages = []
        barrierLastIndex = .max
      }

      func processMemoryBarrier(resource: Resource, afterCommand: Int, afterUsageType: ResourceUsageType, afterStages: RenderStages, beforeCommand: Int, beforeUsageType: ResourceUsageType, beforeStages: RenderStages, activeRange: ActiveResourceRange) -> Bool {
        let currentEncoder = commandInfo.commandEncoders[currentEncoderIndex]
        // We can't insert layout transition barriers during a render pass if the barriers are not applicable to that render encoder;
        // instead, defer them until compute work/as late as necessary.
        if afterUsageType == .textureView, currentEncoder.type == .draw, !currentEncoder.passRange.contains(beforeCommand) {
          return false
        }

        var remainingRange = ActiveResourceRange.inactive // The subresource range not processed by this barrier.
        var activeRange = activeRange

        let pixelFormat = Texture(resource)?.descriptor.pixelFormat ?? .invalid
        let isDepthOrStencil = pixelFormat.isDepth || pixelFormat.isStencil

        let sourceLayout: VkImageLayout
        let destinationLayout: VkImageLayout
        if let image = Texture(resource).flatMap({ resourceMap[$0]?.image }) {
          if afterUsageType == .textureView {
            if !resource._usesPersistentRegistry {
              sourceLayout = VK_IMAGE_LAYOUT_UNDEFINED
            } else {
              (sourceLayout, activeRange, remainingRange) = image.frameInitialLayout(for: activeRange, allocator: AllocatorType(allocator))
            }
          } else {
            sourceLayout = image.layout(commandIndex: afterCommand, subresourceRange: activeRange)
          }

          destinationLayout = image.layout(commandIndex: beforeCommand, subresourceRange: activeRange)
        } else {
          assert(resource.type != .texture || resource.flags.contains(.windowHandle))
          sourceLayout = VK_IMAGE_LAYOUT_UNDEFINED
          destinationLayout = VK_IMAGE_LAYOUT_UNDEFINED
        }

        defer {
          // It's possible there are multiple source layouts/subresource ranges, in which case we insert multiple barriers.
          if !remainingRange.isEqual(to: .inactive, resource: resource) {
            _ = processMemoryBarrier(resource: resource, afterCommand: afterCommand, afterUsageType: afterUsageType, afterStages: afterStages, beforeCommand: beforeCommand, beforeUsageType: beforeUsageType, beforeStages: beforeStages, activeRange: remainingRange)
          }
        }

        if sourceLayout == destinationLayout, afterUsageType == .textureView || (!afterUsageType.isWrite && !beforeUsageType.isWrite) {
          return true // No layout transition needed, and no execution barrier needed, so we don't need to insert a memory barrier; however, we've still successfully processed this barrier.
        }

        let sourceMask = afterUsageType.shaderStageMask(isDepthOrStencil: isDepthOrStencil, stages: afterStages)
        let destinationMask = beforeUsageType.shaderStageMask(isDepthOrStencil: isDepthOrStencil, stages: beforeStages)

        let sourceAccessMask = afterUsageType.accessMask(isDepthOrStencil: isDepthOrStencil).flags
        let destinationAccessMask = beforeUsageType.accessMask(isDepthOrStencil: isDepthOrStencil).flags

        var beforeCommand = beforeCommand

        if let renderTargetsDescriptor = commandInfo.commandEncoderRenderTargets[currentEncoderIndex], beforeCommand > currentEncoder.passRange.lowerBound {
          var subpassDependency = VkSubpassDependency()
          subpassDependency.dependencyFlags = VkDependencyFlags(VK_DEPENDENCY_BY_REGION_BIT) // FIXME: ideally should be VkDependencyFlags(VK_DEPENDENCY_BY_REGION_BIT) for all cases except temporal AA.
          if afterUsageType == .textureView {
            subpassDependency.srcSubpass = VK_SUBPASS_EXTERNAL
          } else if let passUsageSubpass = renderTargetsDescriptor.subpassForPassIndex(currentPassIndex) {
            subpassDependency.srcSubpass = UInt32(passUsageSubpass.index)
          } else {
            subpassDependency.srcSubpass = VK_SUBPASS_EXTERNAL
          }
          subpassDependency.srcStageMask = sourceMask.flags
          subpassDependency.srcAccessMask = sourceAccessMask

          let dependentPass = commandInfo.passes[currentPassIndex...].first(where: { $0.commandRange!.contains(beforeCommand) })!
          if let destinationUsageSubpass = renderTargetsDescriptor.subpassForPassIndex(dependentPass.passIndex) {
            subpassDependency.dstSubpass = UInt32(destinationUsageSubpass.index)
          } else {
            subpassDependency.dstSubpass = VK_SUBPASS_EXTERNAL
          }
          subpassDependency.dstStageMask = destinationMask.flags
          subpassDependency.dstAccessMask = destinationAccessMask

          // If the dependency is on an attachment, then we can let the subpass dependencies handle it, _unless_ both usages are in the same subpass.
          // Otherwise, an image should always be in the right layout when it's materialised. The only case it won't be is if it's used in one way in
          // a draw render pass (e.g. as a read texture) and then needs to transition layout before being used in a different type of pass.

          if subpassDependency.srcSubpass == subpassDependency.dstSubpass {
            precondition(resource.type == .texture, "We can only insert pipeline barriers within render passes for textures.")
            assert(subpassDependency.srcSubpass != VK_SUBPASS_EXTERNAL, "Dependent pass \(dependentPass.passIndex): Subpass dependency from \(afterUsageType) (afterCommand \(afterCommand)) to \(beforeUsageType) (beforeCommand \(beforeCommand)) for resource \(resource) is EXTERNAL to EXTERNAL, which is invalid.")
            renderTargetsDescriptor.addDependency(subpassDependency)
          } else if sourceLayout != destinationLayout, // guaranteed to not be a buffer since buffers have UNDEFINED image layouts above.
                    !afterUsageType.isRenderTarget, !beforeUsageType.isRenderTarget
          {
            // We need to insert a pipeline barrier to handle a layout transition.
            // We can therefore avoid a subpass dependency in most cases.

            if subpassDependency.srcSubpass == VK_SUBPASS_EXTERNAL {
              // Insert a pipeline barrier before the start of the Render Command Encoder.
              beforeCommand = min(beforeCommand, currentEncoder.passRange.lowerBound)
            } else if subpassDependency.dstSubpass == VK_SUBPASS_EXTERNAL {
              // Insert a pipeline barrier before the next command after the render command encoder ends.
              assert(beforeCommand >= currentEncoder.passRange.last!)
            } else {
              // Insert a subpass self-dependency and a pipeline barrier.
              fatalError("This should have been handled by the subpassDependency.srcSubpass == subpassDependency.dstSubpass case.")

              // resourceCommands.append(VulkanFrameResourceCommand(command: .pipelineBarrier(memoryBarrierInfo), index: dependentCommandIndex, order: .before))
              // subpassDependency.srcSubpass = subpassDependency.dstSubpass
              // renderTargetsDescriptor.addDependency(subpassDependency)
            }
          } else {
            // A subpass dependency should be enough to handle this case.
            renderTargetsDescriptor.addDependency(subpassDependency)
            return true
          }
        }

        if let buffer = Buffer(resource) {
          var barrier = VkBufferMemoryBarrier()
          barrier.sType = VK_STRUCTURE_TYPE_BUFFER_MEMORY_BARRIER
          barrier.buffer = resourceMap[buffer]!.buffer.vkBuffer
          barrier.offset = 0
          barrier.size = VK_WHOLE_SIZE // TODO: track at a more fine-grained level.
          if case let .buffer(range) = activeRange {
            barrier.offset = VkDeviceSize(range.lowerBound)
            barrier.size = VkDeviceSize(range.count)
          }
          barrier.srcAccessMask = sourceAccessMask
          barrier.dstAccessMask = destinationAccessMask
          barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
          barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
          bufferBarriers.append(barrier)
        } else if let texture = Texture(resource) {
          var barrier = VkImageMemoryBarrier()
          barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
          barrier.image = resourceMap[texture]!.image.vkImage
          barrier.srcAccessMask = sourceAccessMask
          barrier.dstAccessMask = destinationAccessMask
          barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
          barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED
          barrier.oldLayout = sourceLayout
          barrier.newLayout = destinationLayout

          barrier.subresourceRange = VkImageSubresourceRange(aspectMask: texture.descriptor.pixelFormat.aspectFlags, baseMipLevel: 0, levelCount: UInt32(texture.descriptor.mipmapLevelCount), baseArrayLayer: 0, layerCount: UInt32(texture.descriptor.arrayLength))
          switch activeRange {
          case .fullResource:
            imageBarriers.appendBarrier(barrier)
          case let .texture(mask):
            if mask.value == .max {
              imageBarriers.appendBarrier(barrier)
            } else {
              var activeMask = SubresourceMask(source: mask, subresourceCount: texture.descriptor.subresourceCount, allocator: AllocatorType(allocator))
              processImageSubresourceRanges(&activeMask, textureDescriptor: texture.descriptor, allocator: AllocatorType(allocator)) { range in
                barrier.subresourceRange = range
                imageBarriers.appendBarrier(barrier)
              }
            }
          default:
            fatalError()
          }
        }
        barrierAfterStages.formUnion(sourceMask)
        barrierBeforeStages.formUnion(destinationMask)
        barrierLastIndex = min(beforeCommand, barrierLastIndex)

        return true
      }

      var pendingCommands = [FrameResourceCommands]()

      func processPendingCommands() {
        let encoderFirstCommand = commandInfo.commandEncoders[currentEncoderIndex].passRange.first!
        var i = 0
        while i < pendingCommands.count {
          guard case let .memoryBarrier(resource, afterUsage, afterStages, beforeCommand, beforeUsage, beforeStages, activeRange) = pendingCommands[i] else {
            i += 1
            continue
          }

          if processMemoryBarrier(resource: resource, afterCommand: encoderFirstCommand, afterUsageType: afterUsage, afterStages: afterStages, beforeCommand: beforeCommand, beforeUsageType: beforeUsage, beforeStages: beforeStages, activeRange: activeRange) {
            pendingCommands.remove(at: i, preservingOrder: false)
          } else {
            i += 1
          }
        }
      }

      for command in commandGenerator.commands {
        while (commandInfo.passes[currentPassIndex].passIndex != command.index) {
          currentPassIndex += 1
        }

        while !commandInfo.commandEncoders[currentEncoderIndex].passRange.contains(command.index) {
          currentEncoderIndex += 1

          processPendingCommands()

          assert(bufferBarriers.isEmpty)
          assert(imageBarriers.isEmpty)
        }

        if command.index >= barrierLastIndex { // For barriers, the barrier associated with command.index needs to happen _after_ any barriers required to happen _by_ barrierLastIndex
          addBarrier(&compactedResourceCommands)
        }

        // Strategy:
        // useResource should be batched together by usage to as early as possible in the encoder.
        // memoryBarriers should be as late as possible.
        switch command.command {
        case .useResource:
          fatalError("Vulkan does not track resource residency")
        case let .memoryBarrier(resource, afterUsage, afterStages, beforeCommand, beforeUsage, beforeStages, activeRange):
          if !processMemoryBarrier(resource: resource, afterCommand: command.index, afterUsageType: afterUsage, afterStages: afterStages, beforeCommand: beforeCommand, beforeUsageType: beforeUsage, beforeStages: beforeStages, activeRange: activeRange) {
            pendingCommands.append(command.command)
          }
        }
      }

      if barrierLastIndex < .max {
        addBarrier(&compactedResourceCommands)
      }

      // Flush any pending layout transition commands
      currentEncoderIndex += 1
      while currentEncoderIndex < commandInfo.commandEncoders.count {
        processPendingCommands()

        if barrierLastIndex < .max {
          addBarrier(&compactedResourceCommands)
        }
        currentEncoderIndex += 1
      }

      assert(pendingCommands.isEmpty, "Barriers \(pendingCommands) are still pending")

      compactedResourceCommands.sort()
    }
  }

  enum VulkanResourceMemoryBarrier {
    case texture(Texture, VkImageMemoryBarrier)
    case buffer(Buffer, VkBufferMemoryBarrier)
  }

  struct VulkanMemoryBarrierInfo {
    var sourceMask: VkPipelineStageFlagBits
    var destinationMask: VkPipelineStageFlagBits
    var barrier: VulkanResourceMemoryBarrier
  }

  enum VulkanCompactedResourceCommandType {
    case signalEvent(VkEvent, afterStages: VkPipelineStageFlagBits)

    case waitForEvents(_ events: UnsafeBufferPointer<VkEvent?>, sourceStages: VkPipelineStageFlagBits, destinationStages: VkPipelineStageFlagBits, memoryBarriers: UnsafeBufferPointer<VkMemoryBarrier>, bufferMemoryBarriers: UnsafeBufferPointer<VkBufferMemoryBarrier>, imageMemoryBarriers: UnsafeBufferPointer<VkImageMemoryBarrier>)

    case pipelineBarrier(sourceStages: VkPipelineStageFlagBits, destinationStages: VkPipelineStageFlagBits, dependencyFlags: VkDependencyFlagBits, memoryBarriers: UnsafeBufferPointer<VkMemoryBarrier>, bufferMemoryBarriers: UnsafeBufferPointer<VkBufferMemoryBarrier>, imageMemoryBarriers: UnsafeBufferPointer<VkImageMemoryBarrier>)
  }

#endif // canImport(Vulkan)
