//
//  VulkanResourceRegistry.swift
//  SubstratePackageDescription
//
//  Created by Joseph Bennett on 1/01/18.
//

#if canImport(Vulkan)
  import Dispatch
  @_implementationOnly import SubstrateCExtras
  import SubstrateUtilities
  import Vulkan

  class VulkanHeap {} // Just a stub for now.

  struct VkBufferReference {
    let _buffer: Unmanaged<VulkanBuffer>
    let offset: Int

    var buffer: VulkanBuffer {
      return _buffer.takeUnretainedValue()
    }

    var resource: VulkanBuffer {
      return _buffer.takeUnretainedValue()
    }

    init(buffer: Unmanaged<VulkanBuffer>, offset: Int) {
      _buffer = buffer
      self.offset = offset
    }
  }

  // Must be a POD type and trivially copyable/movable
  struct VkImageReference {
    var _image: Unmanaged<VulkanImage>!

    var image: VulkanImage {
      return _image.takeUnretainedValue()
    }

    var resource: VulkanImage {
      return image
    }

    init(windowTexture _: ()) {
      _image = nil
    }

    init(image: Unmanaged<VulkanImage>) {
      _image = image
    }
  }

  final actor VulkanPersistentResourceRegistry: BackendPersistentResourceRegistry {
    typealias Backend = VulkanBackend

    let device: VulkanDevice
    let vmaAllocator: VmaAllocator

    let descriptorPool: VulkanDescriptorPool

    let heapReferences = PersistentResourceMap<Heap, VulkanHeap>()
    let textureReferences = PersistentResourceMap<Texture, VkImageReference>()
    let bufferReferences = PersistentResourceMap<Buffer, VkBufferReference>()
    let argumentBufferReferences = PersistentResourceMap<ArgumentBuffer, VulkanArgumentBuffer>()

    var samplers = [SamplerDescriptor: VkSampler]()

    public init(instance: VulkanInstance, device: VulkanDevice) {
      self.device = device

      var allocatorInfo = VmaAllocatorCreateInfo(flags: 0, physicalDevice: device.vkDevice, device: device.vkDevice, preferredLargeHeapBlockSize: 0, pAllocationCallbacks: nil, pDeviceMemoryCallbacks: nil, frameInUseCount: 0, pHeapSizeLimit: nil, pVulkanFunctions: nil, pRecordSettings: nil, instance: instance.instance,
                                                 vulkanApiVersion: VulkanVersion.apiVersion.value,
                                                 pTypeExternalMemoryHandleTypes: nil)
      allocatorInfo.device = device.vkDevice
      allocatorInfo.physicalDevice = device.physicalDevice.vkDevice

      var allocator: VmaAllocator? = nil
      vmaCreateAllocator(&allocatorInfo, &allocator).check()
      vmaAllocator = allocator!

      descriptorPool = VulkanDescriptorPool(device: device, incrementalRelease: true)

      VulkanEventRegistry.instance.device = self.device.vkDevice
    }

    deinit {
      self.textureReferences.deinit()
      self.bufferReferences.deinit()
      self.argumentBufferReferences.deinit()
    }

    @discardableResult
    public nonisolated func allocateTexture(_ texture: Texture) -> VkImageReference? {
      precondition(texture._usesPersistentRegistry)

      if texture.flags.contains(.windowHandle) {
        // Reserve a slot in texture references so we can later insert the texture reference in a thread-safe way, but don't actually allocate anything yet
        textureReferences[texture] = VkImageReference(windowTexture: ())
        return nil
      }

      let usage = VkImageUsageFlagBits(texture.descriptor.usageHint, pixelFormat: texture.descriptor.pixelFormat)

      let initialLayout = texture.descriptor.storageMode != .private ? VK_IMAGE_LAYOUT_PREINITIALIZED : VK_IMAGE_LAYOUT_UNDEFINED
      let sharingMode = VulkanSharingMode(usage: usage, device: device) // FIXME: can we infer this?

      // NOTE: all synchronisation is managed through the per-queue waitIndices associated with the resource.

      let descriptor = VulkanImageDescriptor(texture.descriptor, usage: usage, sharingMode: sharingMode, initialLayout: initialLayout)

      var allocInfo = VmaAllocationCreateInfo(storageMode: texture.descriptor.storageMode, cacheMode: texture.descriptor.cacheMode)
      var image: VkImage? = nil
      var allocation: VmaAllocation? = nil
      descriptor.withImageCreateInfo(device: device) { info in
        var info = info
        vmaCreateImage(self.vmaAllocator, &info, &allocInfo, &image, &allocation, nil).check()
      }

      let vkImage = VulkanImage(device: device, image: image!, allocator: vmaAllocator, allocation: allocation!, descriptor: descriptor)

      if let label = texture.label {
        vkImage.label = label
      }

      assert(textureReferences[texture] == nil)
      let imageReference = VkImageReference(image: Unmanaged.passRetained(vkImage))
      textureReferences[texture] = imageReference

      return imageReference
    }

    @discardableResult
    public nonisolated func allocateBuffer(_ buffer: Buffer) -> VkBufferReference? {
      precondition(buffer._usesPersistentRegistry)

      let usage = VkBufferUsageFlagBits(buffer.descriptor.usageHint)

      let sharingMode = VulkanSharingMode(usage: usage, device: device) // FIXME: can we infer this?

      // NOTE: all synchronisation is managed through the per-queue waitIndices associated with the resource.
      let descriptor = VulkanBufferDescriptor(buffer.descriptor, usage: usage, sharingMode: sharingMode)

      var allocInfo = VmaAllocationCreateInfo(storageMode: buffer.descriptor.storageMode, cacheMode: buffer.descriptor.cacheMode)
      var vkBuffer: VkBuffer? = nil
      var allocation: VmaAllocation? = nil
      var allocationInfo = VmaAllocationInfo()
      descriptor.withBufferCreateInfo(device: device) { info in
        var info = info
        vmaCreateBuffer(self.vmaAllocator, &info, &allocInfo, &vkBuffer, &allocation, &allocationInfo).check()
      }

      let vulkanBuffer = VulkanBuffer(device: device, buffer: vkBuffer!, allocator: vmaAllocator, allocation: allocation!, allocationInfo: allocationInfo, descriptor: descriptor)

      let vkBufferReference = VkBufferReference(buffer: Unmanaged<VulkanBuffer>.passRetained(vulkanBuffer), offset: 0)

      if let label = buffer.label {
        vulkanBuffer.label = label
      }

      assert(bufferReferences[buffer] == nil)
      bufferReferences[buffer] = vkBufferReference

      return vkBufferReference
    }

    @discardableResult
    nonisolated func allocateArgumentBufferIfNeeded(_ argumentBuffer: ArgumentBuffer) -> VulkanArgumentBuffer {
      if let vkArgumentBuffer = argumentBufferReferences[argumentBuffer] {
        return vkArgumentBuffer
      }

      let setLayout = Unmanaged<VulkanDescriptorSetLayout>.fromOpaque(argumentBuffer._handle).takeUnretainedValue()
      let set = descriptorPool.allocateSet(layout: setLayout.vkLayout)

      let buffer = VulkanArgumentBuffer(device: device,
                                        layout: setLayout,
                                        descriptorSet: set)

      argumentBufferReferences[argumentBuffer] = buffer

      return buffer
    }

    public nonisolated func importExternalResource(_ resource: Resource, backingResource: Any) {
      if let texture = Texture(resource) {
        textureReferences[texture] = VkImageReference(image: Unmanaged.passRetained(backingResource as! VulkanImage))
      } else if let buffer = Buffer(resource) {
        bufferReferences[buffer] = VkBufferReference(buffer: Unmanaged.passRetained(backingResource as! VulkanBuffer), offset: 0)
      }
    }

    public nonisolated subscript(texture: Texture) -> VkImageReference? {
      return textureReferences[texture]
    }

    public nonisolated subscript(buffer: Buffer) -> VkBufferReference? {
      return bufferReferences[buffer]
    }

    public nonisolated subscript(argumentBuffer: ArgumentBuffer) -> VulkanArgumentBuffer? {
      return argumentBufferReferences[argumentBuffer]
    }

    public subscript(sampler: SamplerDescriptor) -> VkSampler {
      get async {
        if let vkSampler = samplers[sampler] {
          return vkSampler
        }

        var samplerCreateInfo = VkSamplerCreateInfo(descriptor: sampler)

        var vkSampler: VkSampler? = nil
        vkCreateSampler(device.vkDevice, &samplerCreateInfo, nil, &vkSampler)

        samplers[sampler] = vkSampler!

        return vkSampler!
      }
    }

    nonisolated func prepareMultiframeBuffer(_: Buffer, frameIndex _: UInt64) {}

    nonisolated func prepareMultiframeTexture(_ texture: Texture, frameIndex: UInt64) {
      if let image = self[texture] {
        image.image.computeFrameLayouts(resource: Resource(texture), usages: texture.usages, preserveLastLayout: texture.stateFlags.contains(.initialised), frameIndex: frameIndex)
      }
    }

    nonisolated func dispose(resource: Resource) {
      switch resource.type {
      case .buffer:
        let buffer = Buffer(resource)!
        if let vkBuffer = bufferReferences.removeValue(forKey: buffer) {
          // TODO: Allow future allocations to alias against this resource, even if it may still be retained by a command buffer.
          CommandEndActionManager.enqueue(action: .release(Unmanaged.fromOpaque(vkBuffer._buffer.toOpaque())))
        }
      case .texture:
        let texture = Texture(resource)!
        if let vkTexture = textureReferences.removeValue(forKey: texture) {
          if texture.flags.contains(.windowHandle) {
            return
          }
          // TODO: Allow future allocations to alias against this resource, even if it may still be retained by a command buffer.
          CommandEndActionManager.enqueue(action: .release(Unmanaged.fromOpaque(vkTexture._image.toOpaque())))
        }

      case .heap:
        let heap = Heap(resource)!
        if let vkHeap = heapReferences.removeValue(forKey: heap) {
          CommandEndActionManager.enqueue(action: .release(Unmanaged.passRetained(vkHeap)))
        }

      case .argumentBuffer:
        let buffer = ArgumentBuffer(resource)!
        if let vkBuffer = argumentBufferReferences.removeValue(forKey: buffer) {
          // TODO: Allow future allocations to alias against this resource, even if it may still be retained by a command buffer.
          CommandEndActionManager.enqueue(action: .release(Unmanaged.passRetained(vkBuffer)))
        }

      default:
        preconditionFailure("dispose(resource:): Unhandled resource type \(resource.type)")
      }
    }

    nonisolated subscript(_: AccelerationStructure) -> AnyObject? {
      return nil
    }

    nonisolated subscript(_: VisibleFunctionTable) -> Void? {
      return nil
    }

    nonisolated subscript(_: IntersectionFunctionTable) -> Void? {
      return nil
    }

    func allocateVisibleFunctionTable(_: VisibleFunctionTable) -> Void? {
      return nil
    }

    func allocateIntersectionFunctionTable(_: IntersectionFunctionTable) -> Void? {
      return nil
    }

    nonisolated func cycleFrames() {
      // TODO: we should dispose command buffer resources here.
    }
  }

  final class VulkanTransientResourceRegistry: BackendTransientResourceRegistry {
    typealias Backend = VulkanBackend

    let queue: Queue
    let persistentRegistry: VulkanPersistentResourceRegistry
    let transientRegistryIndex: Int
    var accessLock = SpinLock()

    private var textureReferences: TransientResourceMap<Texture, VkImageReference>
    private var bufferReferences: TransientResourceMap<Buffer, VkBufferReference>
    private var argumentBufferReferences: TransientResourceMap<ArgumentBuffer, VulkanArgumentBuffer>

    var textureWaitEvents: TransientResourceMap<Texture, ContextWaitEvent>
    var bufferWaitEvents: TransientResourceMap<Buffer, ContextWaitEvent>
    var historyBufferResourceWaitEvents = [Resource: ContextWaitEvent]()

    private var heapResourceUsageFences = [Resource: [FenceDependency]]()
    private var heapResourceDisposalFences = [Resource: [FenceDependency]]()

    private let frameSharedBufferAllocator: VulkanTemporaryBufferAllocator
    private let frameSharedWriteCombinedBufferAllocator: VulkanTemporaryBufferAllocator

    private let frameManagedBufferAllocator: VulkanTemporaryBufferAllocator
    private let frameManagedWriteCombinedBufferAllocator: VulkanTemporaryBufferAllocator

    private let stagingTextureAllocator: VulkanPoolResourceAllocator
    private let historyBufferAllocator: VulkanPoolResourceAllocator
    private let privateAllocator: VulkanPoolResourceAllocator

    private let descriptorPools: [VulkanDescriptorPool]

    public let inflightFrameCount: Int
    private var descriptorPoolIndex: Int = 0
    private var frameIndex: UInt64 = 0

    var windowReferences = [Texture: VulkanSwapchain]()
    public private(set) var frameSwapchains: [VulkanSwapchain] = []

    public init(device: VulkanDevice, inflightFrameCount: Int, queue: Queue, transientRegistryIndex: Int, persistentRegistry: VulkanPersistentResourceRegistry) {
      self.queue = queue
      self.inflightFrameCount = inflightFrameCount
      self.transientRegistryIndex = transientRegistryIndex
      self.persistentRegistry = persistentRegistry

      textureReferences = .init(transientRegistryIndex: transientRegistryIndex)
      bufferReferences = .init(transientRegistryIndex: transientRegistryIndex)
      argumentBufferReferences = .init(transientRegistryIndex: transientRegistryIndex)

      textureWaitEvents = .init(transientRegistryIndex: transientRegistryIndex)
      bufferWaitEvents = .init(transientRegistryIndex: transientRegistryIndex)

      frameSharedBufferAllocator = VulkanTemporaryBufferAllocator(device: device, allocator: persistentRegistry.vmaAllocator, storageMode: .shared, cacheMode: .defaultCache, inflightFrameCount: inflightFrameCount)
      frameSharedWriteCombinedBufferAllocator = VulkanTemporaryBufferAllocator(device: device, allocator: persistentRegistry.vmaAllocator, storageMode: .shared, cacheMode: .writeCombined, inflightFrameCount: inflightFrameCount)

      frameManagedBufferAllocator = VulkanTemporaryBufferAllocator(device: device, allocator: persistentRegistry.vmaAllocator, storageMode: .managed, cacheMode: .defaultCache, inflightFrameCount: inflightFrameCount)
      frameManagedWriteCombinedBufferAllocator = VulkanTemporaryBufferAllocator(device: device, allocator: persistentRegistry.vmaAllocator, storageMode: .managed, cacheMode: .writeCombined, inflightFrameCount: inflightFrameCount)

      stagingTextureAllocator = VulkanPoolResourceAllocator(device: device, allocator: persistentRegistry.vmaAllocator, numFrames: inflightFrameCount)
      historyBufferAllocator = VulkanPoolResourceAllocator(device: device, allocator: persistentRegistry.vmaAllocator, numFrames: 1)
      privateAllocator = VulkanPoolResourceAllocator(device: device, allocator: persistentRegistry.vmaAllocator, numFrames: 1)

      descriptorPools = (0 ..< inflightFrameCount).map { _ in VulkanDescriptorPool(device: device, incrementalRelease: false) }

      prepareFrame()
    }

    deinit {
      self.textureReferences.deinit()
      self.bufferReferences.deinit()
      self.argumentBufferReferences.deinit()

      self.textureWaitEvents.deinit()
      self.bufferWaitEvents.deinit()
    }

    public func prepareFrame() {
      VulkanEventRegistry.instance.clearCompletedEvents()

      textureReferences.prepareFrame()
      bufferReferences.prepareFrame()
      argumentBufferReferences.prepareFrame()

      textureWaitEvents.prepareFrame()
      bufferWaitEvents.prepareFrame()

      descriptorPools[descriptorPoolIndex].resetDescriptorPool()
    }

    public func registerWindowTexture(for texture: Texture, swapchain: Any) {
      windowReferences[texture] = (swapchain as! VulkanSwapchain)
    }

    func allocatorForBuffer(storageMode: StorageMode, cacheMode: CPUCacheMode, flags: ResourceFlags) -> VulkanBufferAllocator {
      assert(!flags.contains(.persistent))

      if flags.contains(.historyBuffer) {
        assert(storageMode == .private)
        return historyBufferAllocator
      }
      switch storageMode {
      case .private:
        return privateAllocator
      case .managed:
        switch cacheMode {
        case .writeCombined:
          return frameManagedWriteCombinedBufferAllocator
        case .defaultCache:
          return frameManagedBufferAllocator
        }

      case .shared:
        switch cacheMode {
        case .writeCombined:
          return frameSharedWriteCombinedBufferAllocator
        case .defaultCache:
          return frameSharedBufferAllocator
        }
      }
    }

    func allocatorForImage(storageMode: StorageMode, cacheMode _: CPUCacheMode, flags: ResourceFlags) -> VulkanImageAllocator {
      assert(!flags.contains(.persistent))

      if flags.contains(.historyBuffer) {
        assert(storageMode == .private)
        return historyBufferAllocator
      }

      if storageMode != .private {
        return stagingTextureAllocator
      } else {
        return privateAllocator
      }
    }

    static func isAliasedHeapResource(resource _: Resource) -> Bool {
      return false
    }

    @discardableResult
    public func allocateTexture(_ texture: Texture, forceGPUPrivate: Bool) -> VkImageReference {
      if texture.flags.contains(.windowHandle) {
        textureReferences[texture] = VkImageReference(windowTexture: ()) // We retrieve the swapchain image later.
        return VkImageReference(windowTexture: ())
      }

      var imageUsage: VkImageUsageFlagBits = []

      let canBeTransient = texture.usages.allSatisfy { $0.type.isRenderTarget }
      if canBeTransient {
        imageUsage.formUnion(VK_IMAGE_USAGE_TRANSIENT_ATTACHMENT_BIT)
      }
      let isDepthOrStencil = texture.descriptor.pixelFormat.isDepth || texture.descriptor.pixelFormat.isStencil

      for usage in texture.usages {
        switch usage.type {
        case .shaderRead:
          imageUsage.formUnion(VK_IMAGE_USAGE_SAMPLED_BIT)
        case .shaderWrite, .shaderReadWrite:
          imageUsage.formUnion(VK_IMAGE_USAGE_STORAGE_BIT)
        case .colorAttachmentWrite, .depthStencilAttachmentWrite:
          imageUsage.formUnion(isDepthOrStencil ? VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT : VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT)
        case .inputAttachment, .indirectBuffer:
          imageUsage.formUnion(VK_IMAGE_USAGE_INPUT_ATTACHMENT_BIT)
        case .blitSource:
          imageUsage.formUnion(VK_IMAGE_USAGE_TRANSFER_SRC_BIT)
        case .blitDestination:
          imageUsage.formUnion(VK_IMAGE_USAGE_TRANSFER_DST_BIT)
        default:
          break
        }
      }

      var descriptor = texture.descriptor
      let flags = texture.flags

      if forceGPUPrivate {
        descriptor.storageMode = .private
      }

      let allocator = allocatorForImage(storageMode: descriptor.storageMode, cacheMode: descriptor.cacheMode, flags: flags)
      let (vkImage, events, waitEvent) = allocator.collectImage(descriptor: VulkanImageDescriptor(descriptor, usage: imageUsage, sharingMode: .exclusive, initialLayout: VK_IMAGE_LAYOUT_UNDEFINED))

      if let label = texture.label {
        vkImage.image.label = label
      }

      if texture._usesPersistentRegistry {
        precondition(texture.flags.contains(.historyBuffer))
        persistentRegistry.textureReferences[texture] = vkImage
        historyBufferResourceWaitEvents[Resource(texture)] = waitEvent
      } else {
        precondition(textureReferences[texture] == nil)
        textureReferences[texture] = vkImage
        textureWaitEvents[texture] = waitEvent
      }

      if !events.isEmpty {
        heapResourceUsageFences[Resource(texture)] = events
      }

      vkImage.image.computeFrameLayouts(resource: Resource(texture), usages: texture.usages, preserveLastLayout: false, frameIndex: frameIndex)

      return vkImage
    }

    @discardableResult
    public func allocateTextureView(_: Texture, resourceMap _: VulkanPersistentResourceRegistry) -> VkImageReference {
      fatalError("Unimplemented")
    }

    @MainActor
    private func createWindowHandleTexture(_ texture: Texture) {
      let swapchain = windowReferences.removeValue(forKey: texture)!
      frameSwapchains.append(swapchain)
      let image = swapchain.nextImage(descriptor: texture.descriptor)
      image.computeFrameLayouts(resource: Resource(texture), usages: texture.usages, preserveLastLayout: false, frameIndex: frameIndex)
      textureReferences[texture] = VkImageReference(image: Unmanaged.passUnretained(image))
    }

    @discardableResult
    public func allocateWindowHandleTexture(_ texture: Texture) async throws -> VkImageReference {
      precondition(texture.flags.contains(.windowHandle))

      if textureReferences[texture]!._image == nil {
        await createWindowHandleTexture(texture)
      }

      return textureReferences[texture]!
    }

    @discardableResult
    public func allocateBuffer(_ buffer: Buffer, forceGPUPrivate: Bool) -> VkBufferReference {
      // If this is a CPU-visible buffer, include the usage hints passed by the user.
      var bufferUsage: VkBufferUsageFlagBits = forceGPUPrivate ? [] : VkBufferUsageFlagBits(buffer.descriptor.usageHint)

      for usage in buffer.usages {
        switch usage.type {
        case .constantBuffer:
          bufferUsage.formUnion(VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT)
        case .shaderRead:
          bufferUsage.formUnion([VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT])
        case .shaderWrite:
          bufferUsage.formUnion([VK_BUFFER_USAGE_STORAGE_BUFFER_BIT])
        case .shaderReadWrite:
          bufferUsage.formUnion([VK_BUFFER_USAGE_STORAGE_BUFFER_BIT])
        case .vertexBuffer:
          bufferUsage.formUnion(VK_BUFFER_USAGE_VERTEX_BUFFER_BIT)
        case .indexBuffer:
          bufferUsage.formUnion(VK_BUFFER_USAGE_INDEX_BUFFER_BIT)
        case .blitSource:
          bufferUsage.formUnion(VK_BUFFER_USAGE_TRANSFER_SRC_BIT)
        case .blitDestination:
          bufferUsage.formUnion(VK_BUFFER_USAGE_TRANSFER_DST_BIT)
        default:
          break
        }
      }
      if bufferUsage.isEmpty, !forceGPUPrivate {
        bufferUsage = [VK_BUFFER_USAGE_TRANSFER_SRC_BIT, VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT, VK_BUFFER_USAGE_STORAGE_BUFFER_BIT]
      }

      var descriptor = buffer.descriptor

      if forceGPUPrivate {
        descriptor.storageMode = .private
      }

      let allocator = allocatorForBuffer(storageMode: forceGPUPrivate ? .private : buffer.descriptor.storageMode, cacheMode: buffer.descriptor.cacheMode, flags: buffer.flags)
      let (vkBuffer, events, waitSemaphore) = allocator.collectBuffer(descriptor: VulkanBufferDescriptor(descriptor, usage: bufferUsage, sharingMode: .exclusive))

      if let label = buffer.label {
        vkBuffer.buffer.label = label
      }

      if buffer._usesPersistentRegistry {
        precondition(buffer.flags.contains(.historyBuffer))
        persistentRegistry.bufferReferences[buffer] = vkBuffer
        historyBufferResourceWaitEvents[Resource(buffer)] = waitSemaphore
      } else {
        precondition(bufferReferences[buffer] == nil)
        bufferReferences[buffer] = vkBuffer
        bufferWaitEvents[buffer] = waitSemaphore
      }

      if !events.isEmpty {
        heapResourceUsageFences[Resource(buffer)] = events
      }

      return vkBuffer
    }

    @discardableResult
    public func allocateBufferIfNeeded(_ buffer: Buffer, forceGPUPrivate: Bool) -> VkBufferReference {
      if let vkBuffer = bufferReferences[buffer] {
        return vkBuffer
      }
      return allocateBuffer(buffer, forceGPUPrivate: forceGPUPrivate)
    }

    @discardableResult
    public func allocateTextureIfNeeded(_ texture: Texture, forceGPUPrivate: Bool, isStoredThisFrame _: Bool) -> VkImageReference {
      if let vkTexture = textureReferences[texture] {
        return vkTexture
      }
      return allocateTexture(texture, forceGPUPrivate: forceGPUPrivate)
    }

    @discardableResult
    func allocateArgumentBufferIfNeeded(_ argumentBuffer: ArgumentBuffer) -> VulkanArgumentBuffer {
      if let vkArgumentBuffer = argumentBufferReferences[argumentBuffer] {
        return vkArgumentBuffer
      }

      let layout = Unmanaged<VulkanDescriptorSetLayout>.fromOpaque(argumentBuffer.encoder!).takeUnretainedValue()
      let set = descriptorPools[descriptorPoolIndex].allocateSet(layout: layout.vkLayout)

      let vkArgumentBuffer = VulkanArgumentBuffer(device: persistentRegistry.device, layout: layout, descriptorSet: set)

      argumentBufferReferences[argumentBuffer] = vkArgumentBuffer

      return vkArgumentBuffer
    }

    public func importExternalResource(_ resource: Resource, backingResource: Any) {
      prepareFrame()
      if let texture = Texture(resource) {
        textureReferences[texture] = VkImageReference(image: Unmanaged.passRetained(backingResource as! VulkanImage))
      } else if let buffer = Buffer(resource) {
        bufferReferences[buffer] = VkBufferReference(buffer: Unmanaged.passRetained(backingResource as! VulkanBuffer), offset: 0)
      }
    }

    public subscript(texture: Texture) -> VkImageReference? {
      return textureReferences[texture]
    }

    public subscript(buffer: Buffer) -> VkBufferReference? {
      return bufferReferences[buffer]
    }

    public subscript(argumentBuffer: ArgumentBuffer) -> VulkanArgumentBuffer? {
      return argumentBufferReferences[argumentBuffer]
    }

    public func withHeapAliasingFencesIfPresent(for resourceHandle: Resource.Handle, perform: (inout [FenceDependency]) -> Void) {
      let resource = Resource(handle: resourceHandle)

      perform(&heapResourceUsageFences[resource, default: []])
    }

    func setDisposalFences(on resource: Resource, to events: [FenceDependency]) {
      assert(Self.isAliasedHeapResource(resource: Resource(resource)))
      heapResourceDisposalFences[Resource(resource)] = events
    }

    func disposeTexture(_ texture: Texture, waitEvent: ContextWaitEvent) {
      // We keep the reference around until the end of the frame since allocation/disposal is all processed ahead of time.

      let textureRef: VkImageReference?
      if texture._usesPersistentRegistry {
        precondition(texture.flags.contains(.historyBuffer))
        textureRef = persistentRegistry.textureReferences[texture]
        _ = textureRef?._image.retain() // since the persistent registry releases its resources unconditionally on dispose, but we want the allocator to have ownership of it.
      } else {
        textureRef = textureReferences[texture]
      }

      if let vkTexture = textureRef {
        if texture.flags.contains(.windowHandle) || texture.isTextureView {
          CommandEndActionManager.enqueue(action: .release(.fromOpaque(vkTexture._image.toOpaque())), after: waitEvent.waitValue, on: queue)
          return
        }

        var events: [FenceDependency] = []
        if Self.isAliasedHeapResource(resource: Resource(texture)) {
          events = heapResourceDisposalFences[Resource(texture)] ?? []
        }

        let allocator = allocatorForImage(storageMode: texture.descriptor.storageMode, cacheMode: texture.descriptor.cacheMode, flags: texture.flags)
        allocator.depositImage(vkTexture, events: events, waitSemaphore: waitEvent)
      }
    }

    func disposeBuffer(_ buffer: Buffer, waitEvent: ContextWaitEvent) {
      // We keep the reference around until the end of the frame since allocation/disposal is all processed ahead of time.

      let bufferRef: VkBufferReference?
      if buffer._usesPersistentRegistry {
        precondition(buffer.flags.contains(.historyBuffer))
        bufferRef = persistentRegistry.bufferReferences[buffer]
        _ = bufferRef?._buffer.retain() // since the persistent registry releases its resources unconditionally on dispose, but we want the allocator to have ownership of it.
      } else {
        bufferRef = bufferReferences[buffer]
      }

      if let vkBuffer = bufferRef {
        var events: [FenceDependency] = []
        if Self.isAliasedHeapResource(resource: Resource(buffer)) {
          events = heapResourceDisposalFences[Resource(buffer)] ?? []
        }

        let allocator = allocatorForBuffer(storageMode: buffer.descriptor.storageMode, cacheMode: buffer.descriptor.cacheMode, flags: buffer.flags)
        allocator.depositBuffer(vkBuffer, events: events, waitSemaphore: waitEvent)
      }
    }

    func disposeArgumentBuffer(_: ArgumentBuffer, waitEvent _: ContextWaitEvent) {
      // No-op; this should be managed by resetting the descriptor set pool.
      // FIXME: should we manage individual descriptor sets instead?
    }

    func registerInitialisedHistoryBufferForDisposal(resource: Resource) {
      assert(resource.flags.contains(.historyBuffer) && resource.stateFlags.contains(.initialised))
      resource.dispose() // This will dispose it in the RenderGraph persistent allocator, which will in turn call dispose here at the end of the frame.
    }

    func clearSwapchains() {
      frameSwapchains.removeAll(keepingCapacity: true)
    }

    func cycleFrames() {
      // Clear all transient resources at the end of the frame.
      bufferReferences.removeAll()
      argumentBufferReferences.removeAll()

      heapResourceUsageFences.removeAll(keepingCapacity: true)
      heapResourceDisposalFences.removeAll(keepingCapacity: true)

      frameSharedBufferAllocator.cycleFrames()
      frameSharedWriteCombinedBufferAllocator.cycleFrames()

      frameManagedBufferAllocator.cycleFrames()
      frameManagedWriteCombinedBufferAllocator.cycleFrames()

      stagingTextureAllocator.cycleFrames()
      historyBufferAllocator.cycleFrames()
      privateAllocator.cycleFrames()

      descriptorPoolIndex = (descriptorPoolIndex &+ 1) % inflightFrameCount
      frameIndex += 1
    }
  }

#endif // canImport(Vulkan)
