// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import "HugAudioEngine.h"

#import "HugCrashPad.h"
#import "HugLimiter.h"
#import "HugLinearRamper.h"
#import "HugStereoField.h"
#import "HugFastUtils.h"
#import "HugLevelMeter.h"
#import "HugMeterData.h"
#import "HugSimpleGraph.h"
#import "HugRingBuffer.h"
#import "HugUtils.h"
#import "HugAudioSettings.h"
#import "HugAudioSource.h"

#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioUnitParameters.h>
#import <Accelerate/Accelerate.h>

#include <stdatomic.h>

extern volatile mach_port_t _HugCrashPadIgnoredThread;
extern volatile BOOL _HugCrashPadEnabled;


typedef NS_ENUM(NSInteger, PacketType) {
    PacketTypeUnknown = 0,

    // Transmitted via _statusRingBuffer
    PacketTypePlayback = 1,
    PacketTypeMeter    = 2,
    PacketTypeDanger   = 3,
    
    // Transmitted via _errorRingBuffer
    PacketTypeStatusBufferFull = 101, // Uses PacketDataUnknown
    PacketTypeOverload         = 102, // Uses PacketDataUnknown
    PacketTypeRenderError      = 200, // Uses PacketDataError
};

typedef struct {
    uint64_t timestamp;
    UInt16 type;
} PacketDataUnknown;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    HugPlaybackInfo info;
} PacketDataPlayback;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    UInt16 frameCount;
    uint64_t renderTime;
} PacketDataDanger;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    HugMeterDataStruct leftMeterData;
    HugMeterDataStruct rightMeterData;
} PacketDataMeter;

typedef struct {
    uint64_t timestamp;
    UInt16 type;
    UInt16 index;
    OSStatus err;
} PacketDataRenderError;

typedef struct {
    _Atomic HugAudioSourceInputBlock inputBlock;
    _Atomic HugAudioSourceInputBlock nextInputBlock;
    
    _Atomic AURenderPullInputBlock renderBlock;
    _Atomic AURenderPullInputBlock nextRenderBlock;

    volatile float stereoWidth;
    volatile float stereoBalance;
    volatile float volume;
    volatile float preGain;

    volatile UInt64 renderStart;

    // Host time units. Combined latency of every audio unit between the source input
    // block and the output, used to timestamp playback packets with the moment the
    // frames being pulled now will actually be heard.
    volatile UInt64 downstreamLatency;

    // Diagnostics. The block above the time-pitch unit is called with however many frames
    // that unit decides to pull, which is more than the device buffer whenever the rate is
    // above 1.0. Everything upstream is sized for HugGetMaxInternalFrameCount(); record the
    // largest counts actually seen so the update timer can check them against that, off the
    // render thread. Plain stores, no allocation.
    volatile UInt32 maxUpstreamFrameCount;
    volatile UInt32 maxDownstreamFrameCount;

    // Counts transitions of the emergency limiter into gain reduction. Material dependent, so
    // it comes and goes -- worth being able to tell after the fact whether it engaged at all
    // during a track rather than trying to catch a 4 point indicator dot mid-set.
    volatile UInt32 limiterEngageCount;
    volatile BOOL   limiterWasActive;

    // Consecutive renders whose output, measured ahead of the volume ramper, was digital
    // silence. Zeroed on the render thread when the source is swapped out, so it only counts
    // silence produced after that point. See -_waitForGraphToDrain.
    volatile UInt32 silentRenderCount;
} RenderUserInfo;


static OSStatus sOutputUnitRenderCallback(
    void *inRefCon,
    AudioUnitRenderActionFlags *ioActionFlags,
    const AudioTimeStamp *inTimeStamp,
    UInt32 inBusNumber,
    UInt32 inNumberFrames,
    AudioBufferList *ioData)
{
    _HugCrashPadIgnoredThread = mach_thread_self();

    RenderUserInfo *userInfo = (RenderUserInfo *)inRefCon;
    
    __unsafe_unretained AURenderPullInputBlock renderBlock     = atomic_load(&userInfo->renderBlock);
    __unsafe_unretained AURenderPullInputBlock nextRenderBlock = atomic_load(&userInfo->nextRenderBlock);

    OSStatus err = renderBlock(ioActionFlags, inTimeStamp, inNumberFrames, 0, ioData);

    if (renderBlock != nextRenderBlock) {
        atomic_store(&userInfo->renderBlock, nextRenderBlock);
    }

    return err;
}


// Whether a unit still matches the graph it is about to be placed in.
//
// Checking maximumFramesToRender alone is not enough: a sample rate change leaves it
// untouched, so the unit would keep the rate it was first configured with. That stays
// inaudible through AUNewTimePitch at rate 1.0, which passes audio through unaltered -- it
// only surfaces once the speed moves off normal and the phase vocoder starts sizing its
// windows and phase advances from the wrong sample rate.
//
static BOOL sUnitNeedsConfiguration(AUAudioUnit *unit, AVAudioFormat *format, UInt32 maxFramesToRender)
{
    if (![unit renderResourcesAllocated]) return YES;
    if ([unit maximumFramesToRender] != maxFramesToRender) return YES;

    AUAudioUnitBusArray *inputBusses  = [unit inputBusses];
    AUAudioUnitBusArray *outputBusses = [unit outputBusses];

    if (![inputBusses count] || ![outputBusses count]) return NO;

    AVAudioFormat *inputFormat  = [[inputBusses  objectAtIndexedSubscript:0] format];
    AVAudioFormat *outputFormat = [[outputBusses objectAtIndexedSubscript:0] format];

    if ([inputFormat  sampleRate]   != [format sampleRate])   return YES;
    if ([outputFormat sampleRate]   != [format sampleRate])   return YES;
    if ([inputFormat  channelCount] != [format channelCount]) return YES;
    if ([outputFormat channelCount] != [format channelCount]) return YES;

    return NO;
}


