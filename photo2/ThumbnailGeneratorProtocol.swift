// This file should be added to both the main app and XPC service targets

import Foundation

// Protocol that defines the interface for the XPC service
@objc public protocol ThumbnailGeneratorProtocol {
    // Generate thumbnails for video files in a directory
    func generateThumbnails(fromDirectory path: String, 
                           completion: @escaping ([ThumbnailResult]?, Error?) -> Void)
    
    // Optional: Add a method to cancel ongoing operations
    func cancelOperations(completion: @escaping () -> Void)
}

// Data structure to hold thumbnail results - needs to be NSObject, NSSecureCoding, and Sendable for XPC
@objc public final class ThumbnailResult: NSObject, NSSecureCoding, @unchecked Sendable {
    // Make this property a constant (let) to ensure it's immutable
    @objc public static let supportsSecureCoding: Bool = true
    
    public let id: String
    public let urlString: String
    public let thumbnailData: Data
    public let creationDate: Date?
    public let fileSize: NSNumber?
    
    public init(id: String, urlString: String, thumbnailData: Data, creationDate: Date?, fileSize: UInt64?) {
        self.id = id
        self.urlString = urlString
        self.thumbnailData = thumbnailData
        self.creationDate = creationDate
        self.fileSize = fileSize != nil ? NSNumber(value: fileSize!) : nil
        
        super.init()
    }
    
    // NSSecureCoding implementation
    public func encode(with coder: NSCoder) {
        coder.encode(id, forKey: "id")
        coder.encode(urlString, forKey: "urlString")
        coder.encode(thumbnailData, forKey: "thumbnailData")
        coder.encode(creationDate, forKey: "creationDate")
        coder.encode(fileSize, forKey: "fileSize")
    }
    
    public required init?(coder: NSCoder) {
        id = coder.decodeObject(of: NSString.self, forKey: "id") as String? ?? UUID().uuidString
        urlString = coder.decodeObject(of: NSString.self, forKey: "urlString") as String? ?? ""
        thumbnailData = coder.decodeObject(of: NSData.self, forKey: "thumbnailData") as Data? ?? Data()
        creationDate = coder.decodeObject(of: NSDate.self, forKey: "creationDate") as Date?
        fileSize = coder.decodeObject(of: NSNumber.self, forKey: "fileSize")
        
        super.init()
    }
}

// Error types - needs to be NSError for Objective-C compatibility
@objc public enum ThumbnailGeneratorErrorCode: Int {
    case directoryNotFound = 1
    case accessDenied = 2
    case processingFailed = 3
}

// NSXPCConnection helper extension
extension NSXPCConnection {
    public static func makeServiceConnection() -> NSXPCConnection {
        let connection = NSXPCConnection(serviceName: "com.yourcompany.ThumbnailGeneratorService")
        connection.remoteObjectInterface = NSXPCInterface(with: ThumbnailGeneratorProtocol.self)
        return connection
    }
} 
