//
//  ContentView.swift
//  photo2
//
//  Created by David Xiao on 3/1/25.
//

import SwiftUI
import AppKit
import System
import Foundation
import Yams
@preconcurrency import QuickLookThumbnailing


struct ThumbnailView: View {
  let photoAsset: PhotoAsset
  let thumbnailSize: CGSize

  var body: some View {
    VStack {
      if let thumbnailData = photoAsset.thumbnail, let thumbnail = dataToNSImage(thumbnailData) {
        Image(nsImage: thumbnail)
          .resizable()
          .scaledToFit()
          .frame(width: thumbnailSize.width, height: thumbnailSize.height)
          .cornerRadius(8)
          .onTapGesture(count: 2) { // Detect double-tap
            print("Double-clicked: \(photoAsset.fileName)")
            NSWorkspace.shared.open(photoAsset.url) // The modern way!
          }
      } else {
        ProgressView()
          .frame(width: thumbnailSize.width, height: thumbnailSize.height)
      }

      Text(photoAsset.fileName)
        .lineLimit(1)
        .font(.system(size: 16))
        .onTapGesture(count: 2) { // Detect double-tap
          print("Double-clicked: \(photoAsset.fileName)")
          NSWorkspace.shared.open(photoAsset.url) // The modern way!
        }
    }
  }
}//struct ThumbnailView

struct ContentView: View {
  @State private var isLoading = false
  @State private var photoAssets: [PhotoAsset] = []
  @State private var loadedFolderURL: URL?
  @State private var gridLayout: [GridItem] = [GridItem(.flexible())]
  @State private var windowWidth: CGFloat = 0
  @State private var currentSortOrder: SortOrder = .A2Z_fileName // Initial value
  private let thumbnailSize = CGSize(width: 256, height: 256)
  enum SortOrder {
    case A2Z_fileName
    case Z2A_fileName
    case A2Z_creationDate
    case Z2A_creationDate
  }
  //DEBUG: hard coded filename
  private let indexfilename = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Downloads/file.yaml"
  private let rawfilename = "\(FileManager.default.homeDirectoryForCurrentUser.path)/Downloads/file.data"


  func generateThumbnailsfromFolder() {
    let openPanel = NSOpenPanel()
    openPanel.canChooseFiles = false
    openPanel.canChooseDirectories = true
    openPanel.allowsMultipleSelection = false

    if openPanel.runModal() == .OK {
      if let folderURL = openPanel.url {
        generateThumbnails(from: folderURL)
      }
    }
  }//func generateThumbnailsfromFolder