static OSStatus sHandleAudioDeviceOverload(AudioObjectID inObjectID, UInt32 inNumberAddresses, const AudioObjectPropertyAddress inAddresses[], void *inClientData)
{
    PacketDataUnknown packet = { 0, PacketTypeOverload };
    HugRingBufferWrite((HugRingBuffer *)inClientData, &packet, sizeof(packet));
    
    return noErr;
}


@implementation HugAudioEngine {
    RenderUserInfo _renderUserInfo;

    HugAudioSource *_currentSource;
    HugAudioSourceInputBlock _currentInputBlock;
    AudioUnit _outputAudioUnit;

    HugSimpleGraph *_graph;
    AURenderPullInputBlock _graphRenderBlock;

    AudioDeviceID _outputDeviceID;
    NSDictionary *_outputSettings;

    BOOL _switchingSources;

    NSTimer *_updateTimer;

    HugLimiter      *_emergencyLimiter;
    HugStereoField  *_stereoField;
    HugLevelMeter   *_leftLevelMeter;
    HugLevelMeter   *_rightLevelMeter;
    HugLinearRamper *_preGainRamper;
    HugLinearRamper *_volumeRamper;

    HugRingBuffer   *_errorRingBuffer;
    HugRingBuffer   *_statusRingBuffer;

    HugPlaybackStatus _playbackStatus;
    NSTimeInterval    _timeElapsed;
    NSTimeInterval    _timeRemaining;
    HugMeterData     *_leftMeterData;
    HugMeterData     *_rightMeterData;
    float             _dangerLevel;
    NSTimeInterval    _lastOverloadTime;

    NSArray<AUAudioUnit *> *_effectAudioUnits;
    AUAudioUnit            *_timePitchAudioUnit;
    float                   _volume;

    BOOL _graphNeedsDrain;
    BOOL _effectsBypassed;

    UInt32 _reportedUpstreamFrameCount;
    UInt32 _reportedDownstreamFrameCount;
    UInt32 _reportedLimiterEngageCount;
}


- (instancetype) init
{
    if ((self = [super init])) {
        HugLogMethod();

        AudioComponentDescription outputCD = {
            kAudioUnitType_Output,
            kAudioUnitSubType_HALOutput,
            kAudioUnitManufacturer_Apple,
            0,
            0
        };

        AudioComponent outputComponent = AudioComponentFindNext(NULL, &outputCD);

        HugCheckError(
            AudioComponentInstanceNew(outputComponent, &_outputAudioUnit),
            @"HugAudioEngine", @"AudioComponentInstanceNew[ Output ]"
        );

        _stereoField      = HugStereoFieldCreate();
        _preGainRamper    = HugLinearRamperCreate();
        _volumeRamper     = HugLinearRamperCreate();
        _leftLevelMeter   = HugLevelMeterCreate();
        _rightLevelMeter  = HugLevelMeterCreate();
        _emergencyLimiter = HugLimiterCreate();
        
        // Status packets are timestamped with the moment their audio is heard and held by
        // -_readRingBuffers until then, so the buffer always carries the output latency plus
        // the latency of the units in the graph. At 192kHz with 128 frame buffers that is
        // ~6.5KB, so give it room to also absorb a main thread stall between update timer
        // fires. The error buffer is low traffic and untimed.
        //
        _statusRingBuffer = HugRingBufferCreate(65536);
        _errorRingBuffer  = HugRingBufferCreate(8196);

        AudioComponentDescription timePitchCD = {
            kAudioUnitType_FormatConverter,
            kAudioUnitSubType_NewTimePitch,
            kAudioUnitManufacturer_Apple,
            0,
            0
        };
        NSError *timePitchError = nil;
        _timePitchAudioUnit = [[AUAudioUnit alloc] initWithComponentDescription:timePitchCD error:&timePitchError];
        if (timePitchError) {
            HugLog(@"HugAudioEngine", @"Error instantiating NewTimePitch: %@", timePitchError);
        }
    }

    return self;
}


- (void) _sendAudioSourceToRenderThread:(HugAudioSource *)source
{
    if (_currentSource == source) return;

    _switchingSources = YES;

    HugLog(@"HugAudioEngine", @"Sending %@ to render thread", source);

    HugAudioSourceInputBlock blockToCall = [source inputBlock];
    
    // Make a copy of blockToCall. This will change the object pointer
    // and reset the track even if source is the same as _currentSource
    //
    HugAudioSourceInputBlock blockToSend = blockToCall ? [^(
        AUAudioFrameCount frameCount,
        AudioBufferList *inputData,
        HugPlaybackInfo *outInfo
    ) {
        return blockToCall(frameCount, inputData, outInfo);
    } copy] : nil;

    if ([self _isRunning]) {
        atomic_store(&_renderUserInfo.nextInputBlock, blockToSend);

        NSInteger loopGuard = 0;
        while (1) {
            HugRingBufferConfirmReadAll(_statusRingBuffer);

            if (blockToSend == atomic_load(&_renderUserInfo.inputBlock)) {
                break;
            }

            if (![self _isRunning]) return;

            if (loopGuard >= 1000) {
                HugLog(@"HugAudioEngine", @"_sendAudioSourceToRenderThread timed out");
                break;
            }
            
            usleep(1000);
            loopGuard++;
        }

    } else {
        atomic_store(&_renderUserInfo.inputBlock,     nil);
        atomic_store(&_renderUserInfo.nextInputBlock, blockToSend);
    }
    
    _currentSource = source;
    _currentInputBlock = blockToSend;

    HugRingBufferConfirmReadAll(_statusRingBuffer);
    _switchingSources = NO;
}


