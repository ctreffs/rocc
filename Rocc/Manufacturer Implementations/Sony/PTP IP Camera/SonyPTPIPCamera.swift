//
//  SonyPTPIPCamera.swift
//  Rocc
//
//  Created by Simon Mitchell on 02/11/2019.
//  Copyright © 2019 Simon Mitchell. All rights reserved.
//

import Foundation
import os.log

internal final class SonyPTPIPDevice: SonyCamera {
    
    let log = OSLog(subsystem: "com.yellow-brick-bear.rocc", category: "SonyPTPIPCamera")
    
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
    
    var onEventAvailable: (() -> Void)?
    
    var onDisconnected: (() -> Void)?
    
    var zoomingDirection: Zoom.Direction?
        
    var eventPollingMode: PollingMode {
        guard let deviceInfo = deviceInfo else { return .timed }
        return deviceInfo.supportedEventCodes.contains(.propertyChanged) ? .cameraDriven : .timed
    }
    
    var connectionMode: ConnectionMode = .remoteControl
    
    let apiDeviceInfo: ApiDeviceInfo
    
    private var cachedPTPIPClient: PTPIPClient?
    
    var ptpIPClient: PTPIPClient? {
        get {
            if let cachedPTPIPClient = cachedPTPIPClient {
                return cachedPTPIPClient
            }
            cachedPTPIPClient = PTPIPClient(camera: self)
            return cachedPTPIPClient
        }
        set {
            cachedPTPIPClient = newValue
        }
    }
    
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
    
    var lastEventPacket: EventPacket?
    
    var lastEvent: CameraEvent?
    
    var lastStillCaptureModes: (available: [SonyStillCaptureMode], supported: [SonyStillCaptureMode])?
    
    var imageURLs: [ShootingMode : [URL]] = [:]
        
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
    
    private func sendStartSessionPacket(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        // First argument here is the session ID.
        let packet = Packet.commandRequestPacket(code: .openSession, arguments: [0x00000001], transactionId: ptpIPClient?.getNextTransactionId() ?? 0)
        ptpIPClient?.sendCommandRequestPacket(packet, callback: { [weak self] (response) in
            guard response.code == .okay else {
                completion(PTPError.commandRequestFailed(response.code), false)
                return
            }
            self?.getDeviceInfo(completion: completion)
        }, callCallbackForAnyResponse: true)
    }
    
    private func getDeviceInfo(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        let packet = Packet.commandRequestPacket(code: .getDeviceInfo, arguments: nil, transactionId: ptpIPClient?.getNextTransactionId() ?? 1)
        
        ptpIPClient?.awaitDataFor(transactionId: packet.transactionId, callback: { [weak self] (dataResult) in
            
            switch dataResult {
            case .success(let dataContainer):
                guard let deviceInfo = PTP.DeviceInfo(data: dataContainer.data) else {
                    completion(PTPError.fetchDeviceInfoFailed, false)
                    return
                }
                self?.deviceInfo = deviceInfo
                // Only get SDIO Ext Device Info if it's supported!
                guard deviceInfo.supportedOperations.contains(.sdioGetExtDeviceInfo) else {
                    completion(nil, false)
                    return
                }
                self?.getSdioExtDeviceInfo(completion: completion)
            case .failure(let error):
                completion(error, false)
            }
        })
        
        ptpIPClient?.sendCommandRequestPacket(packet, callback: nil)
    }
        
    private func performSdioConnect(completion: @escaping (Error?) -> Void, number: DWord, transactionId: DWord) {
        
        //TODO: Try and find out what the arguments are for this!
        let packet = Packet.commandRequestPacket(code: .sdioConnect, arguments: [number, 0x0000, 0x0000], transactionId: transactionId)
        ptpIPClient?.sendCommandRequestPacket(packet, callback: { (response) in
            guard response.code == .okay else {
                completion(PTPError.commandRequestFailed(response.code))
                return
            }
            completion(nil)
        }, callCallbackForAnyResponse: true)
    }
    
