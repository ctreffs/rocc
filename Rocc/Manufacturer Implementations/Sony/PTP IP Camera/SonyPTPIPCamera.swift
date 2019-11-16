//
//  SonyPTPIPCamera.swift
//  Rocc
//
//  Created by Simon Mitchell on 02/11/2019.
//  Copyright © 2019 Simon Mitchell. All rights reserved.
//

import Foundation

internal final class SonyPTPIPDevice: SonyCamera {
    
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
        
    var eventPollingMode: PollingMode {
        guard let deviceInfo = deviceInfo else { return .timed }
        return deviceInfo.supportedEventCodes.contains(.propertyChanged) ? .cameraDriven : .timed
    }
    
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
    
    var lastEvent: CameraEvent?
        
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
    
    private func getDeviceInfo(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        let packet = Packet.commandRequestPacket(code: .getDeviceInfo, arguments: nil, transactionId: 1)
        ptpIPClient?.awaitDataFor(transactionId: 1, callback: { [weak self] (dataContainer) in
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
        })
        ptpIPClient?.sendCommandRequestPacket(packet, callback: nil)
    }
        
    private func performSdioConnect(completion: @escaping (Error?) -> Void, number: DWord, transactionId: DWord = 2) {
        
        //TODO: Try and find out what the arguments are for this!
        let packet = Packet.commandRequestPacket(code: .sdioConnect, arguments: [number, 0x0000, 0x0000], transactionId: transactionId)
        ptpIPClient?.awaitDataFor(transactionId: packet.transactionId, callback: { (dataContainer) in
            completion(nil)
        })
        ptpIPClient?.sendCommandRequestPacket(packet, callback: nil)
    }
    
    private func getSdioExtDeviceInfo(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        // 1. call sdio connect twice
        // 2. call sdio get ext device info
        // 3. call sdio connect once more
        
        performSdioConnect(completion: { [weak self] (error) in
            guard let this = self else { return }
            //TODO: Handle errors
            this.performSdioConnect(
                completion: { [weak this] (secondaryError) in
                    
                    guard let _this = this else { return }
                    
                    // One parameter into this call, not sure what it represents!
                    let packet = Packet.commandRequestPacket(code: .sdioGetExtDeviceInfo, arguments: [0x0000012c], transactionId: 4)
                    _this.ptpIPClient?.awaitDataFor(transactionId: packet.transactionId, callback: { [weak _this] (dataContainer) in
                        guard let extDeviceInfo = PTP.SDIOExtDeviceInfo(data: dataContainer.data) else {
                            completion(PTPError.fetchSdioExtDeviceInfoFailed, false)
                            return
                        }
                        _this?.deviceInfo?.update(with: extDeviceInfo)
                        _this?.performSdioConnect(completion: { _ in }, number: 3, transactionId: 5)
//                        _this?.performFunction(Event.get, payload: nil, callback: { (error, event) in
//                            print("Got event", event)
//                        })
                        completion(nil, false)
                    })
                    _this.ptpIPClient?.sendCommandRequestPacket(packet, callback: nil)
                },
                number: 2,
                transactionId: 3
            )
        }, number: 1)
    }
    
    enum PTPError: Error {
        case commandRequestFailed
        case fetchDeviceInfoFailed
        case fetchSdioExtDeviceInfoFailed
        case deviceInfoNotAvailable
    }
}

//MARK: - Camera protocol conformance -

extension SonyPTPIPDevice: Camera {
        
    func connect(completion: @escaping SonyPTPIPDevice.ConnectedCompletion) {
        
        ptpIPClient = PTPIPClient(camera: self)
        ptpIPClient?.connect(callback: { [weak self] (error) in
            self?.sendStartSessionPacket(completion: completion)
        })
        ptpIPClient?.onEvent = { [weak self] (event) in
            guard event.code == .propertyChanged else { return }
            self?.onEventAvailable?()
        }
    }
    
    func supportsFunction<T>(_ function: T, callback: @escaping ((Bool?, Error?, [T.SendType]?) -> Void)) where T : CameraFunction {
        
        var supported: Bool = false
                
        // If the function has a related PTP property value
        if let deviceInfo = deviceInfo, let propTypeCodes = function.function.ptpDevicePropertyCodes {
                        
            // Check that the related property value is supported
            supported = propTypeCodes.contains { (functionPropCode) -> Bool in
                return deviceInfo.supportedDeviceProperties.contains(functionPropCode)
            }
            if !supported {
                callback(false, nil, nil)
                return
            }
        }
                
        if let latestEvent = lastEvent, let _ = latestEvent.supportedFunctions {
            latestEvent.supportsFunction(function, callback: callback)
            return
        }
        
        // Fallback for functions that aren't related to a particular camera prop type, or that function differently to the PTP spec!
        switch function.function {
        case .ping:
            callback(true, nil, nil)
        //TODO: Finish implementing!
        default:
            callback(false, nil, nil)
        }
    }
    