- (BOOL) _isRunning
{
    if (!_outputAudioUnit) return NO;

    Boolean isRunning = false;
    UInt32 size = sizeof(isRunning);

    HugCheckError(
        AudioUnitGetProperty(_outputAudioUnit, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global, 0, &isRunning, &size),
        @"HugAudioEngine", @"AudioUnitGetProperty[ Output, IsRunning ]"
    );
    
    return isRunning ? YES : NO;
}


- (void) _readRingBuffers
{
    uint64_t current = HugGetCurrentHostTime();
    uint64_t tooFar  = current + HugGetHostTimeWithSeconds(1.0);

    NSInteger loopGuard = HugRingBufferGetCapacity(_statusRingBuffer) / sizeof(PacketDataUnknown);

    NSInteger overloadCount   = 0;
    NSInteger statusFullCount = 0;

    // Process status
    for (NSInteger i = 0; i < loopGuard; i++) {
        // If we are switching sources, clear the entire _statusRingBuffer
        if (_switchingSources) {
            HugRingBufferConfirmReadAll(_statusRingBuffer);
            break;
        }

        PacketDataUnknown *unknown = HugRingBufferGetReadPtr(_statusRingBuffer, sizeof(PacketDataUnknown));
        if (!unknown) break;
               
        if ((unknown->timestamp >= current) && (unknown->timestamp < tooFar)) {
            break;
        }
        
        if (unknown->type == PacketTypePlayback) {
            PacketDataPlayback packet;
            if (!HugRingBufferRead(_statusRingBuffer, &packet, sizeof(PacketDataPlayback))) return;

            _playbackStatus = packet.info.status;
            _timeElapsed    = packet.info.timeElapsed;
            _timeRemaining  = packet.info.timeRemaining;

        } else if (unknown->type == PacketTypeMeter) {
            PacketDataMeter packet;
            if (!HugRingBufferRead(_statusRingBuffer, &packet, sizeof(PacketDataMeter))) return;
            
            _leftMeterData  = [[HugMeterData alloc] initWithStruct:packet.leftMeterData];
            _rightMeterData = [[HugMeterData alloc] initWithStruct:packet.rightMeterData];

        } else if (unknown->type == PacketTypeDanger) {
            PacketDataDanger packet;
            if (!HugRingBufferRead(_statusRingBuffer, &packet, sizeof(PacketDataDanger))) return;
            
            uint64_t renderTime = packet.renderTime;

            double outputSampleRate = [[_outputSettings objectForKey:HugAudioSettingSampleRate] doubleValue];
            
            double callbackDuration = packet.frameCount / outputSampleRate;
            double elapsedDuration  = HugGetSecondsWithHostTime(renderTime);
            
            _dangerLevel = elapsedDuration / callbackDuration;

        } else {
            NSAssert(NO, @"Unknown packet type: %ld", (long)unknown->type);
        }
    }
    
    // Process error buffer
    for (NSInteger i = 0; i < loopGuard; i++) {
        PacketDataUnknown *unknown = HugRingBufferGetReadPtr(_errorRingBuffer, sizeof(PacketDataUnknown));
        if (!unknown) return;

        if (unknown->type == PacketTypeOverload) {
            PacketDataUnknown packet;
            if (!HugRingBufferRead(_errorRingBuffer, &packet, sizeof(PacketDataUnknown))) return;

            _lastOverloadTime = [NSDate timeIntervalSinceReferenceDate];

            overloadCount++;
           
        } else if (unknown->type == PacketTypeStatusBufferFull) {
            PacketDataUnknown packet;
            if (!HugRingBufferRead(_errorRingBuffer, &packet, sizeof(PacketDataUnknown))) return;

            statusFullCount++;
        
        } else if (unknown->type == PacketTypeRenderError) {
            PacketDataRenderError packet;
            if (!HugRingBufferRead(_errorRingBuffer, &packet, sizeof(PacketDataRenderError))) return;

            HugLog(@"HugAudioEngine", @"Render error on audio thread: index=%ld, error=%@",
                (long)packet.index,
                HugGetStringForFourCharCode(packet.err)
            );
            
        } else {
            NSAssert(NO, @"Unknown packet type: %ld", (long)unknown->type);
        }
    }
    
    // Aggregate logging for overloads and "buffer full" errors. Else, we can spend
    // too much time in HugLog while _statusRingBuffer continues to fill.
    //
    if (overloadCount > 0) {
        HugLog(@"HugAudioEngine", @"kAudioDeviceProcessorOverload detected (%ld)", overloadCount);
    }
    
    if (statusFullCount > 0) {
        HugLog(@"HugAudioEngine", @"_statusRingBuffer is full (%ld)", statusFullCount);
    }
}


