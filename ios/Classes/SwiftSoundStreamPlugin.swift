import Flutter
import UIKit
import AVFoundation

public enum SoundStreamErrors: String {
    case FailedToRecord
    case FailedToPlay
    case FailedToStop
    case FailedToWriteBuffer
    case Unknown
}

public enum SoundStreamStatus: String {
    case Unset
    case Initialized
    case Playing
    case Recording
    case Stopped
}

@available(iOS 9.0, *)
public class SwiftSoundStreamPlugin: NSObject, FlutterPlugin {
    private var channel: FlutterMethodChannel
    private var registrar: FlutterPluginRegistrar
    private var hasPermission: Bool = false
    private var debugLogging: Bool = false
    
    //========= Devices' vars
    private var mConnected = false
    
    //========= Recorder's vars
    private let mAudioEngine = AVAudioEngine()
    private let mRecordBus = 0
    private var mInputNode: AVAudioInputNode
    private var mRecordSampleRate: Double = 16000 // 16Khz
    private var mRecordBufferSize: AVAudioFrameCount = 256
    private var mRecordChannel = 0
    private var mRecordSettings: [String:Int]!
    private var mRecordFormat: AVAudioFormat!
    
    //========= Player's vars
    private let PLAYER_OUTPUT_SAMPLE_RATE: Double = 32000   // 32Khz
    private let mPlayerBus = 0
    private let mPlayerNode = AVAudioPlayerNode()
    private var mPlayerSampleRate: Double = 16000 // 16Khz
    private var mPlayerBufferSize: AVAudioFrameCount = 256
    private var mPlayerOutputFormat: AVAudioFormat!
    private var mPlayerInputFormat: AVAudioFormat!
    private var isRecording = false
    
