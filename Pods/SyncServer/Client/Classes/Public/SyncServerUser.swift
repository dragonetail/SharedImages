//
//  SyncServerUser.swift
//  SyncServer
//
//  Created by Christopher Prince on 12/2/16.
//  Copyright © 2016 Spastic Muffin, LLC. All rights reserved.
//

import Foundation
import SMCoreLib
import SyncServer_Shared

public class SyncServerUser {
    var desiredEvents:EventDesired!
    weak var delegate:SyncServerDelegate!

    public var creds:GenericCredentials? {
        didSet {
            ServerAPI.session.creds = creds
            if let _ = creds {
                setupSharingGroups()
            }
            else {
                sharingGroupIds = nil
            }
        }
    }
    
    // Persisting this in the keychain for security-- I'd rather this identifier wasn't known to more folks than need it.
    static let syncServerUserId = SMPersistItemString(name: "SyncServerUser.syncServerUserId", initialStringValue: "", persistType: .keyChain)
    
    /// A unique identifier for the user on the SyncServer system. If creds are set this will be set.
    public var syncServerUserId:String? {
        if SyncServerUser.syncServerUserId.stringValue == "" {
            return nil
        }
        else {
            return SyncServerUser.syncServerUserId.stringValue
        }
    }
    
    static let sharingGroupIds = SMPersistItemData(name: "SyncServerUser.sharingGroupIds", initialDataValue: Data(), persistType: .userDefaults)
    
    /// This is set at app launch, and is an error if a user is signed in and there are no sharingGroupIds.
    public internal(set) var sharingGroupIds: [SharingGroupId]? {
        get {
            if SyncServerUser.sharingGroupIds.dataValue == Data() {
                return nil
            }
            else {
                let ids = NSKeyedUnarchiver.unarchiveObject(with: SyncServerUser.sharingGroupIds.dataValue) as? [SharingGroupId]
                return ids
            }
        }
        set {
            var newArchive:Data!
            if newValue == nil {
                newArchive = Data()
            }
            else {
                newArchive = NSKeyedArchiver.archivedData(withRootObject: newValue!)
            }
            SyncServerUser.sharingGroupIds.dataValue = newArchive
        }
    }
    
    public private(set) var cloudFolderName:String?
    
    public static let session = SyncServerUser()
    
    func appLaunchSetup(cloudFolderName:String?) {
        self.cloudFolderName = cloudFolderName
    }

    // A distinct UUID for this user mobile device.
    // I'm going to persist this in the keychain not so much because it needs to be secure, but rather because it will survive app deletions/reinstallations.
    static let mobileDeviceUUID = SMPersistItemString(name: "SyncServerUser.mobileDeviceUUID", initialStringValue: "", persistType: .keyChain)
    
    private init() {
        // Check to see if the device has a UUID already.
        if SyncServerUser.mobileDeviceUUID.stringValue.count == 0 {
            SyncServerUser.mobileDeviceUUID.stringValue = UUID.make()
        }
        
        ServerAPI.session.delegate = self
    }
    
    public enum CheckForExistingUserResult {
        case noUser
        case user(permission:Permission, accessToken:String?)
    }
    
    fileprivate func showAlert(with title:String, and message:String? = nil) {
        let window = UIApplication.shared.keyWindow
        let rootViewController = window?.rootViewController
        let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
        alert.popoverPresentationController?.sourceView = rootViewController?.view
        alert.addAction(UIAlertAction(title: "OK", style: .cancel, handler: nil))
        
        Thread.runSync(onMainThread: {
            rootViewController?.present(alert, animated: true, completion: nil)
        })
    }
    
    private func setupSharingGroups() {
        ServerAPI.session.getSharingGroups { sharingGroupIds, error in
            if error == nil, let sharingGroupIds = sharingGroupIds {
                self.sharingGroupIds = sharingGroupIds
                Log.msg("Sharing group ids: \(sharingGroupIds)")
                EventDesired.reportEvent(.haveSharingGroupIds, mask: self.desiredEvents, delegate: self.delegate)
                Migrations.session.runAfterSharingGroupSetup()
            }
            else {
                Log.error("Error getting sharing group ids: \(String(describing: error))")
            }
        }
    }
    