  var body: some View {
    GeometryReader { geometry in
      ScrollView {
        LazyVGrid(columns: gridLayout, spacing: 20) {
          var sortedPhotoAssets: [PhotoAsset] {
            switch currentSortOrder {
            case .A2Z_fileName:
              return photoAssets.sorted { $0.fileName < $1.fileName }
            case .Z2A_fileName:
              return photoAssets.sorted { $0.fileName > $1.fileName }
            case .A2Z_creationDate:
              return photoAssets.sorted { $0.creationDate! < $1.creationDate! }
            case .Z2A_creationDate:
              return photoAssets.sorted { $0.creationDate! > $1.creationDate! }
            }
          }
          ForEach(sortedPhotoAssets) { photoAsset in
            ThumbnailView(photoAsset: photoAsset, thumbnailSize: thumbnailSize)
          }
        }
        .padding(20)
        .onAppear {
          self.windowWidth = geometry.size.width
          updateGridLayout()
        }
        .onChange(of: geometry.size.width) { oldWidth, newWidth in
          self.windowWidth = newWidth
          updateGridLayout()
        }
      }
      .ignoresSafeArea(.all, edges: [.trailing])
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .padding(0)
    .ignoresSafeArea(.all, edges: [.trailing])
    .navigationTitle("Photo2")
    .toolbar {
      ToolbarItem {
        Button("A-Z filename") {
          currentSortOrder = .A2Z_fileName
        }
        .background(currentSortOrder == .A2Z_fileName ? Color.yellow : Color.gray.opacity(0.5))
      }
      ToolbarItem {
        Button("Z-A filename") {
          currentSortOrder = .Z2A_fileName
        }
        .background(currentSortOrder == .Z2A_fileName ? Color.yellow : Color.gray.opacity(0.5))
      }
      ToolbarItem {
        Button("A-Z creationdate") {
          currentSortOrder = .A2Z_creationDate
        }
        .background(currentSortOrder == .A2Z_creationDate ? Color.yellow : Color.gray.opacity(0.5))
      }
      ToolbarItem {
        Button("Z-A creationdate") {
          currentSortOrder = .Z2A_creationDate
        }
        .background(currentSortOrder == .Z2A_creationDate ? Color.yellow : Color.gray.opacity(0.5))
      }
      ToolbarItem {
        Button("Select Video Folder") {
          generateThumbnailsfromFolder()
          //DEBUG
          print("generateThumbnailsfromFolder() completed!")
        }
      }
      ToolbarItem {
        Button("Save File") {
          save()
        }
      }
      ToolbarItem {
        Button("Load File") {
          load()
        }
      }
    }
  } //end var body: some View

  func load() {
    Task.detached {
      do {
        //order is important, loadIndex first
        try await loadIndexFromYAML(filePath: indexfilename)
        try await loadRawFromFile(filePath: rawfilename)
      } catch {
        print("Failed to load photo collection: \(error)")
      }
    }
  }

  func save() {
    Task.detached {
      do {
        //order is important, saveRaw first
        try await saveRawToFile(filePath: rawfilename)
        try await saveIndexToYAML(filePath: indexfilename)
      } catch {
        print("Failed to save photo collection: \(error)")
      }
    }
  }

  func saveRawToFile(filePath: String) throws {
    var offset: UInt64 = 0
    do {
      if !FileManager.default.fileExists(atPath: filePath) {
        FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
      }
      let fileHandle = try FileHandle(forUpdating: URL(fileURLWithPath: filePath))

      for index in photoAssets.indices {
        try fileHandle.seek(toOffset: offset)
        try fileHandle.write(contentsOf: photoAssets[index].thumbnail!)
        photoAssets[index].thumbnail_offset = offset
        photoAssets[index].thumbnail_len = UInt64(photoAssets[index].thumbnail!.count)
        offset += photoAssets[index].thumbnail_len!
      }
      print("Total of \(offset) bytes saved to Rawfile: \(filePath)")
    } catch {
      print("Error writing to file: \(error)")
      throw error
    }
  }

  func saveIndexToYAML(filePath: String) throws {
    do {
      let fileURL = URL(fileURLWithPath: filePath)
      let encoder = YAMLEncoder()
      let yamlString = try encoder.encode(photoAssets)
      try yamlString.write(to: fileURL, atomically: true, encoding: .utf8)
      print("Saved index to \(filePath)")
    } catch {
      print("Error saving index: \(error)")
      throw error
    }
  }

  func loadIndexFromYAML(filePath: String) async throws {
    let fileURL = URL(fileURLWithPath: filePath)
    do {
      let yamlString = try String(contentsOf: fileURL, encoding: .utf8)
      let decoder = YAMLDecoder()
      photoAssets = try decoder.decode([PhotoAsset].self, from: yamlString)
      print("Successfully loaded photoAssets from \(filePath)")
    } catch {
      print("Error loading photoAssets from \(filePath): \(error)")
      throw error
    }
  }

  func loadRawFromFile(filePath: String) throws {
    var totalBytesRead: UInt64 = 0
    do {
      if !FileManager.default.fileExists(atPath: filePath) {
        FileManager.default.createFile(atPath: filePath, contents: nil, attributes: nil)
      }
      let fileHandle = try FileHandle(forReadingFrom: URL(fileURLWithPath: filePath))

      for index in photoAssets.indices {
        try fileHandle.seek(toOffset: photoAssets[index].thumbnail_offset!)
        try photoAssets[index].thumbnail = fileHandle.read(upToCount: Int(photoAssets[index].thumbnail_len!))
        //After modifying assets you must reassign the modified assets array back to the collection using the key. This is how the changes are "kept" in the collection.
        totalBytesRead += UInt64(photoAssets[index].thumbnail!.count)
      }
      print("Total of \(totalBytesRead) bytes read from \(filePath)")
    } catch {
      print("Error reading from file: \(error)")
    }
  }

  func updateGridLayout() {
    guard thumbnailSize.width > 0 else {
      gridLayout = [GridItem(.flexible())]
      return
    }

    let availableWidth = windowWidth - 40
    let numberOfColumns = max(1, Int(availableWidth / (thumbnailSize.width + 20)))
    gridLayout = Array(repeating: GridItem(.flexible(), spacing: 20), count: numberOfColumns)
  }//end func updateGridLayout

  // Add this actor outside the ContentView struct
  actor TaskCounter {
    private var count = 0
    
    func increment() {
      count += 1
    }
    
    func decrement() {
      count -= 1
    }
    
    func getCount() -> Int {
      return count
    }
  }

  // Then modify the generateThumbnails function
  func generateThumbnails(from folderURL: URL) {
    loadedFolderURL = folderURL // Store for reloading
    photoAssets.removeAll() // Clear previous results from the view
    
    // Create a custom executor with a fixed thread pool
    let thumbnailExecutor = DispatchQueue(label: "com.photo2.thumbnailExecutor", attributes: .concurrent)
    
    Task {
      do {
        let fileManager = FileManager.default
        let directoryURL = folderURL
        let taskCounter = TaskCounter()

        // Check if the directory exists and is accessible
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
          print("Error: '\(directoryURL)' is not a valid directory or is inaccessible.")
          return
        }

        let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
        guard let enumerator = fileManager.enumerator(at: directoryURL,
                                                    includingPropertiesForKeys: resourceKeys,
                                                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
                                                    errorHandler: { (url, error) -> Bool in
          print("Error enumerating '\(url.path)': \(error)")
          return true // Continue enumeration even if there are errors with some files.
        }) else {
          print("Error: enumerator is nil")
          return
        }
        
        // Collect all eligible files first
        var eligibleFiles: [URL] = []
        for case let fileURL as URL in enumerator {
          let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))
          
          // Check if the file exists and that it is not a directory
          guard resourceValues.isRegularFile == true else { continue }
          
          // Check file extensions
          let fileExtension = fileURL.pathExtension.lowercased()
          guard fileExtension == "mp4" || fileExtension == "mkv" else { continue }
          
          eligibleFiles.append(fileURL)
        }
        
        // Process files in parallel using task group with throttling
        try await withThrowingDiscardingTaskGroup { group in
          var fileIndex = 0
          
          // Process files in batches
          while fileIndex < eligibleFiles.count {
            // Check if we need to wait for tasks to complete
            let pendingCount = await taskCounter.getCount()
            if pendingCount > 10 {
              print("Throttling: \(pendingCount) tasks pending. Waiting for tasks to complete...")
              try await Task.sleep(for: .seconds(2))
              continue
            }
            
            // Add up to 5 more tasks if we have fewer than 10 pending tasks
            if pendingCount <= 5 {
              let batchSize = min(5, eligibleFiles.count - fileIndex)
              print("Adding batch of \(batchSize) tasks (pending: \(pendingCount))")
              
              for _ in 0..<batchSize {
                let fileURL = eligibleFiles[fileIndex]
                fileIndex += 1
                await taskCounter.increment()
                
                group.addTask {
                  defer { Task { await taskCounter.decrement() } }
                  
                  try await thumbnailExecutor.run {
                    let request = QLThumbnailGenerator.Request(
                      fileAt: fileURL,
                      size: CGSize(width: 256, height: 256),
                      scale: NSScreen.main?.backingScaleFactor ?? 1,
                      representationTypes: .thumbnail
                    )
                    
                    let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
                    
                    guard let thumbnailData = imageToData(thumbnail.nsImage) else {
                      print("Failed to convert thumbnail to data for \(fileURL.lastPathComponent)")
                      return
                    }
                    
                    await MainActor.run {
                      photoAssets.append(.init(url: fileURL, thumbnail: thumbnailData))
                      print("Adding photoAsset \(photoAssets.count): \(fileURL.lastPathComponent)")
                    }
                  }
                }
                
                if fileIndex >= eligibleFiles.count {
                  break
                }
              }
            } else {
              // If we have between 10-20 tasks, wait a bit before checking again
              try await Task.sleep(for: .milliseconds(500))
            }
          }
          
          // Wait for all remaining tasks to complete
          while await taskCounter.getCount() > 0 {
            try await Task.sleep(for: .milliseconds(500))
          }
        }
        
        print("Hello world") // Print when all tasks are completed
        print("Successfully generated thumbnails for \(photoAssets.count) files")
        
      } catch {
        print("Error generating thumbnails: \(error)")
      }
    }
  }
}//struct ContentView


