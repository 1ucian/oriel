import CoreMedia
import CoreVideo
import Foundation
import HermesCaptureCore
import HermesCaptureProtocol
import VideoToolbox

struct EncodedVideoFrame: Sendable {
    let sequence: UInt64
    let presentationTimeNanoseconds: UInt64
    let isKeyFrame: Bool
    let payload: Data
    let parameterSets: H264ParameterSets?
}

enum VideoEncoderError: Error, Sendable {
    case sessionCreationFailed(OSStatus)
    case propertyConfigurationFailed(OSStatus)
    case encodeFailed(OSStatus)
    case missingSampleBuffer
    case missingDataBuffer
    case dataCopyFailed(OSStatus)
}

private final class EncoderCallbackContext: @unchecked Sendable {
    let sequence: UInt64
    let presentationTimeNanoseconds: UInt64
    let completion: @Sendable (Result<EncodedVideoFrame, VideoEncoderError>) -> Void

    init(
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        completion: @escaping @Sendable (
            Result<EncodedVideoFrame, VideoEncoderError>
        ) -> Void
    ) {
        self.sequence = sequence
        self.presentationTimeNanoseconds = presentationTimeNanoseconds
        self.completion = completion
    }
}

private let videoEncoderOutputCallback: VTCompressionOutputCallback = {
    _, sourceFrameRefCon, status, _, sampleBuffer in
    guard let sourceFrameRefCon else { return }
    let context = Unmanaged<EncoderCallbackContext>
        .fromOpaque(sourceFrameRefCon)
        .takeRetainedValue()

    guard status == noErr else {
        context.completion(.failure(.encodeFailed(status)))
        return
    }
    guard let sampleBuffer else {
        context.completion(.failure(.missingSampleBuffer))
        return
    }
    guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
        context.completion(.failure(.missingDataBuffer))
        return
    }

    let length = CMBlockBufferGetDataLength(dataBuffer)
    var payload = Data(count: length)
    let copyStatus = payload.withUnsafeMutableBytes { bytes in
        CMBlockBufferCopyDataBytes(
            dataBuffer,
            atOffset: 0,
            dataLength: length,
            destination: bytes.baseAddress!
        )
    }
    guard copyStatus == kCMBlockBufferNoErr else {
        context.completion(.failure(.dataCopyFailed(copyStatus)))
        return
    }

    let attachments = CMSampleBufferGetSampleAttachmentsArray(
        sampleBuffer,
        createIfNecessary: false
    ) as? [[CFString: Any]]
    let isNotSync = attachments?.first?[kCMSampleAttachmentKey_NotSync]
        as? Bool ?? false
    let parameterSets = isNotSync ? nil : h264ParameterSets(from: sampleBuffer)
    context.completion(
        .success(
            EncodedVideoFrame(
                sequence: context.sequence,
                presentationTimeNanoseconds: context.presentationTimeNanoseconds,
                isKeyFrame: !isNotSync,
                payload: payload,
                parameterSets: parameterSets
            )
        )
    )
}

private func h264ParameterSets(
    from sampleBuffer: CMSampleBuffer
) -> H264ParameterSets? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(
        sampleBuffer
    ) else { return nil }

    func parameterSet(at index: Int) -> Data? {
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        var count = 0
        var headerLength: Int32 = 0
        let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: index,
            parameterSetPointerOut: &pointer,
            parameterSetSizeOut: &size,
            parameterSetCountOut: &count,
            nalUnitHeaderLengthOut: &headerLength
        )
        guard status == noErr, let pointer, size > 0 else { return nil }
        return Data(bytes: pointer, count: size)
    }

    guard let sequenceParameterSet = parameterSet(at: 0),
          let pictureParameterSet = parameterSet(at: 1) else {
        return nil
    }
    return H264ParameterSets(
        sequenceParameterSet: sequenceParameterSet,
        pictureParameterSet: pictureParameterSet
    )
}

final class VideoEncoder: @unchecked Sendable {
    private let lock = NSLock()
    private var session: VTCompressionSession?
    private var configuration: VideoEncoderConfiguration?

