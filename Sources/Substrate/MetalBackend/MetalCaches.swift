//
//  Caches.swift
//  MetalRenderer
//
//  Created by Thomas Roughton on 24/12/17.
//

#if canImport(Metal)

@preconcurrency import Metal
import SubstrateUtilities

final actor MetalFunctionCache {
    let library: MTLLibrary
    private var functionCache = [FunctionDescriptor : MTLFunction]()
    private var functionTasks = [FunctionDescriptor : Task<Void, Error>]()
    
    init(library: MTLLibrary) {
        self.library = library
    }
    
    func function(for functionDescriptor: FunctionDescriptor) async -> MTLFunction? {
        if let function = self.functionCache[functionDescriptor] {
            return function
        }
        
        let functionTask: Task<Void, Error>
        if let task = self.functionTasks[functionDescriptor] {
            functionTask = task
        } else {
            functionTask = Task {
                let function = try await self.library.makeFunction(name: functionDescriptor.name, constantValues: functionDescriptor.constants.map { MTLFunctionConstantValues($0) } ?? MTLFunctionConstantValues())
                self.functionCache[functionDescriptor] = function
            }
            self.functionTasks[functionDescriptor] = functionTask
        }
        
        do {
            _ = try await functionTask.value
            return self.functionCache[functionDescriptor]!
        } catch {
            print("MetalRenderGraph: Error creating function named \(functionDescriptor.name)\(functionDescriptor.constants.map { " with constants \($0)" } ?? ""): \(error)")
            return nil
        }
    }
}

final class MetalRenderPipelineState: RenderPipelineState {
    let mtlState: MTLRenderPipelineState
    
    init(descriptor: RenderPipelineDescriptor, state: MTLRenderPipelineState, reflection: PipelineReflection) {
        self.mtlState = state
        super.init(descriptor: descriptor, state: OpaquePointer(Unmanaged.passUnretained(state).toOpaque()), reflection: reflection)
    }
}

final class MetalComputePipelineState: ComputePipelineState {
    let mtlState: MTLComputePipelineState
    
    init(descriptor: ComputePipelineDescriptor, state: MTLComputePipelineState, reflection: PipelineReflection) {
        self.mtlState = state
        super.init(descriptor: descriptor, state: OpaquePointer(Unmanaged.passUnretained(state).toOpaque()), reflection: reflection, threadExecutionWidth: state.threadExecutionWidth)
    }
}

final class MetalDepthStencilState: DepthStencilState {
    let mtlState: MTLDepthStencilState
    
    init(descriptor: DepthStencilDescriptor, state: MTLDepthStencilState) {
        self.mtlState = state
        super.init(descriptor: descriptor, state: OpaquePointer(Unmanaged.passUnretained(state).toOpaque()))
    }
}

final actor MetalRenderPipelineCache {
    let device: MTLDevice
    let functionCache: MetalFunctionCache
    private var renderStates = [RenderPipelineDescriptor : RenderPipelineState]()
    private var renderReflection = [RenderPipelineDescriptor: MetalPipelineReflection]()
    private var renderStateTasks = [RenderPipelineDescriptor : Task<Void, Error>]()
    
    init(device: MTLDevice, functionCache: MetalFunctionCache) {
        self.device = device
        self.functionCache = functionCache
    }
    
    public subscript(descriptor: RenderPipelineDescriptor) -> RenderPipelineState? {
        get async {
            if let state = self.renderStates[descriptor] {
                return state
            }
            
            let renderStateTask: Task<Void, Error>
            if let task = self.renderStateTasks[descriptor] {
                renderStateTask = task
            } else {
                renderStateTask = Task {
                    guard let mtlDescriptor = await MTLRenderPipelineDescriptor(descriptor, functionCache: self.functionCache) else {
                        return
                    }
                    
                    let (state, reflection) = try await self.device.makeRenderPipelineState(descriptor: mtlDescriptor, options: [.bufferTypeInfo])
                    
                    // TODO: can we retrieve the thread execution width for render pipelines?
                    let pipelineReflection = MetalPipelineReflection(threadExecutionWidth: 4, vertexFunction: mtlDescriptor.vertexFunction!, fragmentFunction: mtlDescriptor.fragmentFunction, renderState: state, renderReflection: reflection!)
                    
                    self.renderStates[descriptor] = RenderPipelineState(descriptor: descriptor, state: OpaquePointer(Unmanaged.passUnretained(state).toOpaque()))
                    if self.renderReflection[descriptor] == nil {
                        self.renderReflection[descriptor] = pipelineReflection
                    }
                }
                
                self.renderStateTasks[descriptor] = renderStateTask
            }
            
            do {
                _ = try await renderStateTask.value
                return self.renderStates[descriptor]
            } catch {
                print("MetalRenderGraph: Error creating render pipeline state for descriptor \(descriptor): \(error)")
                return nil
            }
        }
    }
    
    public func reflection(descriptor pipelineDescriptor: RenderPipelineDescriptor) async -> MetalPipelineReflection? {
        if let reflection = self.renderReflection[pipelineDescriptor] {
            return reflection
        }
        
        guard await self[pipelineDescriptor] != nil else {
            return nil
        }
        
        return await self.reflection(descriptor: pipelineDescriptor)
    }
    
}

