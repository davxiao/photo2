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
import Combine
import AVKit
import AVFoundation
import QuickLookThumbnailing

// Shared state manager for app-wide state
@MainActor
class AppStateManager: ObservableObject {
  static let shared = AppStateManager()

  @Published var isModified: Bool = false

  private init() {}
}

// Video Player State Manager - tracks all active video players and dismisses paused ones after 5 minutes
@MainActor
class VideoPlayerStateManager: ObservableObject {
  static let shared = VideoPlayerStateManager()

  struct PlayerState {
    let id: String
    var isPaused: Bool
    var pausedAt: Date?
    var isHovering: Bool
    var dismissCallback: () -> Void
  }

  private var playerStates: [String: PlayerState] = [:]
  private var cleanupTimer: Timer?
  private let pauseTimeoutMinutes: Double = 1.0 // Dismiss after 1 minutes of pause
  private let checkIntervalSeconds: Double = 5.0 // Check every 5 seconds

  private init() {
    startCleanupTimer()
  }

  private func startCleanupTimer() {
    cleanupTimer = Timer.scheduledTimer(withTimeInterval: checkIntervalSeconds, repeats: true) { [weak self] _ in
      Task { @MainActor in
        self?.checkAndDismissPausedPlayers()
      }
    }
  }

  func registerPlayer(id: String, dismissCallback: @escaping () -> Void) {
    playerStates[id] = PlayerState(
      id: id,
      isPaused: false,
      pausedAt: nil,
      isHovering: true,
      dismissCallback: dismissCallback
    )
    print("VideoPlayerStateManager: Registered player \(id)")
  }

  func unregisterPlayer(id: String) {
    playerStates.removeValue(forKey: id)
    print("VideoPlayerStateManager: Unregistered player \(id)")
  }

  func dismissAllPlayers() {
    let count = playerStates.count
    for (_, state) in playerStates {
      state.dismissCallback()
    }
    playerStates.removeAll()
    if count > 0 {
      print("VideoPlayerStateManager: Dismissed all \(count) player(s)")
    }
  }

  func updatePlayerState(id: String, isPaused: Bool, isHovering: Bool) {
    guard var state = playerStates[id] else { return }

    // Track when the player gets paused
    if isPaused && !state.isPaused {
      state.pausedAt = Date()
    } else if !isPaused {
      state.pausedAt = nil
    }

    state.isPaused = isPaused
    state.isHovering = isHovering
    playerStates[id] = state
  }

  private func checkAndDismissPausedPlayers() {
    let now = Date()
    let timeoutInterval = pauseTimeoutMinutes * 60 // Convert to seconds

    var playersToRemove: [String] = []

    for (id, state) in playerStates {
      // Skip if currently hovering - don't dismiss
      if state.isHovering {
        continue
      }

      // Check if paused for longer than timeout
      if state.isPaused, let pausedAt = state.pausedAt {
        let pauseDuration = now.timeIntervalSince(pausedAt)
        if pauseDuration >= timeoutInterval {
          print("VideoPlayerStateManager: Dismissing player \(id) - paused for \(Int(pauseDuration)) seconds")
          state.dismissCallback()
          playersToRemove.append(id)
        }
      }
    }

    // Remove dismissed players
    for id in playersToRemove {
      playerStates.removeValue(forKey: id)
    }

    if !playersToRemove.isEmpty {
      print("VideoPlayerStateManager: Dismissed \(playersToRemove.count) player(s), \(playerStates.count) remaining")
    }
  }

  // Note: No deinit needed - this is a singleton that lives for the app lifetime
  // The timer will be automatically invalidated when the app terminates
}

// Video Player Manager class to handle AVPlayer state
@MainActor
class VideoPlayerManager: ObservableObject {
  @Published var player: AVPlayer?
  @Published var isPlaying = false
  @Published var isMuted = true
  @Published var currentTime: Double = 0
  @Published var duration: Double = 0

  private var timeObserver: Any?
  private var isSeeking = false
  private var pendingSeekTime: Double?

  init() {}

  func loadVideo(url: URL) {
    let playerItem = AVPlayerItem(url: url)
    player = AVPlayer(playerItem: playerItem)
    player?.isMuted = isMuted

    // Load duration asynchronously using modern API
    Task { [weak self] in
      guard let self = self else { return }
      if let asset = self.player?.currentItem?.asset {
        do {
          let duration = try await asset.load(.duration)
          self.duration = CMTimeGetSeconds(duration)
        } catch {
          print("Failed to load duration: \(error)")
        }
      }
    }

    // Add time observer
    timeObserver = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] time in
      Task { @MainActor [weak self] in
        guard let self = self else { return }
        self.currentTime = CMTimeGetSeconds(time)
        // Update duration from currentItem if available and valid
        if let currentItem = self.player?.currentItem {
          let itemDuration = currentItem.duration
          if itemDuration.isNumeric && !itemDuration.isIndefinite {
            self.duration = CMTimeGetSeconds(itemDuration)
          }
        }
      }
    }

    // Loop video
    NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: player?.currentItem, queue: .main) { [weak self] _ in
      Task { @MainActor [weak self] in
        self?.player?.seek(to: .zero)
        self?.player?.play()
      }
    }
  }

  func play() {
    player?.play()
    isPlaying = true
  }

  func pause() {
    player?.pause()
    isPlaying = false
  }

  func togglePlayPause() {
    if isPlaying {
      pause()
    } else {
      play()
    }
  }

  func toggleMute() {
    isMuted.toggle()
    player?.isMuted = isMuted
  }

  func seek(to time: Double) {
    // If already seeking, store the pending seek time
    if isSeeking {
      pendingSeekTime = time
      return
    }

    isSeeking = true
    let cmTime = CMTime(seconds: time, preferredTimescale: 600)

    player?.seek(to: cmTime, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      Task { @MainActor [weak self] in
        guard let self = self else { return }

        self.isSeeking = false

        // If there's a pending seek, execute it
        if let pendingTime = self.pendingSeekTime {
          self.pendingSeekTime = nil
          self.seek(to: pendingTime)
        }
      }
    }
  }

  func cleanup() {
    pause()
    if let observer = timeObserver {
      player?.removeTimeObserver(observer)
    }
    player = nil
  }

  // Note: deinit removed because cleanup() is @MainActor isolated and cannot be called
  // from a nonisolated deinit. Cleanup is called from onDisappear in EmbeddedVideoPlayerView.
}

