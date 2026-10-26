// Integration fixture, loaded ONLY by tools/prepare_test_host.py's marked host.
// Calls the actual NSDraggingDestination entry point with a controlled payload.
// No mouse/keyboard synthesis and never installed in the user's REAPER profile.
#import <Cocoa/Cocoa.h>
struct Host {int version;void *main;int(*reg)(const char*,void*);void*(*get)(const char*);};
@interface AMTestDrag : NSObject
@property(strong) NSView *draggingSource;
@property(strong) NSPasteboard *draggingPasteboard;
@property NSPoint draggingLocation;
@end
@implementation AMTestDrag
@end
static bool invokeAt(void *source,void *target,void *area,int x,int y,const char *path) {
 NSView *wave=(__bridge NSView*)source,*arrange=(__bridge NSView*)target;
 if([(id)arrange isKindOfClass:NSWindow.class])arrange=[(NSWindow*)(id)arrange contentView];
 NSView *position=(__bridge NSView*)area;
 if([(id)position isKindOfClass:NSWindow.class])position=[(NSWindow*)(id)position contentView];
 AMTestDrag *drag=[AMTestDrag new];drag.draggingSource=wave;
 drag.draggingPasteboard=[NSPasteboard pasteboardWithUniqueName];
 [drag.draggingPasteboard declareTypes:@[@"NSFilenamesPboardType"] owner:nil];
 [drag.draggingPasteboard setPropertyList:[[NSString stringWithUTF8String:path] componentsSeparatedByString:@"\n"] forType:@"NSFilenamesPboardType"];
 NSPoint pt=NSMakePoint(x,position.isFlipped ? y : position.bounds.size.height-y);
 drag.draggingLocation=[position convertPoint:pt toView:nil];
 BOOL result=[arrange performDragOperation:(id)drag];
 [drag.draggingPasteboard releaseGlobally];return result;
}
static bool invoke(void *source,void *target,const char *path) {return invokeAt(source,target,target,200,30,path);}
static void *var(void **p,int n) {return (void*)(intptr_t)(n==3 && invoke(p[0],p[1],(const char*)p[2]));}
static void *varAt(void **p,int n) {return (void*)(intptr_t)(n==6 && invokeAt(p[0],p[1],p[2],(int)(intptr_t)p[3],(int)(intptr_t)p[4],(const char*)p[5]));}
extern "C" __attribute__((visibility("default"))) int ReaperPluginEntry(void*,Host *h) {
 if(!h)return 0;
 auto path=(const char*(*)())h->get("GetResourcePath");
 if(!path || ![[NSFileManager defaultManager] fileExistsAtPath:[[NSString stringWithUTF8String:path()] stringByAppendingPathComponent:@".audition-macro-test"]])return 0;
 h->reg("API_AM_TestWaveformDrop",(void*)invoke);h->reg("APIvararg_AM_TestWaveformDrop",(void*)var);
 h->reg("APIdef_AM_TestWaveformDrop",(void*)"bool\0void*,void*,const char*\0source,target,path\0Isolated-host integration fixture.");
 h->reg("API_AM_TestDropAt",(void*)invokeAt);h->reg("APIvararg_AM_TestDropAt",(void*)varAt);
 h->reg("APIdef_AM_TestDropAt",(void*)"bool\0void*,void*,void*,int,int,const char*\0source,destination,area,x,y,path\0Isolated-host drop at a point measured from the area's top left.");return 1;
}