    func isFunctionAvailable<T>(_ function: T, callback: @escaping ((Bool?, Error?, [T.SendType]?) -> Void)) where T : CameraFunction {
                        
        if let latestEvent = lastEvent, let _ = latestEvent.availableFunctions {
            latestEvent.isFunctionAvailable(function, callback: callback)
            return
        }
        
        // Fallback for functions that aren't related to a particular camera prop type, or that function differently to the PTP spec!
        switch function.function {
        case .ping:
            callback(true, nil, nil)
        //TODO: Finish implementing!
        default:
            callback(false, nil, nil)
        }
    }
    
    func makeFunctionAvailable<T>(_ function: T, callback: @escaping ((Error?) -> Void)) where T : CameraFunction {
        //TODO: Implement this properly!
        callback(nil)
    }
    
    func performFunction<T>(_ function: T, payload: T.SendType?, callback: @escaping ((Error?, T.ReturnType?) -> Void)) where T : CameraFunction {
        
        switch function.function {
        case .getEvent:
            let packet = Packet.commandRequestPacket(code: .getAllDevicePropData, arguments: [0], transactionId: 7)
            ptpIPClient?.awaitDataFor(transactionId: packet.transactionId, callback: { (data) in
                guard let numberOfProperties = data.data[qWord: 0] else { return }
                var offset: UInt = UInt(MemoryLayout<QWord>.size)
                var properties: [PTPDeviceProperty] = []
                for _ in 0..<numberOfProperties {
                    guard let property = data.data.getDeviceProperty(at: offset) else { break }
                    properties.append(property)
                    offset += property.length
                }
                let event = CameraEvent(sonyDeviceProperties: properties)
                callback(nil, event as? T.ReturnType)
            })
            ptpIPClient?.sendCommandRequestPacket(packet, callback: nil)
        case .setShootMode:
            guard let value = payload as? ShootingMode else {
                callback(FunctionError.invalidPayload, nil)
                return
            }
            //TODO: Implement when we have better grasp of available shoot modes
        case .setContinuousShootingMode:
            // This isn't a thing via PTP according to Sony's app (Instead we just have multiple continuous shooting speeds) so we just don't do anything!
            callback(nil, nil)
        case .setISO, .setShutterSpeed, .setAperture, .setExposureCompensation, .setFocusMode, .setExposureMode, .setFlashMode, .setContinuousShootingSpeed:
            guard let value = payload as? SonyPTPPropValueConvertable else {
                callback(FunctionError.invalidPayload, nil)
                return
            }
            ptpIPClient?.sendSetControlDeviceAValue(
                PTP.DeviceProperty.Value(value)
            )
        case .setStillSize:
            guard let stillSize = payload as? StillSize else {
                callback(FunctionError.invalidPayload, nil)
                return
            }
            var stillSizeByte: Byte? = nil
            switch stillSize.size {
            case "L":
                stillSizeByte = 0x01
            case "M":
                stillSizeByte = 0x02
            case "S":
                stillSizeByte = 0x03
            default:
                break
            }
            
            if let _stillSizeByte = stillSizeByte {
                ptpIPClient?.sendSetControlDeviceAValue(
                    PTP.DeviceProperty.Value(
                        code: .imageSizeSony,
                        type: .uint8,
                        value: _stillSizeByte
                    )
                )
            }
            
            guard let aspect = stillSize.aspectRatio else { return }
            
            var aspectRatioByte: Byte? = nil
            switch aspect {
            case "3:2":
                aspectRatioByte = 0x01
            case "16:9":
                aspectRatioByte = 0x02
            case "1:1":
                aspectRatioByte = 0x04
            default:
                break
            }
            
            guard let _aspectRatioByte = aspectRatioByte else { return }
            
            ptpIPClient?.sendSetControlDeviceAValue(
                PTP.DeviceProperty.Value(
                    code: .imageSizeSony,
                    type: .uint8,
                    value: _aspectRatioByte
                )
            )
            
        case .setSelfTimerDuration:
            guard let timeInterval = payload as? TimeInterval else {
                callback(FunctionError.invalidPayload, nil)
                return
            }
            let value: SonyStillCaptureMode
            switch timeInterval {
            case 0.0:
                value = .single
            case 2.0:
                value = .timer2
            case 5.0:
                value = .timer5
            case 10.0:
                //TODO: Pick out the one which is available! How!?
                value = .timer10_a
            default:
                value = .single
            }
            ptpIPClient?.sendSetControlDeviceAValue(
                PTP.DeviceProperty.Value(value)
            )
        case .setWhiteBalance:
            guard let value = payload as? WhiteBalance.Value else {
                callback(FunctionError.invalidPayload, nil)
                return
            }
            ptpIPClient?.sendSetControlDeviceAValue(
                PTP.DeviceProperty.Value(value.mode)
            )
            guard let colorTemp = value.temperature else { return }
            ptpIPClient?.sendSetControlDeviceAValue(
                PTP.DeviceProperty.Value(
                    code: .colorTemp,
                    type: .uint16,
                    value: Word(colorTemp)
                )
            )
        default:
            return
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
