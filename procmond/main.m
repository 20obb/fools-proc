#import <Foundation/Foundation.h>
#import <signal.h>

#import "PMDaemon.h"

int main(int argc, char *argv[]) {
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);

        PMDaemon *daemon = [[PMDaemon alloc] init];
        NSError *error = nil;
        if (![daemon start:&error]) {
            NSLog(@"[ProcMon] Failed to start daemon: %@", error.localizedDescription);
            return 1;
        }

        NSLog(@"[ProcMon] procmond started");
        [[NSRunLoop currentRunLoop] run];
    }

    return 0;
}
