// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

extern NSString * const TracksControllerDidModifyTracksNotificationName;

extern NSString *EmbraceLockedTrackPasteboardType;
extern NSString *EmbraceQueuedTrackPasteboardType;

@class Track, TrackTableView;

@interface TracksController : NSObject <NSTableViewDelegate, NSTableViewDataSource>

- (void) saveState;

- (void) copy:(id)sender;
- (void) paste:(id)sender;

- (Track *) firstQueuedTrack;
- (NSArray *) selectedTracks;

- (BOOL) addTracksWithURLs:(NSArray<NSURL *> *)urls;

- (void) removeAllTracks;
- (void) deselectAllTracks;
- (void) resetPlayedTracks;

- (void) revealTime:(id)sender;

- (void) toggleStopsAfterPlaying:(id)sender;
- (void) toggleIgnoreAutoGap:(id)sender;
- (void) changePlaybackRate:(id)sender;

// Speed of the selection. Absolute for the Speed submenu, relative for the +/- keys, which
// step each track from its own rate so a mixed selection keeps its relative offsets.
- (void) setPlaybackRateForSelectedTracks:(double)rate;
- (void) adjustPlaybackRateForSelectedTracksBy:(double)delta;

// YES when at least one selected track can still have its speed changed.
@property (nonatomic, readonly) BOOL canChangePlaybackRateForSelectedTracks;
- (void) toggleMarkAsPlayed:(id)sender;

- (void) detectDuplicates;

- (NSArray<NSString *> *) readableDraggedTypes;
- (NSDragOperation) validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation;
- (BOOL) acceptDrop:(id <NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation;

- (void) didFinishTrack:(Track *)finishedTrack;
- (void) updatePlayingTrackCell;

- (Track *) trackAtIndex:(NSUInteger)index;
@property (nonatomic, readonly) NSArray *tracks;

@property (nonatomic, readonly) NSTimeInterval modificationTime;

- (IBAction) delete:(id)sender;


@end