// NSViewRepresentable wrapper for AVPlayerView
struct AVPlayerViewRepresentable: NSViewRepresentable {
  let player: AVPlayer

  func makeNSView(context: Context) -> AVPlayerView {
    let playerView = AVPlayerView()
    playerView.player = player
    playerView.controlsStyle = .none // Hide default controls, use custom progress bar overlay
    playerView.showsFullScreenToggleButton = false
    return playerView
  }

  func updateNSView(_ nsView: AVPlayerView, context: Context) {
    nsView.player = player
  }
}

// Embedded Video Player View with default AVKit controls and progress bar overlay
struct EmbeddedVideoPlayerView: View {
  let videoURL: URL
  let size: CGSize
  let isLiked: Bool
  let onDoubleTap: () -> Void
  @StateObject private var playerManager = VideoPlayerManager()
  @Binding var isHovering: Bool

  var body: some View {
    ZStack {
      // Video player with default controls
      if let player = playerManager.player {
        AVPlayerViewRepresentable(player: player)
          .frame(width: size.width, height: size.height)
          .cornerRadius(8)
          .onAppear {
            playerManager.play()
          }
      } else {
        Color(NSColor.windowBackgroundColor)
          .frame(width: size.width, height: size.height)
          .cornerRadius(8)
      }

      // Custom controls overlay
      VStack {
        Spacer()

        // Control row with Play, Scrubber, and Mute
        HStack(spacing: 12) {
          // Play/Pause button
          Button(action: {
            playerManager.togglePlayPause()
          }) {
            Image(systemName: playerManager.isPlaying ? "pause.fill" : "play.fill")
              .foregroundColor(.white)
              .font(.system(size: 20))
          }
          .buttonStyle(PlainButtonStyle())
          .frame(width: 24)

          // Scrubber bar
          GeometryReader { geometry in
            ZStack(alignment: .leading) {
              // Background track
              Capsule()
                .fill(Color.gray.opacity(0.5))
                .frame(height: 4)

              // Progress fill
              Capsule()
                .fill(Color.white)
                .frame(width: playerManager.duration > 0 ? CGFloat(playerManager.currentTime / playerManager.duration) * geometry.size.width : 0, height: 4)

              // Scrubber thumb/knob
              Circle()
                .fill(Color.white)
                .frame(width: 14, height: 14)
                .shadow(color: .black.opacity(0.3), radius: 2, x: 0, y: 1)
                .offset(x: playerManager.duration > 0 ? CGFloat(playerManager.currentTime / playerManager.duration) * (geometry.size.width - 14) : 0)
            }
            .frame(height: 14)
            .contentShape(Rectangle())
            .gesture(
              DragGesture(minimumDistance: 0)
                .onChanged { value in
                  let progress = max(0, min(1, value.location.x / geometry.size.width))
                  let seekTime = Double(progress) * playerManager.duration
                  playerManager.seek(to: seekTime)
                }
            )
          }
          .frame(height: 14)

          // Mute/Unmute button
          Button(action: {
            playerManager.toggleMute()
          }) {
            Image(systemName: playerManager.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
              .foregroundColor(.white)
              .font(.system(size: 18))
              .frame(width: 24, height: 24)
          }
          .buttonStyle(PlainButtonStyle())
          .frame(width: 24, height: 24)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.black.opacity(0.6))
      }
      .frame(width: size.width, height: size.height)

      // Liked border overlay
      if isLiked {
        RoundedRectangle(cornerRadius: 8)
          .stroke(Color.yellow, lineWidth: 4)
          .frame(width: size.width, height: size.height)
      }

      // Invisible overlay to capture double-tap (above controls area)
      VStack {
        Color.clear
          .frame(width: size.width, height: size.height - 44) // Leave space for controls at bottom
          .contentShape(Rectangle())
          .onTapGesture(count: 2) {
            onDoubleTap()
          }
        Spacer()
          .frame(height: 44) // Controls area - don't capture taps here
      }
      .frame(width: size.width, height: size.height)
    }
    .onAppear {
      playerManager.loadVideo(url: videoURL)
    }
    .onDisappear {
      playerManager.cleanup()
    }
    .onChange(of: isHovering) { _, newValue in
      if newValue {
        playerManager.play()
      } else {
        playerManager.pause()
      }
    }
  }
}

struct ThumbnailView: View {
  @Binding var photoAsset: PhotoAsset
  let thumbnailSize: CGSize
  let enablePreview: Bool
  @State private var clickCount = 0
  @State private var clickTimer: Timer?
  @State private var hoverTimer: Timer?
  @State private var isHovering = false
  @State private var showVideoPlayer = false
  @ObservedObject private var appState = AppStateManager.shared

