// (c) 2017-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Foundation/Foundation.h>

extern NSString * const ScriptsManagerDidReloadNotification;

@class Track, ScriptFile;


@interface ScriptsManager : NSObject

+ (instancetype) sharedInstance;

- (void) revealScriptsFolder;

- (void) callMetadataAvailableWithTrack:(Track *)track;
- (void) callCurrentTrackChanged;
- (void) callTracksChanged;

@property (nonatomic, readonly) NSArray<ScriptFile *> *allScriptFiles;
@property (nonatomic, readonly) ScriptFile *handlerScriptFile;

@property (nonatomic) NSMenuItem *scriptsMenuItem;

@end