- (void) _reconnectGraph
{
    HugLogMethod();

    HugLimiter      *limiter          = _emergencyLimiter;
    HugStereoField  *stereoField      = _stereoField;
    HugLevelMeter   *leftLevelMeter   = _leftLevelMeter;
    HugLevelMeter   *rightLevelMeter  = _rightLevelMeter;
    HugLinearRamper *preGainRamper    = _preGainRamper;
    HugLinearRamper *volumeRamper     = _volumeRamper;
    HugRingBuffer   *statusRingBuffer = _statusRingBuffer;
    HugRingBuffer   *errorRingBuffer  = _errorRingBuffer;

    RenderUserInfo *userInfo = &_renderUserInfo;

    HugSimpleGraph *graph = [[HugSimpleGraph alloc] initWithErrorBlock:^(OSStatus err, NSInteger index) {
        PacketDataRenderError packet = { 0, PacketTypeRenderError, index, err };
        HugRingBufferWrite(errorRingBuffer, &packet, sizeof(packet));
    }];
     
    void (^__sendStatusPacket)(void *, CFIndex) = ^(void *buffer, CFIndex length) {
        if (!HugRingBufferWrite(statusRingBuffer, buffer, length)) {
            PacketDataUnknown packet = { 0, PacketTypeStatusBufferFull };
            HugRingBufferWrite(errorRingBuffer, &packet, sizeof(packet));
        }
    };
    #define sendStatusPacket(packet) __sendStatusPacket(&(packet), sizeof((packet)));
     
    [graph addBlock:^(
        AudioUnitRenderActionFlags *ioActionFlags,
        const AudioTimeStamp *timestamp,
        AUAudioFrameCount inNumberFrames,
        NSInteger inputBusNumber,
        AudioBufferList *ioData
    ) {
        userInfo->renderStart = HugGetCurrentHostTime();

        if (inNumberFrames > userInfo->maxUpstreamFrameCount) {
            userInfo->maxUpstreamFrameCount = inNumberFrames;
        }

        __unsafe_unretained HugAudioSourceInputBlock inputBlock     = atomic_load(&userInfo->inputBlock);
        __unsafe_unretained HugAudioSourceInputBlock nextInputBlock = atomic_load(&userInfo->nextInputBlock);
        
        HugPlaybackInfo info = {0};
        OSStatus err = noErr;
        
        BOOL willChangeUnits = (nextInputBlock != inputBlock);

        float *leftData  = ioData->mNumberBuffers > 0 ? ioData->mBuffers[0].mData : NULL;
        float *rightData = ioData->mNumberBuffers > 1 ? ioData->mBuffers[1].mData : NULL;

        if (!inputBlock) {
            *ioActionFlags |= kAudioUnitRenderAction_OutputIsSilence;
            HugApplySilence(leftData, inNumberFrames);
            HugApplySilence(rightData, inNumberFrames);

        } else {
            err = inputBlock(inNumberFrames, ioData, &info);
            
            HugStereoFieldProcess(stereoField, leftData, rightData, inNumberFrames, userInfo->stereoBalance, userInfo->stereoWidth);
            HugLinearRamperProcess(preGainRamper, leftData, rightData, inNumberFrames, userInfo->preGain);

            if (willChangeUnits) {
                HugApplyFade(leftData,  inNumberFrames, 1.0, 0.0);
                HugApplyFade(rightData, inNumberFrames, 1.0, 0.0);
            }
        }

        if (willChangeUnits) {
            HugLinearRamperReset(preGainRamper, userInfo->preGain);
            HugLinearRamperReset(volumeRamper,  userInfo->volume);
            HugStereoFieldReset(stereoField, userInfo->stereoBalance, userInfo->stereoWidth);

            userInfo->silentRenderCount = 0;

            atomic_store(&userInfo->inputBlock, nextInputBlock);

        } else {
            if (inputBlock && (timestamp->mFlags & kAudioTimeStampHostTimeValid)) {
                // info describes the source frames pulled during this cycle, which are still
                // sitting inside the units below us and won't be heard until they clear their
                // latency. Timestamp the packet with that moment so -_readRingBuffers holds it
                // back until then -- otherwise we'd report HugPlaybackStatusFinished (and start
                // the next track) while the tail of this one is still in flight.
                //
                PacketDataPlayback packet = {
                    timestamp->mHostTime + userInfo->downstreamLatency,
                    PacketTypePlayback,
                    info
                };

                sendStatusPacket(packet);
            }
        }

        return err;
    }];

    double sampleRate = [[_outputSettings objectForKey:HugAudioSettingSampleRate] doubleValue];
    UInt32 frameSize  = [[_outputSettings objectForKey:HugAudioSettingFrameSize] unsignedIntValue];

    NSTimeInterval downstreamLatency = 0;

    if (sampleRate && frameSize) {
        AVAudioFormat *format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:sampleRate channels:2];
        
        [_outputSettings objectForKey:HugAudioSettingFrameSize];
        
        if (_timePitchAudioUnit) {
            NSError *error = nil;
            UInt32 maxInternalFrames = HugGetMaxInternalFrameCount(frameSize);

            if (sUnitNeedsConfiguration(_timePitchAudioUnit, format, maxInternalFrames)) {
                [_timePitchAudioUnit deallocateRenderResources];
                [_timePitchAudioUnit setMaximumFramesToRender:maxInternalFrames];

                AUAudioUnitBus *inputBus  = [[_timePitchAudioUnit inputBusses]  objectAtIndexedSubscript:0];
                AUAudioUnitBus *outputBus = [[_timePitchAudioUnit outputBusses] objectAtIndexedSubscript:0];

                if (!error) [inputBus  setFormat:format error:&error];
                if (!error) [outputBus setFormat:format error:&error];
                if (!error) [_timePitchAudioUnit allocateRenderResourcesAndReturnError:&error];
                
                [inputBus setEnabled:YES];
                [outputBus setEnabled:YES];
            }
            
            if (error) {
                HugLog(@"HugAudioEngine", @"Error when configuring timePitch: %@", error);
            } else {
                [graph addAudioUnit:_timePitchAudioUnit];
                downstreamLatency += [_timePitchAudioUnit latency];
            }
        }
        
        for (AUAudioUnit *unit in _effectAudioUnits) {
            NSError *error = nil;

            if (sUnitNeedsConfiguration(unit, format, frameSize)) {
                [unit deallocateRenderResources];

                [unit setMaximumFramesToRender:frameSize];

                AUAudioUnitBus *inputBus  = [[unit inputBusses]  objectAtIndexedSubscript:0];
                AUAudioUnitBus *outputBus = [[unit outputBusses] objectAtIndexedSubscript:0];
                
                if (!error) [inputBus  setFormat:format error:&error];
                if (!error) [outputBus setFormat:format error:&error];
                if (!error) [unit allocateRenderResourcesAndReturnError:&error];
                
                [inputBus setEnabled:YES];
                [outputBus setEnabled:YES];
            }
           
            if (error) {
                HugLog(@"HugAudioEngine", @"Error when configuring %@: %@", unit, error);
            } else  {
                [graph addAudioUnit:unit];
                downstreamLatency += [unit latency];
            }
        }
    }

    HugLog(@"HugAudioEngine", @"downstream latency is %g ms", downstreamLatency * 1000);
    _renderUserInfo.downstreamLatency = HugGetHostTimeWithSeconds(downstreamLatency);

    [graph addBlock:^(
        AudioUnitRenderActionFlags *ioActionFlags,
        const AudioTimeStamp *timestamp,
        AUAudioFrameCount inNumberFrames,
        NSInteger inputBusNumber,
        AudioBufferList *ioData
    ) {
        uint64_t currentTime = (timestamp->mFlags & kAudioTimeStampHostTimeValid) ?
            timestamp->mHostTime :
            HugGetCurrentHostTime();
        
        if (inNumberFrames > userInfo->maxDownstreamFrameCount) {
            userInfo->maxDownstreamFrameCount = inNumberFrames;
        }

        size_t meterFrameCount = HugLevelMeterGetMaxFrameCount(leftLevelMeter);
        
        NSInteger offset = 0;
        NSInteger framesRemaining = inNumberFrames;

        float *leftData  = ioData->mNumberBuffers > 0 ? ioData->mBuffers[0].mData : NULL;
        float *rightData = ioData->mNumberBuffers > 1 ? ioData->mBuffers[1].mData : NULL;

        // Measured ahead of the volume ramper: volume is zero throughout a track change, so
        // the ramper's output says nothing about what the units above are still flushing.
        //
        float peak = 0, channelPeak = 0;
        if (leftData)  { vDSP_maxmgv(leftData,  1, &channelPeak, inNumberFrames); peak = MAX(peak, channelPeak); }
        if (rightData) { vDSP_maxmgv(rightData, 1, &channelPeak, inNumberFrames); peak = MAX(peak, channelPeak); }
        userInfo->silentRenderCount = (peak < 1.0e-6f) ? (userInfo->silentRenderCount + 1) : 0;

        float volume = userInfo->volume;
        HugLinearRamperProcess(volumeRamper, leftData, rightData, inNumberFrames, volume);
        
        while (framesRemaining > 0) {
            NSInteger framesToProcess = MIN(framesRemaining, meterFrameCount);

            PacketDataMeter packet = {0};
            packet.timestamp = currentTime + HugGetHostTimeWithSeconds(offset / sampleRate);
            packet.type = PacketTypeMeter;

            if (leftData) {
                HugLevelMeterProcess(leftLevelMeter, leftData + offset, framesToProcess);

                packet.leftMeterData.peakLevel = HugLevelMeterGetPeakLevel(leftLevelMeter);
                packet.leftMeterData.heldLevel = HugLevelMeterGetHeldLevel(leftLevelMeter);
            }

            if (rightData) {
                HugLevelMeterProcess(rightLevelMeter, rightData + offset, framesToProcess);

                packet.rightMeterData.peakLevel = HugLevelMeterGetPeakLevel(rightLevelMeter);
                packet.rightMeterData.heldLevel = HugLevelMeterGetHeldLevel(rightLevelMeter);
            }

            HugLimiterProcess(limiter, leftData + offset, rightData + offset, framesToProcess);
            packet.leftMeterData.limiterActive = HugLimiterIsActive(limiter);
            packet.rightMeterData.limiterActive = packet.leftMeterData.limiterActive;

            if (packet.leftMeterData.limiterActive && !userInfo->limiterWasActive) {
                userInfo->limiterEngageCount++;
            }
            userInfo->limiterWasActive = packet.leftMeterData.limiterActive;

            sendStatusPacket(packet);

            framesRemaining -= meterFrameCount;
            offset += meterFrameCount;
        }
        
        // Calculate danger level and send packet
        {
            uint64_t renderTime = HugGetCurrentHostTime() - userInfo->renderStart;
            PacketDataDanger packet = { currentTime, PacketTypeDanger, inNumberFrames, renderTime };
            sendStatusPacket(packet);
        }
        
        return noErr;
    }];

    AURenderPullInputBlock blockToSend = [graph renderBlock];
    
    if ([self _isRunning]) {
        atomic_store(&_renderUserInfo.nextRenderBlock, blockToSend);

        NSInteger loopGuard = 0;
        while (1) {
            HugRingBufferConfirmReadAll(_statusRingBuffer);

            if (blockToSend == atomic_load(&_renderUserInfo.renderBlock)) {
                break;
            }

            if (![self _isRunning]) return;

            if (loopGuard >= 1000) {
                HugLog(@"HugAudioEngine", @"_reconnectGraph timed out");
                break;
            }
            
            usleep(1000);
            loopGuard++;
        }

    } else {
        atomic_store(&_renderUserInfo.renderBlock,     blockToSend);
        atomic_store(&_renderUserInfo.nextRenderBlock, blockToSend);
    }

    _graph = graph;
    _graphRenderBlock = blockToSend;
}