  var body: some View {
    VStack {
      ZStack {
        if let thumbnailData = photoAsset.thumbnail, let thumbnail = dataToNSImage(thumbnailData) {
          // Thumbnail image
          Image(nsImage: thumbnail)
            .resizable()
            .scaledToFit()
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
            .cornerRadius(8)
            .overlay(
              RoundedRectangle(cornerRadius: 8)
                .stroke(photoAsset.isLiked ? Color.yellow : Color.clear, lineWidth: 4)
            )
            .opacity(showVideoPlayer ? 0 : 1)
            .onTapGesture(count: 1) {
              handleClick()
            }

          // Video player overlay
          if showVideoPlayer {
            EmbeddedVideoPlayerView(
              videoURL: photoAsset.url,
              size: thumbnailSize,
              isLiked: photoAsset.isLiked,
              onDoubleTap: {
                // Dismiss player and open video file
                withAnimation(.easeInOut(duration: 0.3)) {
                  showVideoPlayer = false
                }
                hoverTimer?.invalidate()

                // Update lastPlayDate
                photoAsset.lastPlayDate = Date()
                appState.isModified = true

                // Open the video file
                NSWorkspace.shared.open(photoAsset.url)
              },
              isHovering: $isHovering
            )
            .transition(.opacity)
          }
        } else {
          ProgressView()
            .frame(width: thumbnailSize.width, height: thumbnailSize.height)
        }
      }
      .onHover { hovering in
        isHovering = hovering

        if hovering {
          // Start 10-second timer when hovering (only if video player not already shown and preview is enabled)
          if !showVideoPlayer && enablePreview {
            hoverTimer?.invalidate()
            hoverTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { _ in
              Task { @MainActor in
                withAnimation(.easeInOut(duration: 0.3)) {
                  showVideoPlayer = true
                  // Register player with state manager
                  VideoPlayerStateManager.shared.registerPlayer(id: photoAsset.id) {
                    withAnimation(.easeInOut(duration: 0.3)) {
                      showVideoPlayer = false
                    }
                  }
                }
              }
            }
          }

          // Update player state when hovering
          if showVideoPlayer {
            Task { @MainActor in
              VideoPlayerStateManager.shared.updatePlayerState(id: photoAsset.id, isPaused: false, isHovering: true)
            }
          }
        } else {
          // Cancel timer when not hovering, but keep video player visible (it will pause via isHovering binding)
          hoverTimer?.invalidate()
          hoverTimer = nil
          // Update player state - paused and not hovering
          if showVideoPlayer {
            Task { @MainActor in
              VideoPlayerStateManager.shared.updatePlayerState(id: photoAsset.id, isPaused: true, isHovering: false)
            }
          }
        }
      }
      .onChange(of: showVideoPlayer) { _, newValue in
        if !newValue {
          // Unregister player when dismissed
          VideoPlayerStateManager.shared.unregisterPlayer(id: photoAsset.id)
        }
      }

      Text(photoAsset.fileName)
        .lineLimit(1)
        .font(.system(size: 16))
        .onTapGesture(count: 1) {
          handleClick()
        }
    }
  }

  private func handleClick() {
    // If video player is showing, hide it on click
    if showVideoPlayer {
      withAnimation(.easeInOut(duration: 0.3)) {
        showVideoPlayer = false
      }
      hoverTimer?.invalidate()
      return
    }

    let isCommandPressed = NSEvent.modifierFlags.contains(.command)

    if isCommandPressed {
      // Command+click: toggle like
      photoAsset.isLiked.toggle()
      appState.isModified = true
      print("Toggled like for: \(photoAsset.fileName), isLiked: \(photoAsset.isLiked)")
    } else {
      // Regular click: count for double-click detection
      clickCount += 1

      if clickCount == 1 {
        // Start timer for double-click detection
        clickTimer?.invalidate()
        clickTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { _ in
          Task { @MainActor in
            // Single click - timer expired, will reset on next click
            clickCount = 0
          }
        }
      } else if clickCount >= 2 {
        // Double-click detected
        clickTimer?.invalidate()
        clickCount = 0

        // Update lastPlayDate
        photoAsset.lastPlayDate = Date()
        appState.isModified = true

        NSWorkspace.shared.open(photoAsset.url)
      }
    }
  }
}//struct ThumbnailView

// Regex cache for search patterns - improves performance by caching compiled regex
final class RegexCache: @unchecked Sendable {
  static let shared = RegexCache()
  private var cache: [String: NSRegularExpression] = [:]
  private let lock = NSLock()
  
  private init() {}
  
  func regex(for pattern: String) -> NSRegularExpression? {
    lock.lock()
    defer { lock.unlock() }
    
    if let cached = cache[pattern] {
      return cached
    }
    
    do {
      let regex = try NSRegularExpression(pattern: pattern, options: .caseInsensitive)
      cache[pattern] = regex
      return regex
    } catch {
      return nil
    }
  }
  
  func clear() {
    lock.lock()
    defer { lock.unlock() }
    cache.removeAll()
  }
}

struct ContentView: View {
  @State private var isLoading = false
  @State private var photoAssets: [PhotoAsset] = []
  @State private var photoAssetURLIndex: [URL: Int] = [:] // O(1) lookup by URL
  @State private var loadedFolderURL: URL?
  @State private var gridLayout: [GridItem] = [GridItem(.flexible())]
  @State private var windowWidth: CGFloat = 0
  @State private var currentSortOrder: SortOrder = .A2Z_fileName // Initial value
  @State private var showLikedOnly: Bool = false
  @State private var enablePreview: Bool = false // Not saved to preferences
  @State private var searchText: String = "" // Search filter text
  private let thumbnailSize = CGSize(width: 256, height: 256)

