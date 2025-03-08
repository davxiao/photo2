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
}//end struct ThumbnailView

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
  } //end func generateThumbnailsfromFolder


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
    }
    .padding()
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
      /*
      ToolbarItem {
        Button("Save File") {
          saveThumbnailsToFile()
        }
      }
      ToolbarItem {
        Button("Load File") {
          loadThumbnailsFromFile()
        }
      }
       */
    }
  } //end var body: some View

  func updateGridLayout() {
    guard thumbnailSize.width > 0 else {
      gridLayout = [GridItem(.flexible())]
      return
    }

    let availableWidth = windowWidth - 40
    let numberOfColumns = max(1, Int(availableWidth / (thumbnailSize.width + 20)))
    gridLayout = Array(repeating: GridItem(.flexible(), spacing: 20), count: numberOfColumns)
  }//end func updateGridLayout

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

        Task.detached {
          let request = QLThumbnailGenerator.Request(fileAt: fileURL,
                                                     size: CGSize(width: 256, height: 256),
                                                     scale: NSScreen.main?.backingScaleFactor ?? 1,
                                                     representationTypes: .thumbnail)
          let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
          await MainActor.run {
            photoAssets.append(.init(url: fileURL, thumbnail: imageToData(thumbnail.nsImage)!))
            print("adding photoAssets \(photoAssets.count)")
          }
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