- (void) _reallyStopHardware
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reallyStopHardware) object:nil];

    HugCheckError(
        AudioOutputUnitStop(_outputAudioUnit),
        @"HugAudioEngine", @"AudioOutputUnitStop"
    );

    // The output unit is stopped, so nothing is inside these units' render blocks. This is
    // the only place it is safe to reset them.
    //
    [_timePitchAudioUnit reset];

    for (AUAudioUnit *unit in _effectAudioUnits) {
        [unit reset];
    }

    _graphNeedsDrain = NO;

    if (_updateTimer) {
        [_updateTimer invalidate];
        _updateTimer = nil;
    }
}


// After -stopPlayback the units in the graph are still flushing the previous track. Block
// here until the render thread has seen the output go silent, so nothing of that track is
// heard under the head of the next one and no unit gets a parameter change with audio in
// flight. Silence is observed rather than predicted from downstreamLatency: AUNewTimePitch's
// real latency grows while the rate is off 1.0 (measured up to 298 ms at 96 kHz, retained at
// 1.0) and the reported figure never moves. Usually preparing the source took longer than
// the flush and this returns at once.
//
// The counter was zeroed at the swap, so consecutive silent renders since then mean the
// input that fed them was silent too: the delay lines hold nothing audible. Bounded, since
// a unit with a noise floor would never read as silent.
//
- (void) _waitForGraphToDrain
{
    if (!_graphNeedsDrain) return;
    _graphNeedsDrain = NO;

    if (![self _isRunning]) return;

    uint64_t start = HugGetCurrentHostTime();
    NSTimeInterval waited = 0;

    while (_renderUserInfo.silentRenderCount < 2) {
        waited = HugGetSecondsWithHostTime(HugGetCurrentHostTime() - start);

        if (waited > 0.75) {
            HugLog(@"HugAudioEngine", @"graph did not drain within %g ms, continuing", waited * 1000);
            return;
        }

        usleep(2000);
    }

    if (waited > 0) {
        HugLog(@"HugAudioEngine", @"waited %g ms for graph to drain", waited * 1000);
    }
}