  // Computed property to check if search text contains only valid characters (alphabet, numbers, and whitespace)
  private var isSearchTextValid: Bool {
    let validCharacters = CharacterSet.letters.union(.decimalDigits).union(.whitespaces)
    return searchText.unicodeScalars.allSatisfy { validCharacters.contains($0) }
  }

  // Computed property to format the folder path with truncation
  private var formattedFolderPath: String {
    guard let url = loadedFolderURL else { return " - no folder selected" }
    let path = url.path
    let maxLength = 50 // Maximum path length before truncation

    if path.count <= maxLength {
      return " - \(path)"
    } else {
      // Truncate from middle, showing beginning and end
      let keepLength = (maxLength - 3) / 2 // 3 for "..."
      let startPart = String(path.prefix(keepLength))
      let endPart = String(path.suffix(keepLength))
      return " - \(startPart)...\(endPart)"
    }
  }

  enum SortOrder {
    case A2Z_fileName
    case Z2A_fileName
    case A2Z_modificationDate
    case Z2A_modificationDate
    case recentlyPlayed
  }

  // Helper function to match filename with wildcard pattern (* as wildcard)
  // Uses RegexCache for improved performance
  private func matchesWildcard(fileName: String, pattern: String) -> Bool {
    // Replace whitespaces with wildcards
    let patternWithWildcardSpaces = pattern.replacingOccurrences(of: " ", with: "*")
    // Implicitly wrap pattern with wildcards at beginning and end
    let wrappedPattern = "*" + patternWithWildcardSpaces + "*"
    // Convert wildcard pattern to regex: escape special chars, replace * with .*
    let escapedPattern = NSRegularExpression.escapedPattern(for: wrappedPattern)
      .replacingOccurrences(of: "\\*", with: ".*")
    let regexPattern = "^" + escapedPattern + "$"

    // Use cached regex for better performance
    guard let regex = RegexCache.shared.regex(for: regexPattern) else {
      return false
    }
    let range = NSRange(fileName.startIndex..., in: fileName)
    return regex.firstMatch(in: fileName, options: [], range: range) != nil
  }

  // Computed property to get filtered indices (search, liked only, or all)
  private var filteredIndices: [Int] {
    var indices = Array(photoAssets.indices)

    // Apply search filter if search text is not empty/whitespace and is valid
    let trimmedSearch = searchText.trimmingCharacters(in: .whitespaces)
    if !trimmedSearch.isEmpty && isSearchTextValid {
      indices = indices.filter { matchesWildcard(fileName: photoAssets[$0].fileName, pattern: trimmedSearch) }
    }

    // Apply liked only filter
    if showLikedOnly {
      indices = indices.filter { photoAssets[$0].isLiked }
    }

    return indices
  }

  // Computed property to get sorted indices
  private var sortedIndices: [Int] {
    let indices = filteredIndices
    switch currentSortOrder {
    case .A2Z_fileName:
      return indices.sorted { photoAssets[$0].fileName < photoAssets[$1].fileName }
    case .Z2A_fileName:
      return indices.sorted { photoAssets[$0].fileName > photoAssets[$1].fileName }
    case .A2Z_modificationDate:
      return indices.sorted {
        guard let date0 = photoAssets[$0].modificationDate,
              let date1 = photoAssets[$1].modificationDate else { return false }
        return date0 < date1
      }
    case .Z2A_modificationDate:
      return indices.sorted {
        guard let date0 = photoAssets[$0].modificationDate,
              let date1 = photoAssets[$1].modificationDate else { return false }
        return date0 > date1
      }
    case .recentlyPlayed:
      // Only show videos that have been played (have lastPlayDate)
      return indices
        .filter { photoAssets[$0].lastPlayDate != nil }
        .sorted {
          let date0 = photoAssets[$0].lastPlayDate!
          let date1 = photoAssets[$1].lastPlayDate!
          return date0 > date1 // Most recent first
        }
    }
  }

  // Computed property for display count
  private var displayCount: Int {
    return sortedIndices.count
  }

  // User defaults key for recent files (stores up to 5 recent files)
  private let recentSaveLocationsKey = "RecentSaveLocations"

  // Helper function to update recent files
  private func updateRecentSaveLocations(with newFileURL: String) {
    var recentFiles = UserDefaults.standard.stringArray(forKey: recentSaveLocationsKey) ?? []

    // Remove the file if it already exists
    recentFiles.removeAll { $0 == newFileURL }

    // Insert the new file at the top
    recentFiles.insert(newFileURL, at: 0)

    // Keep only the last 5 files
    if recentFiles.count > 5 {
      recentFiles = Array(recentFiles.prefix(5))
    }

    // Save back to preferences
    UserDefaults.standard.set(recentFiles, forKey: recentSaveLocationsKey)
    print("Updated recent files: \(recentFiles.map { URL(string: $0)?.path ?? $0 })")
  }

  // Helper function to get the most recent file location
  private func getMostRecentSaveLocation() -> URL? {
    if let recentFiles = UserDefaults.standard.stringArray(forKey: recentSaveLocationsKey),
       let firstFile = recentFiles.first,
       let url = URL(string: firstFile) {
      return url.deletingLastPathComponent()
    }
    return nil
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
  }//func generateThumbnailsfromFolder


