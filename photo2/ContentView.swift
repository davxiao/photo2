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



struct ContentView: View {
  @State private var isLoading = false
  @State private var photoAssets: [PhotoAsset] = []
  @State private var loadedFolderURL: URL?

  func generateThumbnailsfromFolder() {
    let openPanel = NSOpenPanel()
    openPanel.canChooseFiles = false
    openPanel.canChooseDirectories = true
    openPanel.allowsMultipleSelection = false

    if openPanel.runModal() == .OK {
      if let folderURL = openPanel.url {
        let now_1 = Date()
        generateThumbnails(from: folderURL)
        print("generateThumbnails() returned in \(String(format: "%.1f", Date().timeIntervalSince(now_1))) s")
      }
    }
  } //end func generateThumbnailsfromFolder

  var body: some View {
    VStack {
      Image(systemName: "globe")
        .imageScale(.large)
        .foregroundStyle(.tint)
      Text("\(photoAssets.count)")
    }
    .padding()
    .navigationTitle("Photo2")
    .toolbar {
      ToolbarItem {
        Button("Select Video Folder") {
          generateThumbnailsfromFolder() // Await the result of the async function
        }
        .disabled(isLoading) // Disable the button while loading
      }
    }
  } //end var body: some View

  func generateThumbnails(from folderURL: URL)  {
    loadedFolderURL = folderURL // Store for reloading
    photoAssets.removeAll() // Clear previous results from the view

    do {
      let fileManager = FileManager.default
      let directoryURL = folderURL

      // Check if the directory exists and is accessible
      var isDirectory: ObjCBool = false
      guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
        print("Error: '\(directoryURL)' is not a valid directory or is inaccessible.")
        // Show an alert or update the UI to indicate the error.
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
        //show error and alert
        print("Error: enumerator is nil")
        return
      }

      for case let fileURL as URL in enumerator {
        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

        //check if the file exists and that it is not a directory
        guard resourceValues.isRegularFile == true else { continue }

        //check file extensions
        let fileExtension = fileURL.pathExtension.lowercased()
        guard fileExtension == "mp4" || fileExtension == "mkv" else { continue }

        Task {
          let request = QLThumbnailGenerator.Request(fileAt: fileURL,
                                                     size: CGSize(width: 256, height: 256),
                                                     scale: NSScreen.main?.backingScaleFactor ?? 1,
                                                     representationTypes: .thumbnail)
          let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
          photoAssets.append(.init(url: fileURL, thumbnail: imageToData(thumbnail.nsImage)!))
          print("adding photoAssets \(photoAssets.count)")
        }
      }

    } catch {
      print("Error listing files: \(error)")
      // Show an error to the user.
    }
  }
}



//end struct ContentView


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

struct PhotoAsset: Identifiable, Codable {
  let id: String
  let url: URL
  let fileName: String
  var thumbnail: Data?
  var creationDate: Date?
  var fileSize: UInt64?
  var thumbnail_offset: UInt64?
  var thumbnail_len: UInt64?

  init(url: URL) {
    self.id = UUID().uuidString
    self.url = url
    self.fileName = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
    self.creationDate = PhotoAsset.getCreationDate(for: url)
    self.fileSize = PhotoAsset.getFileSize(for: url)
  }

  init(url: URL, thumbnail: Data) {
    self.id = UUID().uuidString
    self.url = url
    self.fileName = url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent
    self.creationDate = PhotoAsset.getCreationDate(for: url)
    self.fileSize = PhotoAsset.getFileSize(for: url)
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
    // do not save thumbnail here
    case id, url, fileName, creationDate, fileSize, thumbnail_offset, thumbnail_len
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(url.absoluteString, forKey: .url)
    try container.encode(fileName, forKey: .fileName)
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

    fileName = try container.decode(String.self, forKey: .fileName)
    creationDate = try container.decodeIfPresent(Date.self, forKey: .creationDate)
    fileSize = try container.decodeIfPresent(UInt64.self, forKey: .fileSize)
    thumbnail_offset = try container.decodeIfPresent(UInt64.self, forKey: .thumbnail_offset)
    thumbnail_len = try container.decodeIfPresent(UInt64.self, forKey: .thumbnail_len)
  }
}