// Both of these are only called from -playAudioFile:..., between the drain and the send of
// the next source, i.e. while every unit is processing silence.
//
- (void) _applyPlaybackRate:(double)rate
{
    [self updatePlaybackRate:rate];
}


- (void) _applyEffectsBypass:(BOOL)bypass
{
    _effectsBypassed = bypass;

    for (AUAudioUnit *unit in _effectAudioUnits) {
        if ([unit shouldBypassEffect] != bypass) {
            [unit setShouldBypassEffect:bypass];
        }
    }
}


- (void) _handleDidPrepareSource:(HugAudioSource *)source
{
    if (source == _currentSource) {
        if ([source error]) {
            [self stopPlayback];
        } else {
            _HugCrashPadEnabled = YES;
        }
    }
}


// Checks the frame counts the render thread recorded against what the buffers upstream and
// downstream of the time-pitch unit were actually sized for. The upstream block sees whatever
// that unit pulls -- ceil(deviceBuffer * rate) -- so this is where a rate above 1.0 shows up.
// Reports once per breach so a bad configuration is obvious in the log rather than only
// audible.
//
- (void) _checkRenderFrameCounts
{
    UInt32 upstream   = _renderUserInfo.maxUpstreamFrameCount;
    UInt32 downstream = _renderUserInfo.maxDownstreamFrameCount;

    // Only a breach is worth saying anything about. The counts themselves climb a frame at a
    // time while the rate ramps, which would otherwise fill the log with noise.
    //
    size_t upstreamCapacity = HugLinearRamperGetMaxFrameCount(_preGainRamper);

    if ((upstream > upstreamCapacity) && (upstream > _reportedUpstreamFrameCount)) {
        _reportedUpstreamFrameCount = upstream;

        HugLog(@"HugAudioEngine", @"upstream frame count %u EXCEEDS capacity (pre-gain ramper holds %ld, stereo field %ld)",
            upstream, (long)upstreamCapacity, (long)HugStereoFieldGetMaxFrameCount(_stereoField));
    }

    size_t downstreamCapacity = HugLinearRamperGetMaxFrameCount(_volumeRamper);

    if ((downstream > downstreamCapacity) && (downstream > _reportedDownstreamFrameCount)) {
        _reportedDownstreamFrameCount = downstream;

        HugLog(@"HugAudioEngine", @"downstream frame count %u EXCEEDS capacity (volume ramper holds %ld, level meter %ld)",
            downstream, (long)downstreamCapacity, (long)HugLevelMeterGetMaxFrameCount(_leftLevelMeter));
    }

    UInt32 engageCount = _renderUserInfo.limiterEngageCount;

    if (engageCount != _reportedLimiterEngageCount) {
        HugLog(@"HugAudioEngine", @"emergency limiter engaged (%u since this track started)",
            engageCount - _reportedLimiterEngageCount);

        _reportedLimiterEngageCount = engageCount;
    }
}


- (void) _handleUpdateTimer:(NSTimer *)timer
{
    [self _readRingBuffers];
    [self _checkRenderFrameCounts];
    if (_updateBlock) _updateBlock();
}


#pragma mark - Public Methods

