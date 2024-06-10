#if canImport(Vulkan)
import Vulkan
@_implementationOnly import SubstrateCExtras

extension ResourceUsageType {

    public func imageLayout(isDepthOrStencil: Bool) -> VkImageLayout? {
        switch self {
        case .shaderRead, .constantBuffer, .inputAttachment:
            return isDepthOrStencil ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_READ_ONLY_OPTIMAL : VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL
        case .shaderWrite, .shaderReadWrite:
            return VK_IMAGE_LAYOUT_GENERAL
        case .colorAttachment, .depthStencilAttachment:
            return isDepthOrStencil ? VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL : VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
        case .blitSource:
            return VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
        case .blitDestination:
            return VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
        case .textureView:
            return VK_IMAGE_LAYOUT_GENERAL
        case .indirectBuffer:
            return nil
        default:
            fatalError("Unknown image layout for usage \(self)")
        }
    }
    
    public func accessMask(isDepthOrStencil: Bool) -> VkAccessFlagBits {
        switch self {
        case .shaderRead: // not a constant/uniform buffer
            return VK_ACCESS_SHADER_READ_BIT
        case .shaderWrite:
            return VK_ACCESS_SHADER_WRITE_BIT
        case .shaderReadWrite:   
            return [VK_ACCESS_SHADER_READ_BIT, VK_ACCESS_SHADER_WRITE_BIT]
        case .colorAttachmentWrite, .depthStencilAttachmentWrite:
            return isDepthOrStencil ? VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT :
                                      VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT
        case .colorAttachmentRead, .colorAttachmentWrite, .depthStencilAttachmentRead, .depthStencilAttachmentWrite:
            return isDepthOrStencil ? [VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_READ_BIT, VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT] :
                                      [VK_ACCESS_COLOR_ATTACHMENT_READ_BIT, VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT]
                    
        case .inputAttachment:
            return VK_ACCESS_INPUT_ATTACHMENT_READ_BIT
        case .constantBuffer:
            return VK_ACCESS_UNIFORM_READ_BIT
        case .blitSource:
            return VK_ACCESS_TRANSFER_READ_BIT
        case .blitDestination:
            return VK_ACCESS_TRANSFER_WRITE_BIT
        case .blitSource:
            return [VK_ACCESS_HOST_READ_BIT, VK_ACCESS_HOST_WRITE_BIT]
        case .vertexBuffer:
            return VK_ACCESS_VERTEX_ATTRIBUTE_READ_BIT
        case .indexBuffer:
            return VK_ACCESS_INDEX_READ_BIT
        case .indirectBuffer:
            return VK_ACCESS_INDIRECT_COMMAND_READ_BIT
        case .textureView: // Used for image layout transitions at the start of the frame
            return []
        default:
            fatalError()
        }
    }
    
    public func shaderStageMask(isDepthOrStencil: Bool, stages: RenderStages) -> VkPipelineStageFlagBits {
        switch self {
        case .constantBuffer, .shaderRead, .shaderReadWrite, .shaderWrite:
            var flags: VkPipelineStageFlagBits = []
        
            if stages.contains(.vertex) {
                flags.formUnion(VK_PIPELINE_STAGE_VERTEX_SHADER_BIT)
            }
            if stages.contains(.fragment) {
                flags.formUnion(VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT)
            }
            if stages.contains(.compute) {
                flags.formUnion(VK_PIPELINE_STAGE_COMPUTE_SHADER_BIT)
            }
            return flags

        case .colorAttachmentRead, .colorAttachmentWrite, .depthStencilAttachmentRead, .depthStencilAttachmentWrite:
            if isDepthOrStencil {
                return [VK_PIPELINE_STAGE_EARLY_FRAGMENT_TESTS_BIT, VK_PIPELINE_STAGE_LATE_FRAGMENT_TESTS_BIT]
            } else {
                return VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT
            }
         case .inputAttachment:
            return VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
        case .blitSource:
            return VK_PIPELINE_STAGE_TRANSFER_BIT
        case .blitDestination:
            return VK_PIPELINE_STAGE_TRANSFER_BIT
        case .cpuRead, .cpuWrite:
            return VK_PIPELINE_STAGE_HOST_BIT
        case .vertexBuffer, .indexBuffer:
            return VK_PIPELINE_STAGE_VERTEX_INPUT_BIT
        case .indirectBuffer:
            return VK_PIPELINE_STAGE_DRAW_INDIRECT_BIT
        case .textureView: // Used for image layout transitions at the start of the frame
            return VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
        default:
            fatalError()
        }
    }

}

#endif // canImport(Vulkan)