    /** ======== Basic Plugin initialization ======== **/
    
    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "vn.casperpas.sound_stream:methods", binaryMessenger: registrar.messenger())
        let instance = SwiftSoundStreamPlugin( channel, registrar: registrar)
        
        registrar.addMethodCallDelegate(instance, channel: channel)
    }
    
    init( _ channel: FlutterMethodChannel, registrar: FlutterPluginRegistrar ) {
        self.channel = channel
        self.registrar = registrar
        self.mInputNode = mAudioEngine.inputNode
        
        super.init()
        
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false)
        try? session.setCategory(
            .playAndRecord,
            mode: AVAudioSession.Mode.default,
            options: [
                .defaultToSpeaker,
                .allowBluetooth,
                .allowBluetoothA2DP,
                .allowAirPlay
            ])
        
        try? session.setPreferredIOBufferDuration(0.002)
        try! session.setActive(true)
        
        let nc = NotificationCenter.default
        nc.addObserver(self,
                       selector: #selector(handleRouteChange),
                       name: AVAudioSession.routeChangeNotification,
                       object: nil)
        
        self.attachPlayer()
        
        mAudioEngine.prepare()
    }
    
    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "hasPermission":
            hasPermission(result)
        case "initializeRecorder":
            initializeRecorder(call, result)
        case "startRecording":
            startRecording(result)
        case "stopRecording":
            stopRecording(result)
        case "initializePlayer":
            initializePlayer(call, result)
        case "startPlayer":
            startPlayer(result)
        case "stopPlayer":
            stopPlayer(result)
        case "writeChunk":
            writeChunk(call, result)
        default:
            print("Unrecognized method: \(call.method)")
            sendResult(result, FlutterMethodNotImplemented)
        }
    }
    
    private func sendResult(_ result: @escaping FlutterResult, _ arguments: Any?) {
        DispatchQueue.main.async {
            result( arguments )
        }
    }
    
    private func invokeFlutter( _ method: String, _ arguments: Any? ) {
        DispatchQueue.main.async {
            self.channel.invokeMethod( method, arguments: arguments )
        }
    }
    
    /** ======== Plugin methods ======== **/
    
    private func checkAndRequestPermission(completion callback: @escaping ((Bool) -> Void)) {
        if (hasPermission) {
            callback(hasPermission)
            return
        }
        
        var permission: AVAudioSession.RecordPermission
#if swift(>=4.2)
        permission = AVAudioSession.sharedInstance().recordPermission
#else
        permission = AVAudioSession.sharedInstance().recordPermission()
#endif
        switch permission {
        case .granted:
            print("granted")
            hasPermission = true
            callback(hasPermission)
            break
        case .denied:
            print("denied")
            hasPermission = false
            callback(hasPermission)
            break
        case .undetermined:
            print("undetermined")
            AVAudioSession.sharedInstance().requestRecordPermission() { [unowned self] allowed in
                if allowed {
                    self.hasPermission = true
                    print("undetermined true")
                    callback(self.hasPermission)
                } else {
                    self.hasPermission = false
                    print("undetermined false")
                    callback(self.hasPermission)
                }
            }
            break
        default:
            callback(hasPermission)
            break
        }
    }
    
    private func hasPermission( _ result: @escaping FlutterResult) {
        checkAndRequestPermission { value in
            self.sendResult(result, value)
        }
    }
    
    private func startEngine() {
        guard !mAudioEngine.isRunning else {
            return
        }
        
//        let count = MemoryLayout<AUAudioUnit>.size
//        let auAudioUnit = UnsafeMutablePointer<AUAudioUnit>.allocate(capacity: count)
//        auAudioUnit.initialize(repeating: mAudioEngine.mainMixerNode.auAudioUnit, count: count)
        
        
//        auAudioUnit.pointee = mAudioEngine.mainMixerNode.auAudioUnit
//        let audioUnit = OpaquePointer(auAudioUnit)
        
        try? mAudioEngine.start()
    }
    
    private func stopEngine() {
        mAudioEngine.stop()
        mAudioEngine.reset()
    }
    
    private func sendEventMethod(_ name: String, _ data: Any) {
        var eventData: [String: Any] = [:]
        eventData["name"] = name
        eventData["data"] = data
        invokeFlutter("platformEvent", eventData)
    }
    
    private func initializeRecorder(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                             message:"Incorrect parameters",
                                             details: nil ))
            return
        }
        
        mRecordBufferSize = argsArr["frameSize"] as? UInt32 ?? mRecordBufferSize
        mRecordSampleRate = argsArr["sampleRate"] as? Double ?? mRecordSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        mRecordFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: mRecordSampleRate, channels: 1, interleaved: true)
        
        checkAndRequestPermission { isGranted in
            if isGranted {
                self.sendRecorderStatus(SoundStreamStatus.Initialized)
                self.sendResult(result, true)
            } else {
                self.sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                                      message:"Incorrect parameters",
                                                      details: nil ))
            }
        }
    }
    
    private func resetEngineForRecord() {
        stopRecorder()
        
        let input = mAudioEngine.inputNode
        let inputFormat = input.inputFormat(forBus: mRecordBus)
        let converter = AVAudioConverter(from: inputFormat, to: mRecordFormat!)!
        let ratio: Float = Float(inputFormat.sampleRate)/Float(mRecordFormat.sampleRate)
        
        AudioUnitSetProperty(mAudioEngine.inputNode.audioUnit!,
                             AudioUnitPropertyID(kAudioUnitProperty_MaximumFramesPerSlice),
                             kAudioUnitScope_Global,
                             0,
                             &mRecordBufferSize,
                             UInt32(MemoryLayout<UInt32>.size))
        
        input.installTap(onBus: mRecordBus, bufferSize: UInt32(0.1 * mRecordSampleRate), format: inputFormat) { (buffer, time) -> Void in
            let inputCallback: AVAudioConverterInputBlock = { inNumPackets, outStatus in
                outStatus.pointee = .haveData
                return buffer
            }
            
            self.isRecording = true
            
            let convertedBuffer = AVAudioPCMBuffer(pcmFormat: self.mRecordFormat!, frameCapacity: UInt32(Float(buffer.frameCapacity) / ratio))!
            
            var error: NSError?
            let status = converter.convert(to: convertedBuffer, error: &error, withInputFrom: inputCallback)
            assert(status != .error)
            
            if (self.mRecordFormat?.commonFormat == AVAudioCommonFormat.pcmFormatInt16) {
                let values = self.audioBufferToBytes(convertedBuffer)
                
                self.sendMicData(values)
            }
        }
    }
    
    private func startRecording(_ result: @escaping FlutterResult) {
        resetEngineForRecord()
        startEngine()
        sendRecorderStatus(SoundStreamStatus.Recording)
        
        result(true)
    }
    
    private func stopRecording(_ result: @escaping FlutterResult) {
        mAudioEngine.inputNode.removeTap(onBus: mRecordBus)
        sendRecorderStatus(SoundStreamStatus.Stopped)
        result(true)
    }
    
    private func stopRecorder() {
        mAudioEngine.inputNode.removeTap(onBus: mRecordBus)
        
        isRecording = false
    }
    
    private func sendMicData(_ data: [UInt8]) {
        let channelData = FlutterStandardTypedData(bytes: NSData(bytes: data, length: data.count) as Data)
        sendEventMethod("dataPeriod", channelData)
    }
    
    private func sendRecorderStatus(_ status: SoundStreamStatus) {
        sendEventMethod("recorderStatus", status.rawValue)
    }
    
    private func initializePlayer(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.Unknown.rawValue,
                                             message:"Incorrect parameters",
                                             details: nil ))
            return
        }
        mPlayerBufferSize = argsArr["frameSize"] as? UInt32 ?? mPlayerBufferSize
        mPlayerSampleRate = argsArr["sampleRate"] as? Double ?? mPlayerSampleRate
        debugLogging = argsArr["showLogs"] as? Bool ?? debugLogging
        mPlayerInputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatInt16, sampleRate: mPlayerSampleRate, channels: 1, interleaved: true)
        sendPlayerStatus(SoundStreamStatus.Initialized)
    }
    
    func hasInputs(in routeDescription: AVAudioSessionRouteDescription) -> Bool {
        // Filter the outputs to only those with a port type of headphones.
        return !routeDescription.inputs.isEmpty
    }
    
    func hasOutputs(in routeDescription: AVAudioSessionRouteDescription) -> Bool {
        // Filter the outputs to only those with a port type of headphones.
        return !routeDescription.outputs.isEmpty
    }
    
    @objc func handleRouteChange(notification: Notification) {
        let audioSession = AVAudioSession.sharedInstance()
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
                  return
              }
        
        if reason != .newDeviceAvailable && reason != .oldDeviceUnavailable {
            if debugLogging {
                print("doing nothing: \(reasonValue)")
            }
            
            return
        }
        
        if debugLogging {
            print("resetting \(reasonValue)")
        }
        
        var isPlaying = false
        var isRecording = false
        
        if mPlayerNode.isPlaying {
            isPlaying = true
            
            mPlayerNode.stop()
            sendPlayerStatus(SoundStreamStatus.Stopped)
        }
        
        if self.isRecording {
            isRecording = true
            
            self.stopRecorder()
            sendRecorderStatus(SoundStreamStatus.Stopped)
        }
                   
        stopEngine()
        
        let inputs = audioSession.currentRoute.inputs
        
        if !inputs.isEmpty {
            let input = inputs[0]
            
            if debugLogging {
                print("\(input.portName)")
            }
            
            do {
                var override = AVAudioSession.PortOverride.none
                
                if (input.portType == .builtInMic || input.portType == .builtInSpeaker || input.portType == .builtInReceiver) {
                    override = AVAudioSession.PortOverride.speaker
                }
                
                try audioSession.overrideOutputAudioPort(override)
                
                try audioSession.setPreferredInput(input)
            } catch let error as NSError {
                if debugLogging {
                    print("audioSession error change to input: \(input.portName) with error: \(error.localizedDescription)")
                }
            }
            
            try? audioSession.setActive(true)
        }
        
        if isPlaying {
            mAudioEngine.connect(mPlayerNode, to: mAudioEngine.mainMixerNode, format: mPlayerOutputFormat)
        }
        
        if isRecording {
            resetEngineForRecord()
            sendRecorderStatus(SoundStreamStatus.Recording)
        }
        
        startEngine()
        
        if isPlaying {
            mPlayerNode.play()
            
            sendPlayerStatus(SoundStreamStatus.Playing)
        }
    }
    
    private func attachPlayer() {
        mPlayerOutputFormat = AVAudioFormat(commonFormat: AVAudioCommonFormat.pcmFormatFloat32, sampleRate: PLAYER_OUTPUT_SAMPLE_RATE, channels: 1, interleaved: true)
        
        mAudioEngine.attach(mPlayerNode)
        mAudioEngine.connect(mPlayerNode, to: mAudioEngine.mainMixerNode, format: mPlayerOutputFormat)
    }
    
    private func startPlayer(_ result: @escaping FlutterResult) {
        AudioUnitSetProperty(mAudioEngine.outputNode.audioUnit!,
                             AudioUnitPropertyID(kAudioUnitProperty_MaximumFramesPerSlice),
                             kAudioUnitScope_Global,
                             0,
                             &mPlayerBufferSize,
                             UInt32(MemoryLayout<UInt32>.size))
        startEngine()
        if !mPlayerNode.isPlaying {
            mPlayerNode.play()
        }
        sendPlayerStatus(SoundStreamStatus.Playing)
        result(true)
    }
    
    private func stopPlayer(_ result: @escaping FlutterResult) {
        if mPlayerNode.isPlaying {
            mPlayerNode.stop()
        }
        sendPlayerStatus(SoundStreamStatus.Stopped)
        result(true)
    }
    
    private func sendPlayerStatus(_ status: SoundStreamStatus) {
        sendEventMethod("playerStatus", status.rawValue)
    }
    
    private func writeChunk(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
        if !mPlayerNode.isPlaying || !mAudioEngine.isRunning {
            return
        }
        
        guard let argsArr = call.arguments as? Dictionary<String,AnyObject>,
              let data = argsArr["data"] as? FlutterStandardTypedData
        else {
            sendResult(result, FlutterError( code: SoundStreamErrors.FailedToWriteBuffer.rawValue,
                                             message:"Failed to write Player buffer",
                                             details: nil ))
            return
        }
        let byteData = [UInt8](data.data)
        pushPlayerChunk(byteData, result)
    }
    
    private func pushPlayerChunk(_ chunk: [UInt8], _ result: @escaping FlutterResult) {
        let buffer = bytesToAudioBuffer(chunk)
        mPlayerNode.scheduleBuffer(convertBufferFormat(
            buffer,
            from: mPlayerInputFormat,
            to: mPlayerOutputFormat
        ));
        result(true)
    }
    
    private func convertBufferFormat(_ buffer: AVAudioPCMBuffer, from: AVAudioFormat, to: AVAudioFormat) -> AVAudioPCMBuffer {
        let formatConverter =  AVAudioConverter(from: from, to: to)
        let ratio: Float = Float(from.sampleRate)/Float(to.sampleRate)
        let pcmBuffer = AVAudioPCMBuffer(pcmFormat: to, frameCapacity: UInt32(Float(buffer.frameCapacity) / ratio))!
        
        var error: NSError? = nil
        let inputBlock: AVAudioConverterInputBlock = {inNumPackets, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        formatConverter?.convert(to: pcmBuffer, error: &error, withInputFrom: inputBlock)
        
        return pcmBuffer
    }
    
    private func audioBufferToBytes(_ audioBuffer: AVAudioPCMBuffer) -> [UInt8] {
        let srcLeft = audioBuffer.int16ChannelData![0]
        let bytesPerFrame = audioBuffer.format.streamDescription.pointee.mBytesPerFrame
        let numBytes = Int(bytesPerFrame * audioBuffer.frameLength)
        
        // initialize bytes by 0
        var audioByteArray = [UInt8](repeating: 0, count: numBytes)
        
        srcLeft.withMemoryRebound(to: UInt8.self, capacity: numBytes) { srcByteData in
            audioByteArray.withUnsafeMutableBufferPointer {
                $0.baseAddress!.initialize(from: srcByteData, count: numBytes)
            }
        }
        
        return audioByteArray
    }
    
    private func bytesToAudioBuffer(_ buf: [UInt8]) -> AVAudioPCMBuffer {
        let frameLength = UInt32(buf.count) / mPlayerInputFormat.streamDescription.pointee.mBytesPerFrame
        
        let audioBuffer = AVAudioPCMBuffer(pcmFormat: mPlayerInputFormat, frameCapacity: frameLength)!
        audioBuffer.frameLength = frameLength
        
        let dstLeft = audioBuffer.int16ChannelData![0]
        
        buf.withUnsafeBufferPointer {
            let src = UnsafeRawPointer($0.baseAddress!).bindMemory(to: Int16.self, capacity: Int(frameLength))
            dstLeft.initialize(from: src, count: Int(frameLength))
        }
        
        return audioBuffer
    }
    
}