- (BOOL) configureWithDeviceID:(AudioDeviceID)deviceID settings:(NSDictionary *)settings
{
    // Listen for kAudioDeviceProcessorOverload
    {
        AudioObjectPropertyAddress overloadAddress = {
            kAudioDeviceProcessorOverload,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMaster
        };

        if (_outputDeviceID) {
            AudioObjectRemovePropertyListener(_outputDeviceID, &overloadAddress, sHandleAudioDeviceOverload, (void *)_errorRingBuffer);
        }
        
        if (deviceID) {
            AudioObjectAddPropertyListener(deviceID, &overloadAddress, sHandleAudioDeviceOverload, (void *)_errorRingBuffer);
        }
    }

    UInt32 frames = [[settings objectForKey:HugAudioSettingFrameSize] unsignedIntValue];
    UInt32 framesSize = sizeof(frames);

    double sampleRate = [[settings objectForKey:HugAudioSettingSampleRate] doubleValue];

    AURenderCallbackStruct renderCallback = { &sOutputUnitRenderCallback, &_renderUserInfo };

    BOOL ok = YES;

    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioDevicePropertyBufferFrameSize, kAudioUnitScope_Global, 0,
        &frames,
        sizeof(frames)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, kAudioDevicePropertyBufferFrameSize]");
    
    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioOutputUnitProperty_CurrentDevice,
        kAudioUnitScope_Global,
        0,
        &deviceID, sizeof(deviceID)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, CurrentDevice]");

    ok = ok && HugCheckError(AudioUnitGetProperty(_outputAudioUnit,
        kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0,
        &frames, &framesSize
    ), @"HugAudioEngine", @"AudioUnitGetProperty[ Output, MaximumFramesPerSlice ]");

    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioUnitProperty_SampleRate, kAudioUnitScope_Input, 0,
        &sampleRate, sizeof(sampleRate)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, SampleRate, Input ]");

    ok = ok && HugCheckError(AudioUnitSetProperty(_outputAudioUnit,
        kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Global, 0,
        &renderCallback,
        sizeof(renderCallback)
    ), @"HugAudioEngine", @"AudioUnitSetProperty[ Output, SetRenderCallback ]");

    _outputDeviceID = deviceID;
    _outputSettings = settings;

    // `frames` is MaximumFramesPerSlice read back from the output unit, which is not
    // necessarily the buffer size we asked the device for -- worth seeing both, since every
    // scratch buffer downstream of the time-pitch unit is sized from it.
    //
    HugLog(@"HugAudioEngine", @"Configuring audio units with %lf sample rate, requested frame size %u, "
        @"MaximumFramesPerSlice %ld, internal bound %u",
        sampleRate,
        [[settings objectForKey:HugAudioSettingFrameSize] unsignedIntValue],
        (long)frames,
        HugGetMaxInternalFrameCount([[settings objectForKey:HugAudioSettingFrameSize] unsignedIntValue])
    );

    _renderUserInfo.maxUpstreamFrameCount   = 0;
    _renderUserInfo.maxDownstreamFrameCount = 0;
    _reportedUpstreamFrameCount   = 0;
    _reportedDownstreamFrameCount = 0;

    ok = ok && HugCheckError(
        AudioUnitInitialize(_outputAudioUnit),
        @"HugAudioEngine", @"AudioUnitInitialize[ Output ]"
    );

    HugLevelMeterSetSampleRate(_leftLevelMeter, sampleRate);
    HugLevelMeterSetSampleRate(_rightLevelMeter, sampleRate);
    HugLimiterSetSampleRate(_emergencyLimiter, sampleRate);

    // _preGainRamper and _stereoField run in the block above _timePitchAudioUnit, so they see
    // whatever frame count it pulls -- up to 3% more than the output buffer at our maximum
    // rate. Size them against the internal bound rather than against `frames`, which is only
    // the output buffer size. _volumeRamper runs below the unit and does see exactly `frames`.
    //
    UInt32 maxInternalFrames = HugGetMaxInternalFrameCount(
        [[settings objectForKey:HugAudioSettingFrameSize] unsignedIntValue]
    );

    HugLinearRamperSetMaxFrameCount(_preGainRamper, maxInternalFrames);
    HugStereoFieldSetMaxFrameCount(_stereoField, maxInternalFrames);

    HugLinearRamperSetMaxFrameCount(_volumeRamper, frames);

    size_t meterFrame = MIN(frames, 1024);
    HugLevelMeterSetMaxFrameCount(_leftLevelMeter, meterFrame);
    HugLevelMeterSetMaxFrameCount(_rightLevelMeter, meterFrame);

    [self _reconnectGraph];

    return ok;
}


