//
//  SonyPTPIPCamera.swift
//  Rocc
//
//  Created by Simon Mitchell on 02/11/2019.
//  Copyright © 2019 Simon Mitchell. All rights reserved.
//

import Foundation

internal final class SonyPTPIPCameraDevice: SonyCamera {
    
    var ipAddress: sockaddr_in? = nil
    
    var apiVersion: String? = nil
    
    var baseURL: URL?
    
    var manufacturer: String
    
    var name: String?
    
    var model: String? = nil
    
    var firmwareVersion: String? = nil
    
    public var latestFirmwareVersion: String? {
        return modelEnum?.latestFirmwareVersion
    }
    
    var remoteAppVersion: String? = nil
    
    var latestRemoteAppVersion: String? = nil
    
    var lensModelName: String? = nil
        
    var supportsPolledEvents: Bool = false
    
    var connectionMode: ConnectionMode = .remoteControl
    
    let apiDeviceInfo: ApiDeviceInfo
    
    var ptpIPClient: PTPIPClient?
    
    struct ApiDeviceInfo {
        
        let liveViewURL: URL
        
        var defaultFunction: String?
                
        init?(dictionary: [AnyHashable : Any]) {
            
            guard let imagingDevice = dictionary["av:X_ScalarWebAPI_ImagingDevice"] as? [AnyHashable : Any] else {
                return nil
            }
            
            guard let liveViewURLString = imagingDevice["av:X_ScalarWebAPI_LiveView_URL"] as? String else {
                return nil
            }
            guard let liveViewURL = URL(string: liveViewURLString) else {
                return nil
            }
            
            self.liveViewURL = liveViewURL
            defaultFunction = imagingDevice["av:X_ScalarWebAPI_DefaultFunction"] as? String
        }
    }
    
    //MARK: - Initialisation -
    
    override init?(dictionary: [AnyHashable : Any]) {
        
        guard let apiDeviceInfoDict = dictionary["av:X_ScalarWebAPI_DeviceInfo"] as? [AnyHashable : Any], let apiInfo = ApiDeviceInfo(dictionary: apiDeviceInfoDict) else {
            return nil
        }
        
        apiDeviceInfo = apiInfo
        manufacturer = dictionary["manufacturer"] as? String ?? "Sony"
        
        super.init(dictionary: dictionary)
        
//        apiClient = SonyCameraAPIClient(apiInfo: apiDeviceInfo)
//        apiVersion = apiDeviceInfo.version

        name = dictionary["friendlyName"] as? String

        if let model = model {
            modelEnum = Model(rawValue: model)
        } else {
            modelEnum = nil
        }

        model = modelEnum?.friendlyName
    }
    
    var isConnected: Bool = false
    
    var deviceInfo: PTP.DeviceInfo?
    
    var extDeviceInfo: PTP.SDIOExtDeviceInfo?
    
    override func update(with deviceInfo: SonyDeviceInfo?) {
        name = modelEnum == nil ? name : (deviceInfo?.model?.friendlyName ?? name)
        modelEnum = deviceInfo?.model ?? modelEnum
        if let modelEnum = deviceInfo?.model {
            model = modelEnum.friendlyName
        }
        lensModelName = deviceInfo?.lensModelName
        firmwareVersion = deviceInfo?.firmwareVersion
    }
    
    //MARK: - Handshake methods -
    
    private func sendStartSessionPacket(completion: @escaping SonyPTPIPCameraDevice.ConnectedCompletion) {
        
        // First argument here is the session ID. We don't need a transaction ID because this is the "first"
        // command we send and so we can use the default 0 value the function provides.
        let packet = Packet.commandRequestPacket(code: .openSession, arguments: [0x00000001])
        ptpIPClient?.sendCommandRequestPacket(packet, callback: { [weak self] (response) in
            guard response.code == .okay else {
                completion(PTPError.commandRequestFailed, false)
                return
            }
            self?.getDeviceInfo(completion: completion)
        }, callCallbackForAnyResponse: true)
    }
    