// Helper function to convert NSImage to Data
func imageToData(_ image: NSImage) -> Data? {

  guard let tiffRepresentation = image.tiffRepresentation,
        let bitmapImage = NSBitmapImageRep(data: tiffRepresentation) else {
    return nil
  }
  // Get PNG data from the bitmap representation.
  return bitmapImage.representation(using: .png, properties: [:])
}

// Helper Function to Convert Data to NSImage
func dataToNSImage(_ data: Data) -> NSImage? {
  return NSImage(data: data)
}

// Custom TaskExecutor implementation
extension DispatchQueue: @unchecked Sendable {
  func run<T: Sendable>(operation: @escaping @Sendable () async throws -> T) async throws -> T {
    return try await withCheckedThrowingContinuation { continuation in
      self.async {
        Task {
          do {
            let result = try await operation()
            continuation.resume(returning: result)
          } catch {
            continuation.resume(throwing: error)
          }
        }
      }
    }
  }
}

struct PhotoAsset: Identifiable, Codable {
  let id: String
  let url: URL
  var fileName: String { return url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
  var thumbnail: Data?
  var creationDate: Date?
  var fileSize: UInt64?
  var thumbnail_offset: UInt64?
  var thumbnail_len: UInt64?

  init(url: URL) {
    self.id = UUID().uuidString
    self.url = url
    self.creationDate = PhotoAsset.getCreationDate(for: url)
    self.fileSize = PhotoAsset.getFileSize(for: url)
  }

  init(url: URL, thumbnail: Data) {
    self.init(url: url)
    self.thumbnail = thumbnail
  }

  static func getCreationDate(for url: URL) -> Date? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return attributes[.creationDate] as? Date
    } catch {
      print("Error getting creation date: \(error)")
      return nil
    }
  }

  static func getFileSize(for url: URL) -> UInt64? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return attributes[.size] as? UInt64
    } catch {
      print("Error getting file size: \(error)")
      return nil
    }
  }
  //Asynchronously loads the thumbnail from the disk.  Returns the image Data.
  func loadThumbnail() async -> Data? {
    if self.thumbnail != nil { return self.thumbnail }

    return await MainActor.run {
      guard let image = NSImage(contentsOf: self.url) else { return nil }
      image.size = NSSize(width: 100, height: 100)
      // Convert to Data here.
      return imageToData(image)
    }
  }

  enum CodingKeys: String, CodingKey {
    // do not save thumbnail and fileName
    case id, url, creationDate, fileSize, thumbnail_offset, thumbnail_len
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(url.absoluteString, forKey: .url)
    try container.encode(creationDate, forKey: .creationDate)
    try container.encode(fileSize, forKey: .fileSize)
    try container.encode(thumbnail_offset, forKey: .thumbnail_offset)
    try container.encode(thumbnail_len, forKey: .thumbnail_len)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    let urlString = try container.decode(String.self, forKey: .url)
    guard let url = URL(string: urlString) else {
      throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Invalid URL string")
    }
    self.url = url

    creationDate = try container.decode(Date.self, forKey: .creationDate)
    fileSize = try container.decode(UInt64.self, forKey: .fileSize)
    thumbnail_offset = try container.decode(UInt64.self, forKey: .thumbnail_offset)
    thumbnail_len = try container.decode(UInt64.self, forKey: .thumbnail_len)
  }
}//struct PhotoAsset