- (BOOL) playAudioFile: (HugAudioFile *) file
             startTime: (NSTimeInterval) startTime
              stopTime: (NSTimeInterval) stopTime
               padding: (NSTimeInterval) padding
                  rate: (double) rate
       bypassesEffects: (BOOL) bypassesEffects
{
    HugLogMethod();

    // Stop first, this should clear the playing HugAudioSource and
    // release the large HugProtectedBuffer objects for the current track.
    //
    [self stopPlayback];

    _playbackStatus = HugPlaybackStatusPreparing;

    HugAudioSource *source = [[HugAudioSource alloc] initWithAudioFile:file settings:_outputSettings];
    
    HugAuto weakSelf = self;
    BOOL didPrepare = [source prepareWithStartTime:startTime stopTime:stopTime padding:padding completionHandler:^(HugAudioSource *inSource) {
        [weakSelf _handleDidPrepareSource:inSource];
    }];

    if (!didPrepare) {
        HugLog(@"HugAudioEngine", @"Couldn't prepare %@", source);
        return NO;
    }
    
    // Order matters: the graph must be silent before the units are touched, and the new
    // source must not enter until they have been.
    //
    [self _waitForGraphToDrain];
    [self _applyPlaybackRate:rate];
    [self _applyEffectsBypass:bypassesEffects];

    [self _sendAudioSourceToRenderThread:source];
    _renderUserInfo.volume = _volume;

    // Read the rate back off the unit rather than trusting what we last wrote, so a track
    // starting through an active phase vocoder rather than the transparent path at 1.0 is
    // visible in the log.
    //
    if (_timePitchAudioUnit) {
        AUParameter *rateParam = [[_timePitchAudioUnit parameterTree] parameterWithID:0 scope:kAudioUnitScope_Global element:0];

        HugLog(@"HugAudioEngine", @"time-pitch rate parameter reads %g at track start (%@), effects %@",
            [rateParam value], ([rateParam value] == 1.0f) ? @"transparent" : @"ACTIVE",
            bypassesEffects ? @"bypassed" : @"active");
    }

    HugLog(@"HugAudioEngine", @"setup complete, starting output");

    if (![self _isRunning]) {
        HugCheckError(
            AudioOutputUnitStart(_outputAudioUnit),
            @"HugAudioEngine", @"AudioOutputUnitStart"
        );
    }

    if (!_updateTimer) {
        _updateTimer = [NSTimer timerWithTimeInterval:(1.0/30.0) target:self selector:@selector(_handleUpdateTimer:) userInfo:nil repeats:YES];
        [_updateTimer setTolerance:(1.0/60.0)];

        [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSRunLoopCommonModes];
        [[NSRunLoop mainRunLoop] addTimer:_updateTimer forMode:NSEventTrackingRunLoopMode];
    }

    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(_reallyStopHardware) object:nil];

    return YES;
}


- (void) stopPlayback
{
    _HugCrashPadEnabled = NO;

    _renderUserInfo.volume = 0;

    if ([self _isRunning]) {
        [self _sendAudioSourceToRenderThread:nil];

        // The units in the graph are still rendering -- -_reallyStopHardware is 30 seconds
        // out -- so we cannot -reset them from here. They are being fed silence as of now;
        // -_waitForGraphToDrain holds the next track back until they have flushed it.
        //
        _graphNeedsDrain = YES;

        [self performSelector:@selector(_reallyStopHardware) withObject:nil afterDelay:30];

    } else {
        // Hardware is stopped, so -_reallyStopHardware has already reset the units.
        _graphNeedsDrain = NO;
    }

    HugRingBufferConfirmReadAll(_statusRingBuffer);

    HugLevelMeterReset(_leftLevelMeter);
    HugLevelMeterReset(_rightLevelMeter);

    // Gain reduction must not follow one track into the next. Once it engages, the limiter's
    // decay time doubles on every re-trigger up to 16 seconds, so without this a track that
    // drove it hard leaves the one after it quieter and flatter for that long. The time-pitch
    // unit makes that easy to hit: above 1.0 it rewrites phase relationships and peaks can
    // land several dB higher than the material they came from.
    //
    // Safe here for the same reason the meter resets above are: volume was set to zero at the
    // top of this method and -_sendAudioSourceToRenderThread: has since waited out a render
    // cycle, so the limiter is looking at silence and will not re-trigger from the tail.
    //
    HugLimiterReset(_emergencyLimiter);

    _playbackStatus = HugPlaybackStatusStopped;
    _timeElapsed    = 0;
    _timeRemaining  = 0;
    _leftMeterData  = nil;
    _rightMeterData = nil;
    _dangerLevel    = 0;
}


- (void) stopHardware
{
    [self stopPlayback];
    [self _reallyStopHardware];
}


- (void) updateStereoWidth:(float)stereoWidth
{
    _renderUserInfo.stereoWidth = stereoWidth;
}


- (void) updateStereoBalance:(float)stereoBalance
{
    _renderUserInfo.stereoBalance = stereoBalance;
}


- (void) updatePreGain:(float)preGain
{
    _renderUserInfo.preGain = preGain;
}


- (void) updateVolume:(float)volume
{
    _volume = volume;
    if (_playbackStatus != HugPlaybackStatusStopped) {
        _renderUserInfo.volume = volume;
    }
}


- (void) updatePlaybackRate:(double)rate
{
    if (_timePitchAudioUnit) {
        AUParameter *rateParam = [[_timePitchAudioUnit parameterTree] parameterWithID:0 scope:kAudioUnitScope_Global element:0];
        [rateParam setValue:rate];
    }
}


- (void) updateEffectAudioUnits:(NSArray<AUAudioUnit *> *)effectAudioUnits
{
    // Same object, or same units in the same order, means there is nothing to rebuild. The
    // pointer check also covers both being nil, which -isEqual: would not.
    //
    if (_effectAudioUnits == effectAudioUnits) return;
    if ([_effectAudioUnits isEqual:effectAudioUnits]) return;

    // Units that were in the chain and no longer are. They keep whatever tail was in them
    // otherwise, and would play it out if they were added back later.
    //
    NSMutableArray *effectsToRemove = [NSMutableArray array];

    for (AUAudioUnit *unit in _effectAudioUnits) {
        if (![effectAudioUnits containsObject:unit]) {
            [effectsToRemove addObject:unit];
        }
    }

    _effectAudioUnits = effectAudioUnits;

    // A unit added mid-track inherits the bypass state of the track that is playing.
    for (AUAudioUnit *unit in effectAudioUnits) {
        if ([unit shouldBypassEffect] != _effectsBypassed) {
            [unit setShouldBypassEffect:_effectsBypassed];
        }
    }

    [self _reconnectGraph];

    // Only safe after -_reconnectGraph, which waits for the render thread to pick up the new
    // graph, so these units are no longer being rendered.
    //
    for (AUAudioUnit *unit in effectsToRemove) {
        [unit reset];
    }
}


@end
