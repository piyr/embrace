// (c) 2018-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>
#import "HugAudioSource.h"

@class TrackScheduler, HugMeterData;

@interface HugAudioEngine : NSObject

- (BOOL) configureWithDeviceID:(AudioDeviceID)deviceID settings:(NSDictionary *)settings;

- (BOOL) playAudioFile: (HugAudioFile *) file
             startTime: (NSTimeInterval) startTime
              stopTime: (NSTimeInterval) stopTime
               padding: (NSTimeInterval) padding;

// Stops playback of the audio file
- (void) stopPlayback;

// Stops the actual audio hardware
- (void) stopHardware;

// Full-scale, linear, 1.0 = 0dBFS
- (void) updatePreGain:(float)preGain;

// Full-scale, linear, 1.0 = 0dBFS
- (void) updateVolume:(float)volume;

// -1.0 = reverse, 0.0 = mono, 1.0 = normal stereo
- (void) updateStereoWidth:(float)stereoWidth;

// -1.0 = left, 0.0 = center, 1.0 = right
- (void) updateStereoBalance:(float)stereoBalance;

- (void) updatePlaybackRate:(double)rate;

- (void) updateEffectAudioUnits:(NSArray<AUAudioUnit *> *)effectAudioUnits;

// Graph -> Player
@property (nonatomic, copy) void (^updateBlock)();

@property (nonatomic, readonly) HugPlaybackStatus playbackStatus;
@property (nonatomic, readonly) NSTimeInterval timeElapsed;
@property (nonatomic, readonly) NSTimeInterval timeRemaining;

@property (nonatomic, readonly) HugMeterData *leftMeterData;
@property (nonatomic, readonly) HugMeterData *rightMeterData;

@property (nonatomic, readonly) float dangerLevel;

@property (nonatomic, readonly) NSTimeInterval lastOverloadTime;

@end


