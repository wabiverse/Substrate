//
//  Target.swift
//  
//
//  Created by Thomas Roughton on 7/12/19.
//

import Foundation
import SPIRV_Cross

enum Target : Hashable, CaseIterable {
    case macOSMetal
    case iOSMetal
    case vulkan
    
    static var defaultTarget : Target {
#if os(iOS) || os(tvOS) || os(watchOS)
        return .iOSMetal
#elseif os(macOS)
        return .macOSMetal
#else
        return .vulkan
#endif
    }
    
    var spvcBackend : spvc_backend {
        switch self {
        case .macOSMetal, .iOSMetal:
            return SPVC_BACKEND_MSL
        case .vulkan:
            return SPVC_BACKEND_NONE
        }
    }
    
    var targetDefine : String {
        switch self {
        case .macOSMetal:
            return "TARGET_METAL_MACOS"
        case .iOSMetal:
            return "TARGET_METAL_IOS"
        case .vulkan:
            return "TARGET_VULKAN"
        }
    }
    
    var outputDirectory : String {
        switch self {
        case .macOSMetal:
            return "Metal"
        case .iOSMetal:
            return "Metal-iOS"
        case .vulkan:
            return "Vulkan"
        }
    }
    
    var spirvDirectory : String {
        switch self {
        case .vulkan:
            return self.outputDirectory
        default:
            return self.outputDirectory + "/SPIRV"
        }
    }
    
    var compiler : TargetCompiler? {
        switch self {
        case .macOSMetal, .iOSMetal:
            return MetalCompiler(target: self)
        case .vulkan:
            return nil // We've already compiled to SPIR-V, so there's nothing else to do.
        }
    }
}

enum CompilerError : Error {
    case shaderErrors
    case libraryGenerationFailed(Error)
}

protocol TargetCompiler {
    func compile(spirvCompilers: [SPIRVCompiler], to outputDirectory: URL, withDebugInformation debug: Bool) throws
}

final class MetalCompiler : TargetCompiler {
    let target: Target
    let driver : MetalDriver
    
    init(target: Target) {
        precondition(target == .macOSMetal || target == .iOSMetal)
        self.target = target
        self.driver = MetalDriver(target: target)!
    }
    
    private func makeMSLVersion(major: Int, minor: Int, patch: Int) -> UInt32 {
        return UInt32(major * 10000 + minor * 100 + patch)
    }
    
    func compile(spirvCompilers: [SPIRVCompiler], to outputDirectory: URL, withDebugInformation debug: Bool) throws {
        var airFiles = [URL]()
        var hadErrors = false
        
        let airDirectory = outputDirectory.appendingPathComponent("AIR")
        try FileManager.default.createDirectoryIfNeeded(at: airDirectory)
        
        for compiler in spirvCompilers where compiler.file.target == self.target {
            
            do {
                var options : spvc_compiler_options! = nil
                spvc_compiler_create_compiler_options(compiler.compiler, &options)
                
                spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, makeMSLVersion(major: 2, minor: 1, patch: 0))
                spvc_compiler_options_set_bool(options, SPVC_COMPILER_OPTION_MSL_ARGUMENT_BUFFERS, 1)
                spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_PLATFORM, self.target == .iOSMetal ? SPVC_MSL_PLATFORM_IOS.rawValue : SPVC_MSL_PLATFORM_MACOS.rawValue)
                
                spvc_compiler_install_compiler_options(compiler.compiler, options)
            }
            
            let outputFileName = compiler.file.sourceFile.renderPass + "-" + compiler.file.entryPoint.name
            
            let metalFileURL = outputDirectory.appendingPathComponent(outputFileName + ".metal")
            let airFileURL = airDirectory.appendingPathComponent(outputFileName + ".air")
            do {
                // Generate the compiled source unconditionally, since we need it to compute bindings for reflection.
                let compiledSource = try compiler.compiledSource()
                
                if airFileURL.needsGeneration(sourceFile: metalFileURL) {
                    try compiledSource.write(to: metalFileURL, atomically: false, encoding: .ascii)
                    try self.driver.compileToAIR(sourceFile: metalFileURL, destinationFile: airFileURL, withDebugInformation: debug).waitUntilExit()
                }
                airFiles.append(airFileURL)
            }
            catch {
                print("Error compiling file \(compiler.file):")
                print(error)
                hadErrors = true
            }
        }
        
        if hadErrors {
            throw CompilerError.shaderErrors
        }
        
        do {
            try self.driver.generateLibrary(airFiles: airFiles, outputLibrary: outputDirectory.appendingPathComponent("Library.metallib")).waitUntilExit()
        }
        catch {
            throw CompilerError.libraryGenerationFailed(error)
        }
    }
}