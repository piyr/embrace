// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

typedef NSString *HugAudioSettings NS_STRING_ENUM;

// NSNumber, the desired sampling rate.
extern HugAudioSettings const HugAudioSettingSampleRate;

// NSNumber, the desired value of kAudioDevicePropertyBufferFrameSize.
extern HugAudioSettings const HugAudioSettingFrameSize;

// If @YES, Hug attempts to take exclusive access of the device (Hog Mode) upon playback.
extern HugAudioSettings const HugAudioSettingTakeExclusiveAccess;

// If @YES, the device is reset to the maximum volume upon playback.
extern HugAudioSettings const HugAudioSettingResetDeviceVolume;


// The time-pitch unit pulls roughly (frameCount * rate) input frames for every frameCount
// frames it renders, so at rates above 1.0 it asks the source for more than one output
// buffer's worth. Everything upstream of it -- the source's scratch buffers, the sample
// rate converter, the pre-gain ramper -- must be sized against this bound rather than
// against HugAudioSettingFrameSize.
static inline UInt32 HugGetMaxInternalFrameCount(UInt32 frameSize)
{
    return MAX(16384, frameSize * 4);
}