  var body: some View {
    VStack(spacing: 0) {
      // Search bar below toolbar, left aligned
      HStack {
        TextField("Search", text: $searchText)
          .textFieldStyle(PlainTextFieldStyle())
          .font(.system(size: 14, design: .monospaced))
          .padding(6)
          .background(Color(NSColor.textBackgroundColor))
          .cornerRadius(6)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(isSearchTextValid ? Color.gray.opacity(0.5) : Color.red, lineWidth: isSearchTextValid ? 1 : 2)
          )
          .frame(width: 250)
          .onChange(of: searchText) { _, newValue in
            // Convert to lowercase
            let lowercased = newValue.lowercased()
            if searchText != lowercased {
              searchText = lowercased
            }
          }
        Spacer()
      }
      .padding(.horizontal, 20)
      .padding(.vertical, 8)

      GeometryReader { geometry in
        ScrollView {
        LazyVGrid(columns: gridLayout, spacing: 20) {
          ForEach(sortedIndices, id: \.self) { index in
            ThumbnailView(photoAsset: $photoAssets[index], thumbnailSize: thumbnailSize, enablePreview: enablePreview)
          }
        }
        .padding(20)
        .onAppear {
          self.windowWidth = geometry.size.width
          updateGridLayout()
        }
        .onChange(of: geometry.size.width) {
          self.windowWidth = geometry.size.width
          updateGridLayout()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSNotification.Name("SaveAndQuit"))) { _ in
          saveAndQuit()
        }
      }
      .ignoresSafeArea(.all, edges: [.trailing])
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      }
      