    private func getSdioExtDeviceInfo(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        // 1. call sdio connect twice
        // 2. call sdio get ext device info
        // 3. call sdio connect once more
        
        performSdioConnect(completion: { [weak self] (error) in
            guard let self = self else { return }
            self.performSdioConnect(
                completion: { [weak self] (secondaryError) in
                    
                    guard let self = self else { return }
                    
                    // One parameter into this call, not sure what it represents!
                    let packet = Packet.commandRequestPacket(code: .sdioGetExtDeviceInfo, arguments: [0x0000012c], transactionId: self.ptpIPClient?.getNextTransactionId() ?? 4)
                    self.ptpIPClient?.awaitDataFor(transactionId: packet.transactionId, callback: { [weak self] (dataResult) in
                        
                        switch dataResult {
                        case .success(let dataContainer):
                            
                            guard let self = self else { return }
                            guard let extDeviceInfo = PTP.SDIOExtDeviceInfo(data: dataContainer.data) else {
                                completion(PTPError.fetchSdioExtDeviceInfoFailed, false)
                                return
                            }
                            self.deviceInfo?.update(with: extDeviceInfo)
                        case .failure(let error):
                            completion(error, false)
                        }
                    })
                    self.ptpIPClient?.sendCommandRequestPacket(packet, callback: { (response) in
                        guard response.code == .okay else {
                            completion(PTPError.commandRequestFailed(response.code), false)
                            return
                        }
                        // Sony app seems to jump current transaction ID back to 2 here, so we'll do the same
                        self.ptpIPClient?.resetTransactionId(to: 1)
                        self.performSdioConnect(
                            completion: { [weak self] _ in
                                self?.performInitialEventFetch(completion: completion)
                            },
                            number: 3,
                            transactionId: self.ptpIPClient?.getNextTransactionId() ?? 2
                        )
                    })
                },
                number: 2,
                transactionId: self.ptpIPClient?.getNextTransactionId() ?? 3
            )
        }, number: 1, transactionId: ptpIPClient?.getNextTransactionId() ?? 2)
    }
    
    private func performInitialEventFetch(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        self.ptpIPClient?.sendCommandRequestPacket(Packet.commandRequestPacket(
            code: .unknownHandshakeRequest,
            arguments: nil,
            transactionId: self.ptpIPClient?.getNextTransactionId() ?? 7
        ), callback: { (response) in
            
            self.performFunction(Event.get, payload: nil, callback: { [weak self] (error, event) in
                
                self?.lastEvent = event
                // Can ignore errors as we don't really require this event for the connection process to complete!
                completion(nil, false)
            })
        })
    }
    
    func getDevicePropDescFor(propCode: PTP.DeviceProperty.Code,  callback: @escaping PTPIPClient.DevicePropertyDescriptionCompletion) {
        
        guard let ptpIPClient = ptpIPClient else { return }
        
        if deviceInfo?.supportedOperations.contains(.getAllDevicePropData) ?? false {
            
            ptpIPClient.getAllDevicePropDesc(callback: { (result) in
                switch result {
                case .success(let properties):
                    guard let property = properties.first(where: { $0.code == propCode }) else {
                        callback(Result.failure(PTPError.propCodeNotFound))
                        return
                    }
                    callback(Result.success(property))
                case .failure(let error):
                    callback(Result.failure(error))
                }
            })
            
        } else if deviceInfo?.supportedOperations.contains(.sonyGetDevicePropDesc) ?? false {
            
            let packet = Packet.commandRequestPacket(code: .sonyGetDevicePropDesc, arguments: [DWord(propCode.rawValue)], transactionId: ptpIPClient.getNextTransactionId())
            ptpIPClient.awaitDataFor(transactionId: packet.transactionId) { (dataResult) in
                switch dataResult {
                case .success(let data):
                    guard let property = data.data.getDeviceProperty(at: 0) else {
                        callback(Result.failure(PTPIPClientError.invalidResponse))
                        return
                    }
                    callback(Result.success(property))
                case .failure(let error):
                    callback(Result.failure(error))
                }
            }
            ptpIPClient.sendCommandRequestPacket(packet, callback: nil)
            
        } else if deviceInfo?.supportedOperations.contains(.getDevicePropDesc) ?? false {
            
            ptpIPClient.getDevicePropDescFor(propCode: propCode, callback: callback)
            
        } else {
            
            callback(Result.failure(PTPError.operationNotSupported))
        }
    }
    
