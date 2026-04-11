// (c) 2014-2024 Ricci Adams
// MIT License (or) 1-clause BSD License

#import <Cocoa/Cocoa.h>


static void sLogHello()
{
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSDictionary *localizedInfoDictionary = [mainBundle localizedInfoDictionary];
    NSDictionary *infoDictionary = [mainBundle infoDictionary];
  
    NSString *buildString = [localizedInfoDictionary objectForKey:@"CFBundleVersion"];
    if (!buildString) buildString = [infoDictionary objectForKey:@"CFBundleVersion"];

    NSString *versionString = [localizedInfoDictionary objectForKey:@"CFBundleShortVersionString"];
    if (!versionString) versionString = [infoDictionary objectForKey:@"CFBundleShortVersionString"];

    EmbraceLog(@"Hello", @"CloseEmbrace %@ (%@) launched at %@", versionString, buildString, [NSDate date]);
    EmbraceLog(@"Hello", @"Running on macOS %@", [[NSProcessInfo processInfo] operatingSystemVersionString]);
}


int main(int argc, const char * argv[])
{
    NSString *logPath = GetApplicationSupportDirectory();
    logPath = [logPath stringByAppendingPathComponent:@"Logs"];

    EmbraceLogSetDirectory(logPath);
    sLogHello();
    
    return NSApplicationMain(argc, (const char **) argv);
}