      // Status bar at the bottom
      HStack {
        Text("Shown:  \(displayCount)   Total: \(photoAssets.count)")
          .font(.system(size: 12))
          .foregroundColor(.secondary)
          .padding(.horizontal, 12)
        Spacer()
      }
      .frame(height: 24)
      .background(Color(NSColor.windowBackgroundColor))
    }
    .padding(0)
    .ignoresSafeArea(.all, edges: [.trailing])
    .navigationTitle("Photo2 \(formattedFolderPath)")
    .onChange(of: enablePreview) { _, newValue in
      if !newValue {
        // Dismiss all video players when preview is disabled
        VideoPlayerStateManager.shared.dismissAllPlayers()
      }
    }
    .toolbar {
      ToolbarItemGroup {
        Toggle("Enable Preview", isOn: $enablePreview)
          .toggleStyle(.checkbox)

        Button("Liked Only") {
          showLikedOnly.toggle()
        }
        .background(showLikedOnly ? Color.yellow : Color.gray.opacity(0.5))

        Button("A-Z filename") {
          currentSortOrder = .A2Z_fileName
        }
        .background(currentSortOrder == .A2Z_fileName ? Color.yellow : Color.gray.opacity(0.5))

        Button("Z-A filename") {
          currentSortOrder = .Z2A_fileName
        }
        .background(currentSortOrder == .Z2A_fileName ? Color.yellow : Color.gray.opacity(0.5))

        Button("Oldest first") {
          currentSortOrder = .A2Z_modificationDate
        }
        .background(currentSortOrder == .A2Z_modificationDate ? Color.yellow : Color.gray.opacity(0.5))

        Button("Newest first") {
          currentSortOrder = .Z2A_modificationDate
        }
        .background(currentSortOrder == .Z2A_modificationDate ? Color.yellow : Color.gray.opacity(0.5))

        Button("Recently Played") {
          currentSortOrder = .recentlyPlayed
        }
        .background(currentSortOrder == .recentlyPlayed ? Color.yellow : Color.gray.opacity(0.5))
      }

      ToolbarItemGroup {
        Button("List not-liked") {
          listNotLikedFiles()
        }
        .disabled(photoAssets.isEmpty)

        Button("Select Video Folder") {
          generateThumbnailsfromFolder()
        }

        Button("Save File") {
          save()
        }
        .keyboardShortcut("s", modifiers: .command)
        .disabled(loadedFolderURL == nil)

        Button("Load File") {
          load()
        }

        Button("Reset All Settings") {
          removeRecentLocations()
        }
      }
    }
  } //end var body: some View

  func removeRecentLocations() {
    UserDefaults.standard.removeObject(forKey: recentSaveLocationsKey)
    print("Removed all recent locations")

    // Show confirmation alert
    let alert = NSAlert()
    alert.messageText = "Recent Locations Cleared"
    alert.informativeText = "All recent file locations have been removed."
    alert.alertStyle = .informational
    alert.addButton(withTitle: "OK")
    alert.runModal()
  }

  func listNotLikedFiles() {
    // Get all files that are not marked as liked
    let notLikedFiles = photoAssets.filter { !$0.isLiked }

    if notLikedFiles.isEmpty {
      let alert = NSAlert()
      alert.messageText = "All Files Liked"
      alert.informativeText = "All files are marked as liked!"
      alert.alertStyle = .informational
      alert.addButton(withTitle: "OK")
      alert.runModal()
      return
    }

    // Sort by file size, largest first
    let sortedFiles = notLikedFiles.sorted { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }

    // Create the content for the text file with timestamp
    let dateFormatter = DateFormatter()
    dateFormatter.dateStyle = .medium
    dateFormatter.timeStyle = .medium
    let timestamp = dateFormatter.string(from: Date())

    // Calculate total file size in GB
    let totalBytes = sortedFiles.reduce(UInt64(0)) { $0 + ($1.fileSize ?? 0) }
    let totalGB = Double(totalBytes) / 1_000_000_000.0

    var content = "# Files Not Marked as Liked\n"
    content += "# Generated: \(timestamp)\n"
    content += "# Total: \(sortedFiles.count) files\n"
    content += String(format: "# Total Size: %.2f GB\n", totalGB)
    content += "# " + String(repeating: "=", count: 50) + "\n\n"

    for asset in sortedFiles {
      // Add file size line before each file path
      let fileSizeGB = Double(asset.fileSize ?? 0) / 1_000_000_000.0
      content += String(format: "# %.2f GB\n", fileSizeGB)
      content += "\(asset.url.path)\n"
    }

    // Create a temporary file
    let tempDir = FileManager.default.temporaryDirectory
    let fileName = "photo2_\(Date().timeIntervalSince1970).txt"
    let fileURL = tempDir.appendingPathComponent(fileName)

    do {
      try content.write(to: fileURL, atomically: true, encoding: .utf8)

      // Open the file in TextEdit
      NSWorkspace.shared.open(fileURL)

      print("Created file list at: \(fileURL.path)")
    } catch {
      let alert = NSAlert()
      alert.messageText = "Error Creating File"
      alert.informativeText = "Failed to create file list: \(error.localizedDescription)"
      alert.alertStyle = .warning
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
  }

  func load() {
    let recentLocations = UserDefaults.standard.stringArray(forKey: recentSaveLocationsKey) ?? []

    // If there are any recent locations, show a popup menu
    if recentLocations.count >= 1 {
      showRecentLocationsMenu()
    } else {
      // Otherwise, show the file dialog directly
      showLoadFileDialog()
    }
  }

  private func showRecentLocationsMenu() {
    let recentLocations = UserDefaults.standard.stringArray(forKey: recentSaveLocationsKey) ?? []

    // Create a helper class to handle menu actions
    class MenuHandler {
      var onSelectLocation: ((String) -> Void)?
      var onOpenDialog: (() -> Void)?

      @objc func selectLocation(_ sender: NSMenuItem) {
        if let locationString = sender.representedObject as? String {
          onSelectLocation?(locationString)
        }
      }

      @objc func openDialog() {
        onOpenDialog?()
      }
    }

    let handler = MenuHandler()
    handler.onSelectLocation = { [self] fileURLString in
      if let fileURL = URL(string: fileURLString) {
        // Load the file directly without showing dialog
        self.loadFilesFromURL(fileURL)
      }
    }
    handler.onOpenDialog = { [self] in
      self.showLoadFileDialog()
    }

    let menu = NSMenu()

    // Add recent locations as menu items
    for locationString in recentLocations {
      if let url = URL(string: locationString) {
        let path = url.path
        let displayName = truncatePath(path, maxLength: 50)
        let menuItem = NSMenuItem(title: displayName, action: #selector(MenuHandler.selectLocation(_:)), keyEquivalent: "")
        menuItem.representedObject = locationString
        menuItem.target = handler
        menu.addItem(menuItem)
      }
    }

    // Add separator
    menu.addItem(NSMenuItem.separator())

    // Add "Open File Dialog..." option
    let openDialogItem = NSMenuItem(title: "Open File Dialog...", action: #selector(MenuHandler.openDialog), keyEquivalent: "")
    openDialogItem.target = handler
    menu.addItem(openDialogItem)

    // Show the menu at the mouse cursor location (where the Load File button was clicked)
    let mouseLocation = NSEvent.mouseLocation
    menu.popUp(positioning: nil, at: mouseLocation, in: nil)

    // Keep handler alive
    objc_setAssociatedObject(menu, "handler", handler, .OBJC_ASSOCIATION_RETAIN)
  }

  private func loadFilesFromURL(_ yamlFileURL: URL) {
    let yamlFilePath = yamlFileURL.path
    // Derive the data file path by replacing .yaml extension with .data
    let dataFilePath = yamlFilePath.replacingOccurrences(of: ".yaml", with: ".data")

    Task.detached {
      do {
        //order is important, loadIndex first
        try await loadIndexFromYAML(filePath: yamlFilePath)
        try await loadRawFromFile(filePath: dataFilePath)

        // Update recent files with the full file URL and reset search bar
        await MainActor.run {
          updateRecentSaveLocations(with: yamlFileURL.absoluteString)
          searchText = "" // Reset search bar
        }

      } catch {
        print("Failed to load photo collection: \(error)")
        await MainActor.run {
          let alert = NSAlert()
          alert.messageText = "Load Failed"
          alert.informativeText = "Failed to load photo collection: \(error.localizedDescription)"
          alert.alertStyle = .warning
          alert.addButton(withTitle: "OK")
          alert.runModal()
        }
      }
    }
  }

  private func showLoadFileDialog(at directoryURL: URL? = nil) {
    let openPanel = NSOpenPanel()
    openPanel.canChooseFiles = true
    openPanel.canChooseDirectories = false
    openPanel.allowsMultipleSelection = false
    openPanel.allowedContentTypes = [.init(filenameExtension: "yaml")!]

    // Use provided directory or the most recent save location from preferences
    if let directory = directoryURL {
      openPanel.directoryURL = directory
    } else if let mostRecentLocation = getMostRecentSaveLocation() {
      openPanel.directoryURL = mostRecentLocation
    }

    if openPanel.runModal() == .OK {
      if let yamlFileURL = openPanel.url {
        loadFilesFromURL(yamlFileURL)
      }
    }
  }

  private func truncatePath(_ path: String, maxLength: Int) -> String {
    if path.count <= maxLength {
      return path
    }

    let keepLength = (maxLength - 3) / 2 // 3 for "..."
    let startPart = String(path.prefix(keepLength))
    let endPart = String(path.suffix(keepLength))
    return "\(startPart)...\(endPart)"
  }

  func save() {
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.init(filenameExtension: "yaml")!]
    savePanel.nameFieldStringValue = "file.yaml"

    // Use the most recent save location from preferences
    if let mostRecentLocation = getMostRecentSaveLocation() {
      savePanel.directoryURL = mostRecentLocation
    }

    if savePanel.runModal() == .OK {
      if let yamlFileURL = savePanel.url {
        let yamlFilePath = yamlFileURL.path
        // Derive the data file path by replacing .yaml extension with .data
        let dataFilePath = yamlFilePath.replacingOccurrences(of: ".yaml", with: ".data")

        Task.detached {
          do {
            //order is important, saveRaw first
            try await saveRawToFile(filePath: dataFilePath)
            try await saveIndexToYAML(filePath: yamlFilePath)

            // Update recent files with the full file URL and set isModified to false
            await MainActor.run {
              updateRecentSaveLocations(with: yamlFileURL.absoluteString)
              AppStateManager.shared.isModified = false
            }
          } catch {
            print("Failed to save photo collection: \(error)")
            await MainActor.run {
              let alert = NSAlert()
              alert.messageText = "Save Failed"
              alert.informativeText = "Failed to save photo collection: \(error.localizedDescription)"
              alert.alertStyle = .warning
              alert.addButton(withTitle: "OK")
              alert.runModal()
            }
          }
        }
      }
    }
  }

  // Called when the user clicks "Save File" in the quit confirmation dialog
  func saveAndQuit() {
    let savePanel = NSSavePanel()
    savePanel.allowedContentTypes = [.init(filenameExtension: "yaml")!]
    savePanel.nameFieldStringValue = "file.yaml"

    // Use the most recent save location from preferences
    if let mostRecentLocation = getMostRecentSaveLocation() {
      savePanel.directoryURL = mostRecentLocation
    }

    if savePanel.runModal() == .OK {
      if let yamlFileURL = savePanel.url {
        let yamlFilePath = yamlFileURL.path
        // Derive the data file path by replacing .yaml extension with .data
        let dataFilePath = yamlFilePath.replacingOccurrences(of: ".yaml", with: ".data")

        Task.detached {
          do {
            //order is important, saveRaw first
            try await saveRawToFile(filePath: dataFilePath)
            try await saveIndexToYAML(filePath: yamlFilePath)

            // Update recent files with the full file URL and set isModified to false
            await MainActor.run {
              updateRecentSaveLocations(with: yamlFileURL.absoluteString)
              AppStateManager.shared.isModified = false
              // Now quit the application
              NSApplication.shared.terminate(nil)
            }
          } catch {
            print("Failed to save photo collection: \(error)")
            await MainActor.run {
              let alert = NSAlert()
              alert.messageText = "Save Failed"
              alert.informativeText = "Failed to save photo collection: \(error.localizedDescription)"
              alert.alertStyle = .warning
              alert.addButton(withTitle: "OK")
              alert.runModal()
            }
          }
        }
      }
    }
    // If user cancels the save dialog, don't quit
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

    } catch {
      print("Error writing to file: \(error)")
      throw error
    }
  }

  func saveIndexToYAML(filePath: String) throws {
    if photoAssets.isEmpty {
      let alert = NSAlert()
      alert.messageText = "No Thumbnails"
      alert.informativeText = "No thumbnails are saved."
      alert.alertStyle = .informational
      alert.addButton(withTitle: "OK")
      alert.runModal()
    }
    else {
      do {
        let fileURL = URL(fileURLWithPath: filePath)
        let encoder = YAMLEncoder()
        let yamlString = try encoder.encode(photoAssets)
        try yamlString.write(to: fileURL, atomically: true, encoding: .utf8)

      } catch {
        print("Error saving index: \(error)")
        throw error
      }
    }
  }

  func loadIndexFromYAML(filePath: String) async throws {
    let fileURL = URL(fileURLWithPath: filePath)
    do {
      let yamlString = try String(contentsOf: fileURL, encoding: .utf8)
      let decoder = YAMLDecoder()
      photoAssets = try decoder.decode([PhotoAsset].self, from: yamlString)

      // Set loadedFolderURL to the directory of the first photoAsset
      if let firstAsset = photoAssets.first {
        await MainActor.run {
          loadedFolderURL = firstAsset.url.deletingLastPathComponent()
        }
      } else {
        // Show message box when no thumbnails are loaded
        await MainActor.run {
          let alert = NSAlert()
          alert.messageText = "No Thumbnails"
          alert.informativeText = "No thumbnails are loaded."
          alert.alertStyle = .informational
          alert.addButton(withTitle: "OK")
          alert.runModal()
        }
      }

    } catch {
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

  // Helper function to rebuild the URL index for O(1) lookups
  private func rebuildURLIndex() {
    photoAssetURLIndex.removeAll()
    for (index, asset) in photoAssets.enumerated() {
      photoAssetURLIndex[asset.url] = index
    }
  }
  
  func remove_nonexist_thumbnails() {
    let fileManager = FileManager.default
    photoAssets.removeAll { asset in
      let fileURL = asset.url
      if fileManager.fileExists(atPath: fileURL.path) {
        return false // Keep the asset
      } else {
        print("removing thumbnail as file does not exist \(asset.url)")
        return true // Remove the asset
      }
    }
    // Rebuild index after removing assets
    rebuildURLIndex()
  }

  func generateThumbnails(from folderURL: URL)  {
    if loadedFolderURL != nil && loadedFolderURL != folderURL {
      photoAssets.removeAll()
    }
    loadedFolderURL = folderURL // Store for reloading

    //scan the photoassets and remove files that do not exist
    remove_nonexist_thumbnails()


    let fileManager = FileManager.default
    let directoryURL = folderURL

    // Check if the directory exists and is accessible
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      print("Error: '\(directoryURL)' is not a valid directory or is inaccessible.")
      // Show an alert or update the UI to indicate the error.
      return
    }

    Task {
      await MainActor.run {
        isLoading = true
      }
      let resourceKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey]
      guard let enumerator = fileManager.enumerator(at: directoryURL,
                                                    includingPropertiesForKeys: resourceKeys,
                                                    options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants, .skipsPackageDescendants],
                                                    errorHandler: { (url, error) -> Bool in
        print("Error enumerating '\(url.path)': \(error)")
        return true // return true means continue the enumeration even if there are errors with some files.
      }) else {
        //show error and alert
        print("Error: enumerator is nil")
        await MainActor.run {
          isLoading = false
        }
        return
      }

      for fileURL in enumerator.compactMap({ $0 as? URL }) {
        let resourceValues = try fileURL.resourceValues(forKeys: Set(resourceKeys))

        //check if the file exists and that it is not a directory
        guard resourceValues.isRegularFile == true else { continue }

        //check file extensions
        let fileExtension = fileURL.pathExtension.lowercased()
        guard fileExtension == "mp4" else { continue }

        //if the thumbnail exists and file has not changed then skip to next - O(1) lookup
        let temp_Asset = PhotoAsset(url: fileURL)
        if let foundIndex = photoAssetURLIndex[fileURL] {
          let foundAsset = photoAssets[foundIndex]
          if temp_Asset.modificationDate == foundAsset.modificationDate &&
              temp_Asset.fileSize == foundAsset.fileSize {

            continue
          } else {
            //file exists but either size or modificationDate has changed, remove the existing thumbnail

            photoAssets.remove(at: foundIndex)
            photoAssetURLIndex.removeValue(forKey: fileURL)
            // Rebuild index since indices shifted
            rebuildURLIndex()
          }
        }

        let request = QLThumbnailGenerator.Request(fileAt: fileURL,
                                                   size: CGSize(width: 256, height: 256),
                                                   scale: NSScreen.main?.backingScaleFactor ?? 1,
                                                   representationTypes: .thumbnail)
        let thumbnail = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
        await MainActor.run {
          photoAssets.append(.init(url: fileURL, thumbnail: imageToData(thumbnail.nsImage)!))
          AppStateManager.shared.isModified = true
        }

      }//end for loop

      await MainActor.run {
        isLoading = false
        searchText = "" // Reset search bar

        if photoAssets.isEmpty {
          let alert = NSAlert()
          alert.messageText = "No Thumbnails"
          alert.informativeText = "No thumbnails are loaded from the specified location."
          alert.alertStyle = .informational
          alert.addButton(withTitle: "OK")
          alert.runModal()
        }
        //print("set isLoading = \(isLoading). line \(#line) at func \(#function)")
      }

    }


  }//func generateThumbnails

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