    /// Calls the server API method to check credentials.
    public func checkForExistingUser(creds: GenericCredentials,
        completion:@escaping (_ result: CheckForExistingUserResult?, Error?) ->()) {
        
        // Have to do this before call to `checkCreds` because it sets up creds with the ServerAPI.
        ServerAPI.session.creds = creds
        Log.msg("SignInCreds: \(creds)")
        
        ServerAPI.session.checkCreds {[unowned self] (checkCredsResult, error) in
            var checkForUserResult:CheckForExistingUserResult?
            var errorResult:Error? = error
            
            switch checkCredsResult {
            case .none:
                ServerAPI.session.creds = nil
                // Don't sign the user out here. Callers of `checkForExistingUser` (e.g., GoogleSignIn or FacebookSignIn) can deal with this.
                Log.error("Had an error: \(String(describing: error))")
                errorResult = error
            
            case .some(.noUser):
                ServerAPI.session.creds = nil
                // Definitive result from server-- there was no user. Still, I'm not going to sign the user out here. Callers can do that.
                checkForUserResult = .noUser
                
            case .some(.user(let syncServerUserId, let permission, let accessToken)):
                self.creds = creds
                checkForUserResult = .user(permission: permission, accessToken:accessToken)
                SyncServerUser.syncServerUserId.stringValue = "\(syncServerUserId)"
            }
            
            if case .some(.noUser) = checkForUserResult {
                Thread.runSync(onMainThread: {
                    self.showAlert(with: "\(creds.uiDisplayName) doesn't exist on the system.", and: "You can sign in as a \"New user\", or get a sharing invitation from another user.")
                })
            }
            else if errorResult != nil {
                Thread.runSync(onMainThread: {
                    self.showAlert(with: "Error trying to sign in: \(errorResult!)")
                })
            }
            
            Thread.runSync(onMainThread: {
                completion(checkForUserResult, errorResult)
            })
        }
    }
    
    /// Calls the server API method to add a user.
    public func addUser(creds: GenericCredentials, completion:@escaping (SharingGroupId?, Error?) ->()) {
        Log.msg("SignInCreds: \(creds)")

        ServerAPI.session.creds = creds
        ServerAPI.session.addUser(cloudFolderName: cloudFolderName) { syncServerUserId, sharingGroupId, error in
            if error == nil {
                self.creds = creds
                if let syncServerUserId = syncServerUserId  {
                    SyncServerUser.syncServerUserId.stringValue = "\(syncServerUserId)"
                }
            }
            else {
                Log.error("Error: \(String(describing: error))")
                ServerAPI.session.creds = nil
                Thread.runSync(onMainThread: {
                    self.showAlert(with: "Failed adding user \(creds.uiDisplayName).", and: "Error was: \(error!).")
                })
            }
            
            Thread.runSync(onMainThread: {
                completion(sharingGroupId, error)
            })
        }
    }
    
    /// Calls the server API method to create a sharing invitation.
    public func createSharingInvitation(withPermission permission:Permission, sharingGroupId: SharingGroupId, completion:((_ invitationCode:String?, Error?)->(Void))?) {

        ServerAPI.session.createSharingInvitation(withPermission: permission, sharingGroupId: sharingGroupId) { (sharingInvitationUUID, error) in
            Thread.runSync(onMainThread: {
                completion?(sharingInvitationUUID, error)
            })
        }
    }
    
    /// Calls the server API method to redeem a sharing invitation.
    public func redeemSharingInvitation(creds: GenericCredentials, invitationCode:String, cloudFolderName: String?, completion:((_ accessToken:String?, _ sharingGroupId: SharingGroupId?, Error?)->())?) {
        
        ServerAPI.session.creds = creds
        
        ServerAPI.session.redeemSharingInvitation(sharingInvitationUUID: invitationCode, cloudFolderName: cloudFolderName) { accessToken, sharingGroupId, error in
            if error == nil {
                self.creds = creds
            }
            else {
                ServerAPI.session.creds = nil
            }
            
            Thread.runSync(onMainThread: {
                completion?(accessToken, sharingGroupId, error)
            })
        }
    }
}

extension SyncServerUser : ServerAPIDelegate {    
    func deviceUUID(forServerAPI: ServerAPI) -> Foundation.UUID {
        return Foundation.UUID(uuidString: SyncServerUser.mobileDeviceUUID.stringValue)!
    }
    
    // 1/3/18 somewhat before 9am MST; Bushrod just got this after installing v0.10.0 of SharedImages, "I just upgraded sharedimages. When i launched it, it said it was having trouble authenticating me and that I should log out and back in. I didn’t do that, changed to the login tab, back to the images tab, and it downloaded new images so I guess the sticky login worked despite the complaining."
    func userWasUnauthorized(forServerAPI: ServerAPI) {
        Thread.runSync(onMainThread: {
            self.showAlert(with: "The server is having problems authenticating you. You may need to sign out and sign back in.")
        })
    }

#if DEBUG
    func doneUploadsRequestTestLockSync(forServerAPI: ServerAPI) -> TimeInterval? {
        return nil
    }
    
    func fileIndexRequestServerSleep(forServerAPI: ServerAPI) -> TimeInterval? {
        return nil
    }
#endif
}


