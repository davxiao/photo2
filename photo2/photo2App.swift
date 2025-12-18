//
//  photo2App.swift
//  photo2
//
//  Created by David Xiao on 3/1/25.
//

import SwiftUI
import AppKit

// App Delegate to handle application lifecycle events
class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    // Check if there are unsaved changes
    if AppStateManager.shared.isModified {
      // Show dialog with 3 options
      let alert = NSAlert()
      alert.messageText = "Unsaved Changes"
      alert.informativeText = "You have unsaved changes. What would you like to do?"
      alert.alertStyle = .warning
      
      // Add buttons in order (first button is default, index 1000)
      alert.addButton(withTitle: "Save File")           // NSApplication.ModalResponse.alertFirstButtonReturn (1000)
      alert.addButton(withTitle: "Discard changes and quit")  // NSApplication.ModalResponse.alertSecondButtonReturn (1001)
      alert.addButton(withTitle: "Cancel")              // NSApplication.ModalResponse.alertThirdButtonReturn (1002)
      
      let response = alert.runModal()
      
      switch response {
      case .alertFirstButtonReturn:
        // Save File - trigger save and then quit
        // Post notification to trigger save in ContentView
        NotificationCenter.default.post(name: NSNotification.Name("SaveAndQuit"), object: nil)
        // For now, cancel termination and let the save handler quit after saving
        return .terminateCancel
        
      case .alertSecondButtonReturn:
        // Discard changes and quit
        return .terminateNow
        
      case .alertThirdButtonReturn:
        // Cancel - don't quit
        return .terminateCancel
        
      default:
        return .terminateCancel
      }
    }
    
    // No unsaved changes, allow termination
    return .terminateNow
  }
}

@main
struct photo2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
  
  var body: some Scene {
    WindowGroup {
      ContentView()
    }
  }
}