    fileprivate func handlePTPIPEvent(_ event: EventPacket) {
        
        lastEventPacket = event
        
        switch event.code {
        case .propertyChanged:
            onEventAvailable?()
        case .objectAdded:
            Logger.log(message: "Got property changed event and was \"Object Added\", initiating transfer", category: "SonyPTPIPCamera")
            os_log("Got property changed event and was \"Object Added\", initiating transfer", log: self.log, type: .debug)
            guard let objectID = event.variables?.first else { return }
            handleObjectId(objectID: objectID, shootingMode: lastEvent?.shootMode?.current ?? .photo) { (result) in
                
            }
            break
        case .objectRemoved:
            // If object was removed, we are done with capture
            break
        default:
            break
        }
    }
    
    enum PTPError: Error {
        case commandRequestFailed(CommandResponsePacket.Code)
        case fetchDeviceInfoFailed
        case fetchSdioExtDeviceInfoFailed
        case deviceInfoNotAvailable
        case objectNotFound
        case propCodeNotFound
        case operationNotSupported
    }
}

//MARK: - Camera protocol conformance -

extension SonyPTPIPDevice: Camera {
        
    func connect(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        lastEvent = nil
        lastEventPacket = nil
        lastStillCaptureModes = nil
        zoomingDirection = nil
        
        ptpIPClient?.connect(callback: { [weak self] (error) in
            self?.sendStartSessionPacket(completion: completion)
        })
        ptpIPClient?.onEvent = { [weak self] (event) in
            self?.handlePTPIPEvent(event)
        }
        ptpIPClient?.onDisconnect = { [weak self] in
            self?.onDisconnected?()
        }
    }
    
    func makeFunctionAvailable<T>(_ function: T, callback: @escaping ((Error?) -> Void)) where T : CameraFunction {
        
        switch function.function {
        case .startContinuousShooting:
            
            setShutterSpeedAwayFromBulbIfRequired { [weak self] (_) in
                
                guard let self = self else { return }
                
                // On PTP IP cameras still capture mode gives us both continuous shooting speed, and it's mode too
                self.getDevicePropDescFor(propCode: .stillCaptureMode, callback: { [weak self] (result) in
                    
                    guard let self = self else { return }
                    
                    switch result {
                    case .success(let property):
                        
                        let event = CameraEvent.fromSonyDeviceProperties([property]).event
                        guard let firstMode = event.continuousShootingMode?.available.first(where: { $0 != .single }) ?? event.continuousShootingMode?.available.first else {
                            callback(nil)
                            return
                        }
                        
                        self.performFunction(ContinuousCapture.Mode.set, payload: firstMode) { [weak self] (error, _) in

                            guard error == nil else {
                                callback(error)
                                return
                            }
                            
                            guard let self = self else { return }
                            
                            guard let firstSpeed = event.continuousShootingSpeed?.available.first else {
                                callback(nil)
                                return
                            }
                            
                            self.performFunction(ContinuousCapture.Speed.set, payload: firstSpeed) { (error, _) in
                                callback(error)
                            }
                        }
                    case .failure(let error):
                        callback(error)
                    }
                })
            }
        case .startBulbCapture:
            performFunction(Shutter.Speed.set, payload: ShutterSpeed.bulb) { [weak self] (shutterSpeedError, _) in
                guard shutterSpeedError == nil else {
                    callback(shutterSpeedError)
                    return
                }
                // We need to do this otherwise the camera can get stuck in continuous shooting mode!
                self?.performFunction(ShootMode.set, payload: .photo) { (_, _) in
                    callback(nil)
                }
            }
        case .takePicture:
            setShutterSpeedAwayFromBulbIfRequired() { [weak self] (_) in
                self?.performFunction(ShootMode.set, payload: .photo) { (_, _) in
                    callback(nil)
                }
            }
        case .startIntervalStillRecording:
            setShutterSpeedAwayFromBulbIfRequired() { [weak self] (_) in
                self?.setToShootModeIfRequired(.interval, callback)
            }
        case .startAudioRecording:
            setShutterSpeedAwayFromBulbIfRequired() { [weak self] (_) in
                self?.setToShootModeIfRequired(.audio, callback)
            }
        case .startVideoRecording:
            setShutterSpeedAwayFromBulbIfRequired() { [weak self] (_) in
                self?.setToShootModeIfRequired(.video, callback)
            }
        case .startLoopRecording:
            setShutterSpeedAwayFromBulbIfRequired() { [weak self] (_) in
                self?.setToShootModeIfRequired(.loop, callback)
            }
        default:
            callback(nil)
        }
    }
    
