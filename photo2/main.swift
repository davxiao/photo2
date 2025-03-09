import Foundation

// Set up the XPC listener
let delegate = ServiceDelegate()
let listener = NSXPCListener.service()
listener.delegate = delegate
listener.resume()

// Keep the service running
RunLoop.current.run()

// Service delegate class
class ServiceDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Configure the connection
        let exportedObject = ThumbnailGeneratorService()
        connection.exportedInterface = NSXPCInterface(with: ThumbnailGeneratorProtocol.self)
        connection.exportedObject = exportedObject
        
        // Accept the connection
        connection.resume()
        return true
    }
} 