// Instance-local Cocoa drop interception. Only drags whose source is the
// attached native ME waveform or file list are handled. Finder/other-project drops pass
// through untouched. No polling for newly-created project items is involved.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <string>
#include <unordered_set>
extern "C" void AMDropDetach();

namespace {
struct Hook { __weak NSView *view; Class original; Class installed; };
static Hook hooks[3]; // Main content view, Arrange, track control panel.
static __weak NSView *wave;
static __weak NSView *fileList;
static id mouseMonitor;
static int sourceGesture=0; // 1 = waveform, 2 = file list
static void *project;
static int command;
static bool busy=false, result=false, pendingDetach=false;
static unsigned long serial=0;
static std::string context;
static void *(*enumProjects)(int,char*,int);
static void (*action)(int,int,void*);
static int (*countItems)(void*);
static void *(*getItem)(void*,int);
static bool (*itemString)(void*,const char*,char*,bool);
static void (*beginUndo)(void*);
static void (*endUndo)(void*,const char*,int);
static const char *(*canUndo)(void*);
static int (*undo)(void*);
static int (*stateCount)(void*);
static void finishTransaction() {
  context.clear();busy=false;
  if(pendingDetach){pendingDetach=false;AMDropDetach();}
}

static NSString *guid(void *item) {
  char id[128]={};return itemString(item,"GUID",id,false) ? [NSString stringWithUTF8String:id] : nil;
}
static void setContext(NSString *phase,NSArray *paths,NSString *origin,NSArray *items) {
  NSDictionary *value=@{@"phase":phase,@"path":paths[0],@"paths":paths,@"origin":origin,@"id":@(serial),@"items":items ?: @[]};
  NSData *data=[NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
  context.assign((const char *)data.bytes,data.length);
}
static Class baseClass(id self) {
  // May be called through another extension's subclass above our own.
  Class c=object_getClass(self);
  while(c) {
    if ([NSStringFromClass(c) hasPrefix:@"AMWaveDrop_"]) return class_getSuperclass(c);
    c=class_getSuperclass(c);
  }
  return Nil;
}
static BOOL originalDrop(id self,SEL sel,id sender) {
  Class base=baseClass(self);
  auto imp=(BOOL(*)(id,SEL,id))class_getMethodImplementation(base,sel);
  return imp ? imp(self,sel,sender) : NO;
}
static BOOL drop(id self,SEL sel,id<NSDraggingInfo> sender) {
  id source=sender.draggingSource;
  int origin=0;
  for(int i=1;i<=2;++i) {
    NSView *view=i==1 ? wave : fileList;
    const bool exact=view && [source isKindOfClass:[NSView class]] &&
      (source==view || [(NSView*)source isDescendantOf:view]);
  // Some SWELL paths report the owner view/window as the drag source. In that
  // case also require the actual gesture's mouse-down to be inside the waveform.
    const bool owner=sourceGesture==i && view &&
      (([source isKindOfClass:[NSView class]] && [view isDescendantOf:(NSView*)source]) || source==view.window);
    if(exact || owner){origin=i;break;}
  }
  if (busy || !wave || !command || enumProjects(-1,nullptr,0)!=project ||
      !origin)
    return originalDrop(self,sel,sender);
  // SWELL's native file drags use the filenames list, not file URL promises.
  NSArray *files=[sender.draggingPasteboard propertyListForType:@"NSFilenamesPboardType"];
  if (![files isKindOfClass:[NSArray class]] || files.count==0 || (origin==1 && files.count!=1))return NO;
  for(id path in files)if(![path isKindOfClass:[NSString class]])return NO;
  NSString *originName=origin==1 ? @"waveform" : @"list";
  // SWELL may deliver to either the child or the main content view. Accept
  // only the Arrange/TCP areas, never the whole root (which includes Mixer,
  // dockers and toolbars). Let REAPER decide placement and track creation.
  bool target=false;
  for(int i=1;i<=2;++i) {
    NSView *view=hooks[i].view;
    if(view && view.window==[(NSView*)self window] && !view.isHiddenOrHasHiddenAncestor &&
        NSPointInRect([view convertPoint:sender.draggingLocation fromView:nil],view.bounds)) {
      target=true;break;
    }
  }
  if(!target)return originalDrop(self,sel,sender);
  sourceGesture=0;busy=true;++serial;result=false;
  setContext(@"prepare",files,originName,nil);action(command,0,project);
  if (!result || enumProjects(-1,nullptr,0)!=project) { finishTransaction();return NO; }
  std::unordered_set<void*> before;
  for(int i=0;i<countItems(project);++i) before.insert(getItem(project,i));
  const int state=stateCount(project);
  beginUndo(project);
  BOOL accepted=originalDrop(self,sel,sender);
  NSMutableArray *items=[NSMutableArray array];
  for(int i=0;i<countItems(project);++i) {
    void *item=getItem(project,i);
    if (!before.count(item)) { NSString *id=guid(item);if(id)[items addObject:id]; }
  }
  result=false;
  if (accepted && items.count==files.count) {
    setContext(@"finish",files,originName,items);action(command,0,project);
  }
  const bool success=result;
  std::string label=success ? "Insert SoundPrep" : "Cancelled SoundPrep drop "+std::to_string(serial);
  endUndo(project,label.c_str(),-1);
  // Roll back only our just-created undo entry; never undo an earlier user edit.
  const char *top=canUndo(project);
  if (!success && stateCount(project)!=state && top && label==top) undo(project);
  if(!accepted || items.count!=files.count) {setContext(@"cancel",files,originName,items);action(command,0,project);}
  finishTransaction();
  return success ? YES : NO;
}
static bool install(Hook &hook,NSView *view) {
  if(hook.view==view) return true;
  Class original=object_getClass(view);
  if(baseClass(view)) {hook={view,Nil,Nil};return true;}
  Method method=class_getInstanceMethod(original,@selector(performDragOperation:));
  if(!method) return false;
  NSString *name=[@"AMWaveDrop_" stringByAppendingString:NSStringFromClass(original)];
  Class sub=NSClassFromString(name);
  if(!sub) {
    sub=objc_allocateClassPair(original,name.UTF8String,0);
    if(!sub)return false;
    class_addMethod(sub,@selector(performDragOperation:),(IMP)drop,method_getTypeEncoding(method));
    objc_registerClassPair(sub);
  }
  hook={view,original,sub};object_setClass(view,sub);return true;
}
}
extern "C" void AMDropDetach() {
  if(busy){pendingDetach=true;return;}
  if(mouseMonitor){[NSEvent removeMonitor:mouseMonitor];mouseMonitor=nil;}
  sourceGesture=0;
  wave=nil;fileList=nil;command=0;project=nullptr;context.clear();
  for(auto &h:hooks) {
    if(h.view && object_getClass(h.view)==h.installed)object_setClass(h.view,h.original);
    h.view=nil;
  }
}
extern "C" bool AMDropAttachSources(void *main,void *arrange,void *source,void *list,void *proj,int cmd,void *(*get)(const char*)) {
  if(busy)return false;
  NSView *m=(__bridge NSView*)main,*a=(__bridge NSView*)arrange,*w=(__bridge NSView*)source,*l=(__bridge NSView*)list;
  if([(id)m isKindOfClass:NSWindow.class])m=[(NSWindow*)(id)m contentView];
  if(![m isKindOfClass:NSView.class] || ![a isKindOfClass:NSView.class] || ![w isKindOfClass:NSView.class])return false;
  if(l && ![l isKindOfClass:NSView.class])return false;
  // TCP has no stable numeric control ID on macOS. Match REAPER's native
  // class name, which is independent of the theme and translated labels.
  auto find=reinterpret_cast<void*(*)(void*,void*,const char*,const char*)>(get("JS_Window_FindEx"));
  NSView *tcp=find ? (__bridge NSView*)find(main,main,"REAPERTCPDisplay","") : nil;
  if(![tcp isKindOfClass:NSView.class])return false;
  if(hooks[0].view==m && hooks[1].view==a && hooks[2].view==tcp && wave==w && fileList==l && project==proj && command==cmd)return true;
  AMDropDetach();
#define RESOLVE(v,n) v=reinterpret_cast<decltype(v)>(get(n));if(!v)return false
  RESOLVE(enumProjects,"EnumProjects");RESOLVE(action,"Main_OnCommandEx");
  RESOLVE(countItems,"CountMediaItems");RESOLVE(getItem,"GetMediaItem");
  RESOLVE(itemString,"GetSetMediaItemInfo_String");RESOLVE(beginUndo,"Undo_BeginBlock2");
  RESOLVE(endUndo,"Undo_EndBlock2");RESOLVE(canUndo,"Undo_CanUndo2");RESOLVE(undo,"Undo_DoUndo2");RESOLVE(stateCount,"GetProjectStateChangeCount");
#undef RESOLVE
  if(!install(hooks[0],m) || !install(hooks[1],a) || !install(hooks[2],tcp)){AMDropDetach();return false;}
  wave=w;fileList=l;project=proj;command=cmd;
  mouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent*(NSEvent *event) {
    NSView *hit=[event.window.contentView hitTest:event.locationInWindow];
    sourceGesture=0;
    if(wave && event.window==wave.window && (hit==wave || [hit isDescendantOf:wave]))sourceGesture=1;
    else if(fileList && event.window==fileList.window && (hit==fileList || [hit isDescendantOf:fileList]))sourceGesture=2;
    return event;
  }];
  return true;
}
extern "C" bool AMDropAttach(void *main,void *arrange,void *source,void *proj,int cmd,void *(*get)(const char*)) {
  return AMDropAttachSources(main,arrange,source,nullptr,proj,cmd,get);
}
extern "C" const char *AMDropContext(){return context.c_str();}
extern "C" void AMDropResult(bool ok){if(busy)result=ok;}
