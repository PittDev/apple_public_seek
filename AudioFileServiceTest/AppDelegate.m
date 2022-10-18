//
//  AppDelegate.m
//  AudioFileServiceTest
//
//  Created by Pitt on 12/08/2022.
//

#import "AppDelegate.h"
#import "AudioFileTest.h"

@interface AppDelegate ()
@property (strong) IBOutlet NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
  launchTest();
}

- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app {
  return YES;
}

@end
