//
//  VulkanFramebuffer.swift
//  VkRenderer
//
//  Created by Thomas Roughton on 14/01/18.
//

#if canImport(Vulkan)
  @_implementationOnly import SubstrateCExtras
  import Vulkan

  final class VulkanFramebuffer {
    let device: VulkanDevice
    let framebuffer: VkFramebuffer

    let imageViews: [VulkanImageView]

    init(descriptor: VulkanRenderTargetDescriptor, renderPass: VulkanRenderPass, device: VulkanDevice, resourceMap: VulkanPersistentResourceRegistry) async throws {
      self.device = device

      let renderTargetSize = descriptor.descriptor.size

      var createInfo = VkFramebufferCreateInfo()
      createInfo.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO
      createInfo.renderPass = renderPass.vkPass
      createInfo.width = UInt32(renderTargetSize.width)
      createInfo.height = UInt32(renderTargetSize.height)
      createInfo.layers = UInt32(max(descriptor.descriptor.renderTargetArrayLength, 1))

      var attachments = [VkImageView?]()
      attachments.reserveCapacity(renderPass.attachmentCount)

      var imageViews = [VulkanImageView]()
      imageViews.reserveCapacity(renderPass.attachmentCount)

      // Depth-stencil first, then colour.

      if let depthAttachment = descriptor.descriptor.depthAttachment {
        let image = try await resourceMap.renderTargetTexture(depthAttachment.texture).image
        let imageView = image.viewForAttachment(descriptor: depthAttachment)
        imageViews.append(imageView)
        attachments.append(imageView.vkView)
      }

      if let stencilAttachment = descriptor.descriptor.stencilAttachment, stencilAttachment.texture != descriptor.descriptor.depthAttachment?.texture {
        let image = try await resourceMap.renderTargetTexture(stencilAttachment.texture).image
        let imageView = image.viewForAttachment(descriptor: stencilAttachment)
        imageViews.append(imageView)
        attachments.append(imageView.vkView)
      }

      for (i, attachment) in descriptor.descriptor.colorAttachments.enumerated() {
        guard let attachment = attachment else { continue }

        let image = try await resourceMap.renderTargetTexture(attachment.texture).image
        let imageView = image.viewForAttachment(descriptor: attachment)
        imageViews.append(imageView)
        attachments.append(imageView.vkView)
      }

      self.imageViews = imageViews

      var framebuffer: VkFramebuffer?

      attachments.withUnsafeBufferPointer { attachments in
        createInfo.pAttachments = attachments.baseAddress
        createInfo.attachmentCount = UInt32(attachments.count)

        vkCreateFramebuffer(device.vkDevice, &createInfo, nil, &framebuffer)
      }

      self.framebuffer = framebuffer!
    }

    deinit {
      vkDestroyFramebuffer(self.device.vkDevice, self.framebuffer, nil)
    }
  }

#endif // canImport(Vulkan)