struct PhotoAsset: Identifiable, Codable, Sendable {
  let id: String
  let url: URL
  var fileName: String { return url.lastPathComponent.isEmpty ? "/" : url.lastPathComponent }
  var thumbnail: Data?
  var modificationDate: Date?
  var fileSize: UInt64?
  var thumbnail_offset: UInt64?
  var thumbnail_len: UInt64?
  var isLiked: Bool = false
  var lastPlayDate: Date?

  init(url: URL) {
    self.id = UUID().uuidString
    self.url = url
    self.modificationDate = PhotoAsset.getModificationDate(for: url)
    self.fileSize = PhotoAsset.getFileSize(for: url)
    self.isLiked = false
    self.lastPlayDate = nil
  }

  init(url: URL, thumbnail: Data) {
    self.init(url: url)
    self.thumbnail = thumbnail
  }

  static func getModificationDate(for url: URL) -> Date? {
    do {
      let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
      return attributes[.modificationDate] as? Date
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
    case id, url, modificationDate, fileSize, thumbnail_offset, thumbnail_len, isLiked, lastPlayDate
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(url.absoluteString, forKey: .url)
    try container.encode(modificationDate, forKey: .modificationDate)
    try container.encode(fileSize, forKey: .fileSize)
    try container.encode(thumbnail_offset, forKey: .thumbnail_offset)
    try container.encode(thumbnail_len, forKey: .thumbnail_len)
    try container.encode(isLiked, forKey: .isLiked)
    try container.encodeIfPresent(lastPlayDate, forKey: .lastPlayDate)
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    let urlString = try container.decode(String.self, forKey: .url)
    guard let url = URL(string: urlString) else {
      throw DecodingError.dataCorruptedError(forKey: .url, in: container, debugDescription: "Invalid URL string")
    }
    self.url = url

    modificationDate = try container.decode(Date.self, forKey: .modificationDate)
    fileSize = try container.decode(UInt64.self, forKey: .fileSize)
    thumbnail_offset = try container.decode(UInt64.self, forKey: .thumbnail_offset)
    thumbnail_len = try container.decode(UInt64.self, forKey: .thumbnail_len)
    isLiked = try container.decodeIfPresent(Bool.self, forKey: .isLiked) ?? false
    lastPlayDate = try container.decodeIfPresent(Date.self, forKey: .lastPlayDate)
  }
}//struct PhotoAsset
