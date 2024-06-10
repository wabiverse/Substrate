//
//  VulkanBackend.swift
//  VKRenderer
//
//  Created by Joseph Bennett on 1/1/18.
//
//

#if canImport(Vulkan)
  import Foundation
  @_implementationOnly import SubstrateCExtras
  import SubstrateUtilities
  import Vulkan

  public final class VulkanBackend: SpecificRenderBackend {
    @TaskLocal static var activeContext: RenderGraphContextImpl<VulkanBackend>? = nil

    static var activeContextTaskLocal: TaskLocal<RenderGraphContextImpl<VulkanBackend>?> { $activeContext }

    typealias BufferReference = VkBufferReference
    typealias TextureReference = VkImageReference
    typealias ArgumentBufferReference = VulkanArgumentBuffer
    typealias SamplerReference = VkSampler
    typealias ResourceReference = Void

    typealias VisibleFunctionTableReference = Void
    typealias IntersectionFunctionTableReference = Void

    typealias TransientResourceRegistry = VulkanTransientResourceRegistry
    typealias PersistentResourceRegistry = VulkanPersistentResourceRegistry

    typealias RenderTargetDescriptor = VulkanRenderTargetDescriptor

    typealias CompactedResourceCommandType = VulkanCompactedResourceCommandType
    typealias Event = VkSemaphore
    typealias BackendQueue = VulkanQueue
    typealias InterEncoderDependencyType = FineDependency
    typealias CommandBuffer = VulkanCommandBuffer
    typealias QueueImpl = VulkanQueue

    public var api: RenderAPI {
      return .vulkan
    }

    public let vulkanInstance: VulkanInstance
    public let device: VulkanDevice

    let resourceRegistry: VulkanPersistentResourceRegistry
    let shaderLibrary: VulkanShaderLibrary
    let stateCaches: VulkanStateCaches
    let enableValidation: Bool
    let enableShaderHotReloading: Bool

    var activeContext: RenderGraphContextImpl<VulkanBackend>? = nil
    let activeContextLock = SpinLock()

    var queueSyncSemaphores = [VkSemaphore?](repeating: nil, count: QueueRegistry.maxQueues)

    public init(instance: VulkanInstance, shaderLibraryURL: URL, enableValidation: Bool = true, enableShaderHotReloading: Bool = true) {
      vulkanInstance = instance
      let physicalDevice = vulkanInstance.createSystemDefaultDevice()!

      device = VulkanDevice(physicalDevice: physicalDevice)!

      resourceRegistry = VulkanPersistentResourceRegistry(instance: instance, device: device)
      shaderLibrary = try! VulkanShaderLibrary(device: device, url: shaderLibraryURL)
      stateCaches = VulkanStateCaches(device: device, shaderLibrary: shaderLibrary)
      self.enableValidation = enableValidation
      self.enableShaderHotReloading = enableShaderHotReloading

      RenderBackend._backend = self
    }

    func reloadShaderLibraryIfNeeded() async {
      if enableShaderHotReloading {
        await stateCaches.checkForLibraryReload()
      }
    }

    public func materialisePersistentResource(_ resource: Resource) -> Bool {
      switch resource.type {
      case .texture:
        return resourceRegistry.allocateTexture(Texture(resource)!) != nil
      case .buffer:
        return resourceRegistry.allocateBuffer(Buffer(resource)!) != nil
      default:
        preconditionFailure("Unhandled resource type in materialiseResource")
      }
    }

    public func buffer(_ buffer: Buffer, didModifyRange range: Range<Int>) {
      if range.isEmpty { return }
      let bufferReference = resourceRegistry[buffer]!
      let buffer = bufferReference.buffer
      buffer.didModifyRange((range.lowerBound + bufferReference.offset) ..< (range.upperBound + bufferReference.offset))
    }

    public func replaceTextureRegion(texture: Texture, region: Region, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) async {
      await replaceTextureRegion(texture: texture, region: region, mipmapLevel: mipmapLevel, slice: 0, withBytes: bytes, bytesPerRow: bytesPerRow, bytesPerImage: bytesPerRow * region.size.height * region.size.depth)
    }

    public func dispose(resource: Resource) {
      resourceRegistry.dispose(resource: resource)
    }

    public func backingResource(_ resource: Resource) -> Any? {
      if let buffer = Buffer(resource) {
        let bufferReference = resourceRegistry[buffer]
        return bufferReference?.buffer.vkBuffer
      } else if let texture = Texture(resource) {
        return resourceRegistry[texture]?.image.vkImage
      }
      return nil
    }

    public func supportsPixelFormat(_ pixelFormat: PixelFormat, usage: TextureUsage) -> Bool {
      return device.physicalDevice.supportsPixelFormat(pixelFormat, usage: usage)
    }

    public var hasUnifiedMemory: Bool {
      return false // TODO: Retrieve this from the device.
    }

    public var requiresEmulatedInputAttachments: Bool {
      return false
    }

    public var supportsMemorylessAttachments: Bool {
      return false
    }

    public var renderDevice: Any {
      return device
    }

    @usableFromInline
    func renderPipelineReflection(descriptor: RenderPipelineDescriptor) -> PipelineReflection? {
      return stateCaches.reflection(for: descriptor, renderTarget: nil)
    }

    @usableFromInline
    func computePipelineReflection(descriptor: ComputePipelineDescriptor) -> PipelineReflection? {
      return stateCaches.reflection(for: descriptor)
    }

    @usableFromInline
    var pushConstantPath: ResourceBindingPath {
      return ResourceBindingPath.pushConstantPath
    }

    @usableFromInline func replaceBackingResource(for _: Resource, with _: Any?) -> Any? {
      fatalError("replaceBackingResource(for:with:) is unimplemented on Vulkan")
    }

    @usableFromInline
    func registerExternalResource(_: Resource, backingResource _: Any) {
      fatalError("registerExternalResource is unimplemented on Vulkan")
    }

    @usableFromInline
    func copyTextureBytes(from _: Texture, to _: UnsafeMutableRawPointer, bytesPerRow _: Int, region _: Region, mipmapLevel _: Int) {
      fatalError("copyTextureBytes is unimplemented on Vulkan")
    }

    public func sizeAndAlignment(for _: BufferDescriptor) -> (size: Int, alignment: Int) {
      fatalError("sizeAndAlignment(for:) is unimplemented on Vulkan")
    }

    public func sizeAndAlignment(for _: TextureDescriptor) -> (size: Int, alignment: Int) {
      fatalError("sizeAndAlignment(for:) is unimplemented on Vulkan")
    }

    @usableFromInline func usedSize(for _: Heap) -> Int {
      fatalError("usedSize(for:) is unimplemented on Vulkan")
    }

    @usableFromInline func currentAllocatedSize(for _: Heap) -> Int {
      fatalError("currentAllocatedSize(for:) is unimplemented on Vulkan")
    }

    @usableFromInline func maxAvailableSize(forAlignment _: Int, in _: Heap) -> Int {
      fatalError("maxAvailableSize(forAlignment:in:) is unimplemented on Vulkan")
    }

    @usableFromInline func accelerationStructureSizes(for _: AccelerationStructureDescriptor) -> AccelerationStructureSizes {
      fatalError("accelerationStructureSizes(for:) is unimplemented on Vulkan")
    }

    @usableFromInline
    func replaceTextureRegion(texture: Texture, region: Region, mipmapLevel: Int, slice: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int, bytesPerImage _: Int) async {
      let textureReference = resourceRegistry[texture]!
      let image = textureReference.image

      var data: UnsafeMutableRawPointer! = nil
      vmaMapMemory(image.allocator!, image.allocation!, &data)

      var subresource = VkImageSubresource()
      subresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT.flags
      subresource.mipLevel = UInt32(mipmapLevel)
      subresource.arrayLayer = UInt32(slice)

      var layout = VkSubresourceLayout()
      vkGetImageSubresourceLayout(device.vkDevice, image.vkImage, &subresource, &layout)

      data += Int(layout.offset)

      let bytesPerPixel = texture.descriptor.pixelFormat.bytesPerPixel

      var sourcePointer = bytes
      for z in region.origin.z ..< region.origin.z + region.size.depth {
        let zSliceData = data + z * Int(layout.depthPitch)
        for row in region.origin.y ..< region.origin.y + region.size.height {
          let offsetInRow = Int(exactly: bytesPerPixel * Double(region.origin.x))!
          let bytesInRow = Int(exactly: bytesPerPixel * Double(region.size.width))!
          assert(bytesInRow == bytesPerRow)

          (zSliceData + row * Int(layout.rowPitch) + offsetInRow).copyMemory(from: sourcePointer, byteCount: bytesInRow)
          sourcePointer += bytesPerRow
        }
      }

      vmaUnmapMemory(image.allocator!, image.allocation!)
    }

    @usableFromInline func updateLabel(on _: Resource) {
      // TODO: implement.
    }

    @usableFromInline func updatePurgeableState(for _: Resource, to _: ResourcePurgeableState?) -> ResourcePurgeableState {
      return .nonDiscardable // TODO: implement.
    }

    @usableFromInline
    func argumentBufferPath(at index: Int, stages _: RenderStages) -> ResourceBindingPath {
      return ResourceBindingPath(argumentBuffer: UInt32(index))
    }

    // MARK: - SpecificRenderBackend conformance

    static var requiresResourceResidencyTracking: Bool {
      return false
    }

    func fillVisibleFunctionTable(_: VisibleFunctionTable, storage _: Void, firstUseCommandIndex _: Int, resourceMap _: VulkanPersistentResourceRegistry) async {
      preconditionFailure()
    }

    func fillIntersectionFunctionTable(_: IntersectionFunctionTable, storage _: Void, firstUseCommandIndex _: Int, resourceMap _: VulkanPersistentResourceRegistry) async {
      preconditionFailure()
    }

    func makeTransientRegistry(index: Int, inflightFrameCount: Int, queue: Queue) -> VulkanTransientResourceRegistry {
      return VulkanTransientResourceRegistry(device: device, inflightFrameCount: inflightFrameCount, queue: queue, transientRegistryIndex: index, persistentRegistry: resourceRegistry)
    }

    func makeQueue(renderGraphQueue _: Queue) -> VulkanQueue {
      return VulkanQueue(backend: self, device: device)
    }

    func makeSyncEvent(for queue: Queue) -> Event {
      var semaphoreTypeCreateInfo = VkSemaphoreTypeCreateInfo()
      semaphoreTypeCreateInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_TYPE_CREATE_INFO
      semaphoreTypeCreateInfo.initialValue = 0
      semaphoreTypeCreateInfo.semaphoreType = VK_SEMAPHORE_TYPE_TIMELINE

      var semaphore: VkSemaphore? = nil
      withUnsafePointer(to: semaphoreTypeCreateInfo) { semaphoreTypeCreateInfo in
        var semaphoreCreateInfo = VkSemaphoreCreateInfo()
        semaphoreCreateInfo.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO
        semaphoreCreateInfo.pNext = UnsafeRawPointer(semaphoreTypeCreateInfo)
        vkCreateSemaphore(self.device.vkDevice, &semaphoreCreateInfo, nil, &semaphore)
      }
      queueSyncSemaphores[Int(queue.index)] = semaphore
      return semaphore!
    }

    func syncEvent(for queue: Queue) -> VkSemaphore? {
      return queueSyncSemaphores[Int(queue.index)]
    }

    func freeSyncEvent(for queue: Queue) {
      assert(queueSyncSemaphores[Int(queue.index)] != nil)
      vkDestroySemaphore(device.vkDevice, queueSyncSemaphores[Int(queue.index)], nil)
      queueSyncSemaphores[Int(queue.index)] = nil
    }

    func didCompleteCommand(_: UInt64, queue _: Queue, context _: RenderGraphContextImpl<VulkanBackend>) {
      VulkanEventRegistry.instance.clearCompletedEvents()
    }
  }

#else

  @available(*, unavailable)
  typealias VulkanBackend = UnavailableBackend

#endif // canImport(Vulkan)