    deinit {
        if let session {
            VTCompressionSessionCompleteFrames(
                session,
                untilPresentationTimeStamp: .invalid
            )
            VTCompressionSessionInvalidate(session)
        }
    }

    func configure(_ configuration: VideoEncoderConfiguration) throws {
        try lock.withLock {
            if self.configuration == configuration, session != nil {
                return
            }
            invalidateLocked()

            var createdSession: VTCompressionSession?
            let specification: [CFString: Any] = [
                kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            ]
            let status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(configuration.width),
                height: Int32(configuration.height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: specification as CFDictionary,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: videoEncoderOutputCallback,
                refcon: nil,
                compressionSessionOut: &createdSession
            )
            guard status == noErr, let createdSession else {
                throw VideoEncoderError.sessionCreationFailed(status)
            }

            do {
                try set(
                    kVTCompressionPropertyKey_RealTime,
                    value: kCFBooleanTrue,
                    on: createdSession
                )
                try set(
                    kVTCompressionPropertyKey_AllowFrameReordering,
                    value: kCFBooleanFalse,
                    on: createdSession
                )
                try set(
                    kVTCompressionPropertyKey_ProfileLevel,
                    value: kVTProfileLevel_H264_Main_AutoLevel,
                    on: createdSession
                )
                try set(
                    kVTCompressionPropertyKey_AverageBitRate,
                    value: configuration.averageBitRate as CFNumber,
                    on: createdSession
                )
                try set(
                    kVTCompressionPropertyKey_ExpectedFrameRate,
                    value: configuration.framesPerSecond as CFNumber,
                    on: createdSession
                )
                try set(
                    kVTCompressionPropertyKey_MaxKeyFrameInterval,
                    value: configuration.keyFrameInterval as CFNumber,
                    on: createdSession
                )
                let preparationStatus = VTCompressionSessionPrepareToEncodeFrames(
                    createdSession
                )
                guard preparationStatus == noErr else {
                    throw VideoEncoderError.propertyConfigurationFailed(
                        preparationStatus
                    )
                }
            } catch {
                VTCompressionSessionInvalidate(createdSession)
                throw error
            }

            session = createdSession
            self.configuration = configuration
        }
    }

    func encode(
        _ pixelBuffer: CVPixelBuffer,
        sequence: UInt64,
        presentationTimeNanoseconds: UInt64,
        forceKeyFrame: Bool = false,
        completion: @escaping @Sendable (
            Result<EncodedVideoFrame, VideoEncoderError>
        ) -> Void
    ) throws {
        try lock.withLock {
            guard let session else {
                throw VideoEncoderError.sessionCreationFailed(kVTInvalidSessionErr)
            }
            let context = EncoderCallbackContext(
                sequence: sequence,
                presentationTimeNanoseconds: presentationTimeNanoseconds,
                completion: completion
            )
            let retainedContext = Unmanaged.passRetained(context).toOpaque()
            let presentationTime = CMTime(
                value: CMTimeValue(presentationTimeNanoseconds),
                timescale: 1_000_000_000
            )
            let properties: CFDictionary? = forceKeyFrame
                ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
                : nil
            let status = VTCompressionSessionEncodeFrame(
                session,
                imageBuffer: pixelBuffer,
                presentationTimeStamp: presentationTime,
                duration: .invalid,
                frameProperties: properties,
                sourceFrameRefcon: retainedContext,
                infoFlagsOut: nil
            )
            guard status == noErr else {
                Unmanaged<EncoderCallbackContext>
                    .fromOpaque(retainedContext)
                    .release()
                throw VideoEncoderError.encodeFailed(status)
            }
        }
    }

    func invalidate() {
        lock.withLock { invalidateLocked() }
    }

    private func invalidateLocked() {
        if let session {
            VTCompressionSessionCompleteFrames(
                session,
                untilPresentationTimeStamp: .invalid
            )
            VTCompressionSessionInvalidate(session)
        }
        session = nil
        configuration = nil
    }

    private func set(
        _ key: CFString,
        value: CFTypeRef,
        on session: VTCompressionSession
    ) throws {
        let status = VTSessionSetProperty(session, key: key, value: value)
        guard status == noErr else {
            throw VideoEncoderError.propertyConfigurationFailed(status)
        }
    }
}
