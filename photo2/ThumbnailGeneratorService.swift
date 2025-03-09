import Foundation
import AppKit
import QuickLookThumbnailing

// Make the service class conform to Sendable
@available(macOS 12.0, *)
actor ThumbnailGeneratorService: NSObject, ThumbnailGeneratorProtocol {
    private var activeTask: Task<Void, Error>?
    
    nonisolated func generateThumbnails(fromDirectory path: String, completion: @escaping ([ThumbnailResult]?, Error?) -> Void) {
        // Start a new task to handle the thumbnail generation
        Task {
            // We need to capture self explicitly to avoid isolation issues
            let service = self
            
            // Cancel any existing task
            await service.cancelActiveTask()
            
            // Create a new task for the actual work
            let serviceTask = Task<Void, Error> {
                do {
                    let directoryURL = URL(fileURLWithPath: path)
                    let fileManager = FileManager.default
                    
                    // Check if the directory exists and is accessible
                    var isDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), 
                          isDirectory.boolValue else {
                        let error = NSError(domain: "ThumbnailGeneratorErrorDomain", 
                                           code: ThumbnailGeneratorErrorCode.directoryNotFound.rawValue,
                                           userInfo: [NSLocalizedDescriptionKey: "Directory not found"])
                        // Use MainActor to call the completion handler
                        await MainActor.run {
                            completion(nil, error)
                        }
                        return
                    }
                    
                    // Find eligible video files
                    let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .creationDateKey, .fileSizeKey]
                    guard let enumerator = fileManager.enumerator(
                        at: directoryURL,
                        includingPropertiesForKeys: resourceKeys,
                        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants]
                    ) else {
                        let error = NSError(domain: "ThumbnailGeneratorErrorDomain", 
                                           code: ThumbnailGeneratorErrorCode.accessDenied.rawValue,
                                           userInfo: [NSLocalizedDescriptionKey: "Access denied"])
                        await MainActor.run {
                            completion(nil, error)
                        }
                        return
                    }
                    
                    // Collect eligible files
                    var eligibleFiles: [URL] = []
                    for case let fileURL as URL in enumerator {
                        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
                        
                        // Check if it's a regular file
                        guard resourceValues.isRegularFile == true else { continue }
                        
                        // Check file extensions
                        let fileExtension = fileURL.pathExtension.lowercased()
                        guard fileExtension == "mp4" || fileExtension == "mkv" else { continue }
                        
                        eligibleFiles.append(fileURL)
                    }
                    
                    // Process files with controlled concurrency
                    var results: [ThumbnailResult] = []
                    
                    // Create a helper function for image conversion that doesn't require actor isolation
                    let imageToDataHelper = { (image: NSImage) -> Data? in
                        guard let tiffRepresentation = image.tiffRepresentation,
                              let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
                            return nil
                        }
                        return bitmapImage.representation(using: .png, properties: [:])
                    }
                    
                    // Use TaskGroup for better concurrency control
                    try await withThrowingTaskGroup(of: ThumbnailResult?.self) { group in
                        // Limit concurrency to 5 tasks at a time
                        let maxConcurrentTasks = 5
                        var tasksAdded = 0
                        var activeTaskCount = 0
                        
                        while tasksAdded < eligibleFiles.count {
                            // Add tasks up to our concurrency limit
                            while activeTaskCount < maxConcurrentTasks && tasksAdded < eligibleFiles.count {
                                let fileURL = eligibleFiles[tasksAdded]
                                tasksAdded += 1
                                activeTaskCount += 1
                                
                                group.addTask {
                                    do {
                                        // Get file metadata
                                        let resourceValues = try fileURL.resourceValues(forKeys: Set([.creationDateKey, .fileSizeKey]))
                                        let creationDate = resourceValues.creationDate
                                        
                                        // Fix the fileSize type issue
                                        let fileSize: UInt64?
                                        if let size = resourceValues.fileSize {
                                            fileSize = UInt64(size)
                                        } else {
                                            fileSize = nil
                                        }
                                        
                                        // Generate thumbnail
                                        let request = QLThumbnailGenerator.Request(
                                            fileAt: fileURL,
                                            size: CGSize(width: 256, height: 256),
                                            scale: 2.0,
                                            representationTypes: .thumbnail
                                        )
                                        
                                        let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                                        
                                        // Convert to data using the helper function
                                        guard let thumbnailData = imageToDataHelper(thumbnail.nsImage) else {
                                            print("Failed to convert thumbnail to data for \(fileURL.lastPathComponent)")
                                            return nil
                                        }
                                        
                                        // Create result - this is a transport object for XPC
                                        return ThumbnailResult(
                                            id: UUID().uuidString,
                                            urlString: fileURL.absoluteString,
                                            thumbnailData: thumbnailData,
                                            creationDate: creationDate,
                                            fileSize: fileSize
                                        )
                                    } catch {
                                        print("Error generating thumbnail for \(fileURL.lastPathComponent): \(error)")
                                        return nil
                                    }
                                }
                            }
                            
                            // Wait for a task to complete
                            if let result = try await group.next() {
                                activeTaskCount -= 1
                                if let validResult = result {
                                    results.append(validResult)
                                }
                            }
                        }
                        
                        // Collect any remaining results
                        for try await result in group {
                            if let validResult = result {
                                results.append(validResult)
                            }
                        }
                    }
                    
                    print("Hello world") // Print when all thumbnails are processed
                    print("Successfully generated thumbnails for \(results.count) files")
                    
                    // Return the results on the main thread
                    await MainActor.run {
                        completion(results, nil)
                    }
                    
                } catch {
                    if error is CancellationError {
                        print("Thumbnail generation was cancelled")
                        await MainActor.run {
                            completion(nil, NSError(domain: "ThumbnailGeneratorErrorDomain", 
                                                 code: -999,
                                                 userInfo: [NSLocalizedDescriptionKey: "Operation cancelled"]))
                        }
                    } else {
                        let nsError = NSError(domain: "ThumbnailGeneratorErrorDomain", 
                                             code: ThumbnailGeneratorErrorCode.processingFailed.rawValue,
                                             userInfo: [NSLocalizedDescriptionKey: error.localizedDescription])
                        await MainActor.run {
                            completion(nil, nsError)
                        }
                    }
                }
            }
            
            // Store the task
            await service.storeActiveTask(serviceTask)
        }
    }
    
    nonisolated func cancelOperations(completion: @escaping () -> Void) {
        Task {
            // We need to capture self explicitly to avoid isolation issues
            let service = self
            
            await service.cancelActiveTask()
            
            // Call the completion handler on the main thread
            await MainActor.run {
                completion()
            }
        }
    }
    
    private func storeActiveTask(_ task: Task<Void, Error>) {
        activeTask = task
    }
    
    private func cancelActiveTask() {
        activeTask?.cancel()
        activeTask = nil
    }
    
    // This function is no longer needed as we're using a local helper function
    // private func imageToData(_ image: NSImage) async -> Data? {
    //     guard let tiffRepresentation = image.tiffRepresentation,
    //           let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
    //         return nil
    //     }
    //     return bitmapImage.representation(using: .png, properties: [:])
    // }
} 