final actor MetalComputePipelineCache {
    struct CacheKey: Hashable {
        var descriptor: ComputePipelineDescriptor
        var threadgroupSizeIsMultipleOfThreadExecutionWidth: Bool
    }
    
    let device: MTLDevice
    let functionCache: MetalFunctionCache
    private var computeStates = [CacheKey: MTLComputePipelineState]()
    private var computeReflection = [ComputePipelineDescriptor: (MetalPipelineReflection, Int)]()
    private var computeStateTasks = [CacheKey : Task<Void, Error>]()
    
    init(device: MTLDevice, functionCache: MetalFunctionCache) {
        self.device = device
        self.functionCache = functionCache
    }
    
    public subscript(descriptor: ComputePipelineDescriptor) -> ComputePipelineState? {
        get async {
            // Figure out whether the thread group size is always a multiple of the thread execution width and set the optimisation hint appropriately.
            let cacheKey = CacheKey(descriptor: descriptor, threadgroupSizeIsMultipleOfThreadExecutionWidth: threadgroupSizeIsMultipleOfThreadExecutionWidth)
            
            if let state = self.computeStates[cacheKey] {
                return state
            }
            
            let computeStateTask: Task<Void, Error>
            if let task = self.computeStateTasks[cacheKey] {
                computeStateTask = task
            } else {
                computeStateTask = Task {
                    guard let function = await self.functionCache.function(for: descriptor.function) else {
                        return
                    }
                    
                    let mtlDescriptor = MTLComputePipelineDescriptor()
                    mtlDescriptor.computeFunction = function
                    mtlDescriptor.threadGroupSizeIsMultipleOfThreadExecutionWidth = threadgroupSizeIsMultipleOfThreadExecutionWidth
                    
                    if !descriptor.linkedFunctions.isEmpty, #available(iOS 14.0, macOS 11.0, *) {
                        var functions = [MTLFunction]()
                        for functionDescriptor in descriptor.linkedFunctions {
                            if let function = await self.functionCache.function(for: functionDescriptor) {
                                functions.append(function)
                            }
                        }
                        let linkedFunctions = MTLLinkedFunctions()
                        linkedFunctions.functions = functions
                        mtlDescriptor.linkedFunctions = linkedFunctions
                    }
                    
                    let (state, reflection) = try await self.device.makeComputePipelineState(descriptor: mtlDescriptor, options: [.bufferTypeInfo])
                    
                    let pipelineReflection = MetalPipelineReflection(threadExecutionWidth: state.threadExecutionWidth, function: mtlDescriptor.computeFunction!, computeState: state, computeReflection: reflection!)
                    
                    self.computeStates[cacheKey] = state
                    if self.computeReflection[descriptor] == nil {
                        self.computeReflection[descriptor] = (pipelineReflection, pipelineReflection.threadExecutionWidth)
                    }
                }
                self.computeStateTasks[cacheKey] = computeStateTask
            }
            
            do {
                _ = try await computeStateTask.value
                return self.computeStates[cacheKey]
            } catch {
                print("MetalRenderGraph: Error creating compute pipeline state for descriptor \(descriptor): \(error)")
                return nil
            }
        }
    }
    
    public func reflection(for pipelineDescriptor: ComputePipelineDescriptor) async -> (MetalPipelineReflection, Int)? {
        if let reflection = self.computeReflection[pipelineDescriptor] {
            return reflection
        }
        
        guard await self[pipelineDescriptor] != nil else {
            return nil
        }
        return await self.reflection(for: pipelineDescriptor)
    }
}

final actor MetalDepthStencilStateCache {
    struct RenderPipelineFunctionNames : Hashable {
        var vertexFunction : String
        var fragmentFunction : String
    }
    
    let device: MTLDevice
    let defaultDepthState : MTLDepthStencilState
    private var depthStates: [MetalDepthStencilState]
    
    init(device: MTLDevice) {
        self.device = device
        let defaultDepthDescriptor = DepthStencilDescriptor()
        let mtlDescriptor = MTLDepthStencilDescriptor(defaultDepthDescriptor)
        let defaultDepthState = self.device.makeDepthStencilState(descriptor: mtlDescriptor)!
        self.defaultDepthState = defaultDepthState
        self.depthStates = [.init(descriptor: defaultDepthDescriptor, state: defaultDepthState)]
    }
    
    public subscript(descriptor: DepthStencilDescriptor) -> DepthStencilState {
        if let state = self.depthStates.first(where: { $0.descriptor == descriptor }) {
            return state
        }
        
        let mtlDescriptor = MTLDepthStencilDescriptor(descriptor)
        let mtlState = self.device.makeDepthStencilState(descriptor: mtlDescriptor)!
        let state = MetalDepthStencilState(descriptor: descriptor, state: mtlState)
        self.depthStates.append(state)
        
        return state
    }
}