    func bestStillCaptureMode(for shootMode: ShootingMode) -> SonyStillCaptureMode? {
                
        switch shootMode {
        case .audio, .video, .loop, .interval:
            //TODO: Work out how to handle these!
            return nil
        case .photo, .timelapse, .bulb:
            return .single
        case .continuous:
            guard let continuousShootingModes = lastStillCaptureModes?.available.filter({ $0.shootMode == .continuous }) else {
                return .continuous
            }
            return continuousShootingModes.first
        }
    }
    
    private func setToShootModeIfRequired(_ shootMode: ShootingMode, _ completion: @escaping ((Error?) -> Void)) {
        
        // Last shoot mode should be up to date so do a quick check if we're already in the correct shoot mode
        guard lastEvent?.shootMode?.current != shootMode else {
            completion(nil)
            return
        }
        
        guard let stillCaptureMode = bestStillCaptureMode(for: shootMode) else {
            completion(nil)
            return
        }
        
        setStillCaptureMode(stillCaptureMode, completion)
    }
    
    func setStillCaptureMode(_ mode: SonyStillCaptureMode, _ completion: @escaping ((Error?) -> Void)) {
        
        ptpIPClient?.sendSetControlDeviceAValue(
            PTP.DeviceProperty.Value(
                code: .stillCaptureMode,
                type: .uint32,
                value: mode.rawValue
            ),
            callback: { (response) in
                completion(response.code.isError ? PTPError.commandRequestFailed(response.code) : nil)
            }
        )
    }
    
    private func setShutterSpeedAwayFromBulbIfRequired(_ callback: @escaping ((Error?) -> Void)) {
        
        // We need to do this otherwise the camera can get stuck in continuous shooting mode!
        // If the shutter speed is BULB then we need to set it to something else!
        guard self.lastEvent?.shutterSpeed?.current.isBulb == true else {
            callback(nil)
            return
        }
        
        // Get available shutter speeds
        getDevicePropDescFor(propCode: .shutterSpeed) { [weak self] (result) in
            
            guard let self = self else { return }
            
            switch result {
            case .success(let property):
                let event = CameraEvent.fromSonyDeviceProperties([property]).event
                guard let firstNonBulbShutterSpeed = event.shutterSpeed?.available.first(where: { !$0.isBulb }) else {
                    callback(nil)
                    return
                }
                // Set shutter speed to non-bulb
                self.performFunction(Shutter.Speed.set, payload: firstNonBulbShutterSpeed) { (error, _) in
                    callback(error)
                }
            case .failure(let error):
                callback(error)
            }
        }
    }
    
    func loadFilesToTransfer(callback: @escaping ((Error?, [File]?) -> Void)) {
        
    }
    
    func finishTransfer(callback: @escaping ((Error?) -> Void)) {
        
    }
    
    func handleEvent(event: CameraEvent) {
        lastEvent = event
    }
}