    private func getDeviceInfo(completion: @escaping SonyPTPIPCameraDevice.ConnectedCompletion) {
        
        let packet = Packet.commandRequestPacket(code: .getDeviceInfo, arguments: nil, transactionId: 1)
        ptpIPClient?.awaitDataFor(transactionId: 1, callback: { [weak self] (dataContainer) in
            guard let deviceInfo = PTP.DeviceInfo(data: dataContainer.data) else {
                completion(PTPError.fetchDeviceInfoFailed, false)
                return
            }
            self?.deviceInfo = deviceInfo
            self?.performSdioConnect(completion: completion)
        })
        ptpIPClient?.sendCommandRequestPacket(packet, callback: nil)
    }
    
    private func performSdioConnect(completion: @escaping SonyPTPIPCameraDevice.ConnectedCompletion) {
        
        //TODO: Try and find out what the arguments are for this!
        let packet = Packet.commandRequestPacket(code: .sdioConnect, arguments: [0x0001, 0x0000, 0x0000], transactionId: 2)
        ptpIPClient?.awaitDataFor(transactionId: packet.transactionId, callback: { [weak self] (dataContainer) in
            //TODO: Currently not idea what we need to do with this!
            self?.getSdioExtDeviceInfo(completion: completion)
        })
        ptpIPClient?.sendCommandRequestPacket(packet, callback: nil)
    }
    
    private func getSdioExtDeviceInfo(completion: @escaping SonyPTPIPCameraDevice.ConnectedCompletion) {
        
        let packet = Packet.commandRequestPacket(code: .sdioGetExtDeviceInfo, arguments: [0x0000012c], transactionId: 3)
        ptpIPClient?.awaitDataFor(transactionId: packet.transactionId, callback: { [weak self] (dataContainer) in
            guard let extDeviceInfo = PTP.SDIOExtDeviceInfo(data: dataContainer.data) else {
                completion(PTPError.fetchSdioExtDeviceInfoFailed, false)
                return
            }
            self?.extDeviceInfo = extDeviceInfo
            completion(nil, false)
        })
    }
    
    enum PTPError: Error {
        case commandRequestFailed
        case fetchDeviceInfoFailed
        case fetchSdioExtDeviceInfoFailed
        case sdioExtDeviceInfoNotAvailable
    }
}

//MARK: - Camera protocol conformance -

extension SonyPTPIPCameraDevice: Camera {
    
    func connect(completion: @escaping SonyPTPIPCameraDevice.ConnectedCompletion) {
        
        ptpIPClient = PTPIPClient(camera: self)
        ptpIPClient?.connect(callback: { [weak self] (error) in
            self?.sendStartSessionPacket(completion: completion)
        })
    }
    
    func supportsFunction<T>(_ function: T, callback: @escaping ((Bool?, Error?, [T.SendType]?) -> Void)) where T : CameraFunction {
        guard let sdioExtDeviceInfo = extDeviceInfo else {
            callback(nil, PTPError.sdioExtDeviceInfoNotAvailable, nil)
            return
        }
    }
    
    func isFunctionAvailable<T>(_ function: T, callback: @escaping ((Bool?, Error?, [T.SendType]?) -> Void)) where T : CameraFunction {
        
    }
    
    func makeFunctionAvailable<T>(_ function: T, callback: @escaping ((Error?) -> Void)) where T : CameraFunction {
        
    }
    
    func performFunction<T>(_ function: T, payload: T.SendType?, callback: @escaping ((Error?, T.ReturnType?) -> Void)) where T : CameraFunction {
        
    }
    
    func loadFilesToTransfer(callback: @escaping ((Error?, [File]?) -> Void)) {
        
    }
    
    func finishTransfer(callback: @escaping ((Error?) -> Void)) {
        
    }
    
    func handleEvent(event: CameraEvent) {
        
    }
}