final class MetalArgumentEncoderCache {
    let device: MTLDevice
    private var cache: [ArgumentBufferDescriptor: MTLArgumentEncoder]
    let lock = SpinLock()
    
    init(device: MTLDevice) {
        self.device = device
        self.cache = [:]
    }
    
    deinit {
        self.lock.deinit()
    }
    
    public subscript(descriptor: ArgumentBufferDescriptor) -> MTLArgumentEncoder {
        return self.lock.withLock {
            if let encoder = self.cache[descriptor] {
                return encoder
            }
            
            let arguments = descriptor.argumentDescriptors
            let encoder = self.device.makeArgumentEncoder(arguments: arguments)
            self.cache[descriptor] = encoder
            return encoder!
        }
    }
}

final class MetalStateCaches {
    let device : MTLDevice
    
    var libraryURL : URL?
    var loadedLibraryModificationDate : Date = .distantPast
    
    var functionCache: MetalFunctionCache
    var renderPipelineCache: MetalRenderPipelineCache
    var computePipelineCache: MetalComputePipelineCache
    let depthStencilCache: MetalDepthStencilStateCache
    let argumentEncoderCache: MetalArgumentEncoderCache
    
    public init(device: MTLDevice, libraryPath: String?) {
        self.device = device
        let library: MTLLibrary
        if let libraryPath = libraryPath {
            var libraryURL = URL(fileURLWithPath: libraryPath)
            
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: libraryPath, isDirectory: &isDirectory), isDirectory.boolValue {
                #if os(macOS) || targetEnvironment(macCatalyst)
                libraryURL = libraryURL.appendingPathComponent(device.isAppleSiliconGPU ? "Library-macOSAppleSilicon.metallib" : "Library-macOS.metallib")
                #else
                libraryURL = libraryURL.appendingPathComponent("Library-iOS.metallib")
                #endif
            }
            
            library = try! device.makeLibrary(filepath: libraryURL.path)
            self.libraryURL = libraryURL
            self.loadedLibraryModificationDate = try! libraryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
        } else {
            library = device.makeDefaultLibrary()!
        }
        
        self.functionCache = MetalFunctionCache(library: library)
        self.renderPipelineCache = .init(device: self.device, functionCache: functionCache)
        self.computePipelineCache = .init(device: self.device, functionCache: functionCache)
        self.depthStencilCache = .init(device: self.device)
        self.argumentEncoderCache = .init(device: self.device)
    }
    
    func checkForLibraryReload() async {
        self.libraryURL?.removeCachedResourceValue(forKey: .contentModificationDateKey)
        
        guard let libraryURL = self.libraryURL else { return }
        if FileManager.default.fileExists(atPath: libraryURL.path),
           let currentModificationDate = try? libraryURL.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           currentModificationDate > self.loadedLibraryModificationDate {
            
            for queue in QueueRegistry.allQueues {
                await queue.waitForCommandCompletion(queue.lastSubmittedCommand) // Wait for all commands to finish on all queues.
            }
            
            // Metal won't pick up the changes if we use the makeLibrary(filePath:) initialiser,
            // so we have to load into a DispatchData instead.
            guard let data = try? Data(contentsOf: libraryURL) else {
                return
            }
            
            guard let library = data.withUnsafeBytes({ bytes -> MTLLibrary? in
                let dispatchData = DispatchData(bytes: bytes)
                return try? device.makeLibrary(data: dispatchData as __DispatchData)
            }) else { return }
            
            
            self.functionCache = MetalFunctionCache(library: library)
            self.renderPipelineCache = .init(device: self.device, functionCache: functionCache)
            self.computePipelineCache = .init(device: self.device, functionCache: functionCache)
            
            VisibleFunctionTableRegistry.instance.markAllAsUninitialised()
            IntersectionFunctionTableRegistry.instance.markAllAsUninitialised()
            
            self.loadedLibraryModificationDate = currentModificationDate
        }
    }
    

    public func renderPipelineState(descriptor pipelineDescriptor: RenderPipelineDescriptor) async -> RenderPipelineState? {
        return await self.renderPipelineCache[pipelineDescriptor]
    }
    
    public func computePipelineState(descriptor: ComputePipelineDescriptor) async -> ComputePipelineState? {
        return await self.computePipelineCache[descriptor]
    }

    public func renderPipelineReflection(descriptor pipelineDescriptor: RenderPipelineDescriptor) async -> MetalPipelineReflection? {
        return await self.renderPipelineCache.reflection(descriptor: pipelineDescriptor)
    }
    
    public func computePipelineReflection(descriptor: ComputePipelineDescriptor) async -> MetalPipelineReflection? {
        return await self.computePipelineCache.reflection(for: descriptor)?.0
    }
}

#endif // canImport(Metal)
