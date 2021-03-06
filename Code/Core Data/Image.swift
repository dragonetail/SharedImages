//
//  Image+CoreDataClass.swift
//  SharedImages
//
//  Created by Christopher Prince on 3/10/17.
//  Copyright © 2017 Spastic Muffin, LLC. All rights reserved.
//

import Foundation
import CoreData
import SMCoreLib
import SyncServer_Shared

// 5/13/18-- The discussionUUID is old as of today. The fileGroupUUID property is the new way to connect discussion and image.

@objc(Image)
public class Image: NSManagedObject {
    static let CREATION_DATE_KEY = "creationDate"
    static let UUID_KEY = "uuid"
    static let DISCUSSION_UUID_KEY = "discussionUUID"
    static let FILE_GROUP_UUID_KEY = "fileGroupUUID"
    static let UNREAD_COUNT = "discussion.unreadCount"
    
    public var sharingGroupId: SharingGroupId? {
        get {
            return sharingGroupIdInternal?.int64Value
        }
        
        set {
            sharingGroupIdInternal = newValue == nil ? nil : NSNumber(value: newValue!)
        }
    }
    
    var originalSize:CGSize {
        var originalImageSize = CGSize()

        // Originally, I wasn't storing these sizes, so need to grab & store them here if we can. (Defaults for sizes are -1).
        if originalWidth < 0 || originalHeight < 0 {
            originalImageSize = ImageExtras.sizeFromFile(url: url! as URL)
            originalWidth = Float(originalImageSize.width)
            originalHeight = Float(originalImageSize.height)
            CoreData.sessionNamed(CoreDataExtras.sessionName).saveContext()
        }
        else {
            originalImageSize.height = CGFloat(originalHeight)
            originalImageSize.width = CGFloat(originalWidth)
        }
        
        return originalImageSize
    }
    
    var url:SMRelativeLocalURL? {
        get {
            return CoreData.getSMRelativeLocalURL(fromCoreDataProperty: urlInternal as Data?)
        }
        
        set {            
            if newValue == nil {
                urlInternal = nil
            }
            else {
                urlInternal = NSKeyedArchiver.archivedData(withRootObject: newValue!) as NSData?
            }
        }
    }

    class func entityName() -> String {
        return "Image"
    }

    class func newObjectAndMakeUUID(makeUUID: Bool, creationDate:NSDate? = nil) -> NSManagedObject {
        let image = CoreData.sessionNamed(CoreDataExtras.sessionName).newObject(withEntityName: self.entityName()) as! Image
        
        if makeUUID {
            image.uuid = UUID.make()
        }
        
        if creationDate == nil {
            image.creationDate = NSDate()
        }
        else {
            image.creationDate = creationDate
        }
        
        return image
    }
    
    class func newObject() -> NSManagedObject {
        return newObjectAndMakeUUID(makeUUID: false)
    }
    
    struct SortFilterParams {
        let sortingOrder: Parameters.SortOrder
        let isAscending: Bool
        let unreadCounts: Parameters.UnreadCounts
    }
    
    class func fetchRequestForAllObjects(params:SortFilterParams) -> NSFetchRequest<NSFetchRequestResult>? {
        var fetchRequest: NSFetchRequest<NSFetchRequestResult>?
        fetchRequest = CoreData.sessionNamed(CoreDataExtras.sessionName).fetchRequest(withEntityName: self.entityName(), modifyingFetchRequestWith: { request in
            
            var subpredicates = [NSPredicate]()
            
            switch params.unreadCounts {
            case .all:
                break
                
            case .unread:
                subpredicates += [NSPredicate(format: "(%K > 0)", UNREAD_COUNT)]
            }
            
            if subpredicates.count > 0 {
                let compoundPredicate = NSCompoundPredicate(andPredicateWithSubpredicates: subpredicates)
                request.predicate = compoundPredicate
            }
        })
        
        if fetchRequest != nil {
            var sortDescriptor:NSSortDescriptor!
            
            switch params.sortingOrder {
            case .creationDate:
                sortDescriptor = NSSortDescriptor(key: CREATION_DATE_KEY, ascending: params.isAscending)
            }
            
            fetchRequest!.sortDescriptors = [sortDescriptor]
        }
        
        return fetchRequest
    }
    
    class func fetchObjectWithUUID(_ uuid:String) -> Image? {
        let managedObject = CoreData.fetchObjectWithUUID(uuid, usingUUIDKey: UUID_KEY, fromEntityName: self.entityName(), coreDataSession: CoreData.sessionNamed(CoreDataExtras.sessionName))
        return managedObject as? Image
    }
    
    class func fetchObjectWithDiscussionUUID(_ discussionUUID:String) -> Image? {
        let managedObject = CoreData.fetchObjectWithUUID(discussionUUID, usingUUIDKey: DISCUSSION_UUID_KEY, fromEntityName: self.entityName(), coreDataSession: CoreData.sessionNamed(CoreDataExtras.sessionName))
        return managedObject as? Image
    }
    
    class func fetchObjectWithFileGroupUUID(_ fileGroupUUID:String) -> Image? {
        let managedObject = CoreData.fetchObjectWithUUID(fileGroupUUID, usingUUIDKey: FILE_GROUP_UUID_KEY, fromEntityName: self.entityName(), coreDataSession: CoreData.sessionNamed(CoreDataExtras.sessionName))
        return managedObject as? Image
    }
    
    static func fetchAll() -> [Image] {
        var images:[Image]!

        do {
            images = try CoreData.sessionNamed(CoreDataExtras.sessionName).fetchAllObjects(withEntityName: self.entityName()) as? [Image]
        } catch (let error) {
            Log.error("Error: \(error)")
            assert(false)
        }
        
        return images
    }
    
    func save() {
        CoreData.sessionNamed(CoreDataExtras.sessionName).saveContext()
    }
    
    // Also removes associated discussion.
    func remove() throws {
        if let discussion = discussion {
            try discussion.remove()
        }
        
        if let url = url {
            try FileManager.default.removeItem(at: url as URL)
        }
        
        CoreData.sessionNamed(CoreDataExtras.sessionName).remove(self)
    }
}

extension Image : CacheDataSource {
    func keyFor(args size:CGSize) -> String {
        // Using as the key:
        // <filename>.<W>x<H>
        let filename = ImageExtras.imageFileName(url: url! as URL)
        return "\(filename).\(size.width)x\(size.height)"
    }
    
    func cacheDataFor(args size:CGSize) -> UIImage {
        return ImageStorage.getImage(ImageExtras.imageFileName(url: url! as URL), of: size, fromIconDirectory: ImageExtras.iconDirectoryURL, withLargeImageDirectory: ImageExtras.largeImageDirectoryURL)
    }
    
    func costFor(_ item: UIImage) -> Int? {
        // An approximation of the memory space used.
        return item.cgImage!.height * item.cgImage!.bytesPerRow
    }

#if DEBUG
    func cachedItem(_ item:UIImage) {}
    func evictedItemFromCache(_ item:UIImage) {
        Log.msg("Evicted image from cache.")
    }
#endif
}

