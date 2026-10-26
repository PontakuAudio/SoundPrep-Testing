// Loaded ONLY by the owned, optional background-render process. Prevent a render
// dialog or FX editor from activating that process and closing the foreground
// REAPER's audio device under its normal "close audio when inactive" preference.
#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#include <sys/stat.h>
#include <string>
#include <set>
#include <fstream>
struct WorkerHost { int version;void *window;int(*reg)(const char*,void*);void*(*get)(const char*); };
static WorkerHost host{};
static bool owned=false;
static std::string readyMarker;
static std::string commandFile;
static bool started=false;
static unsigned startupTicks=0;
static std::set<std::string> seen;
static BOOL (*originalPolicy)(id,SEL,NSApplicationActivationPolicy);
static BOOL backgroundPolicy(id app,SEL selector,NSApplicationActivationPolicy) {
  return originalPolicy(app,selector,NSApplicationActivationPolicyProhibited);
}
static void noActivation(id,SEL,BOOL) {}
static void lockBackgroundPolicy() {
  Class base=object_getClass(NSApp);
  Class worker=objc_allocateClassPair(base,"AMBackgroundRenderApplication",0);
  if(!worker)return;
  SEL policy=@selector(setActivationPolicy:);
  originalPolicy=reinterpret_cast<decltype(originalPolicy)>(class_getMethodImplementation(base,policy));
  class_addMethod(worker,policy,reinterpret_cast<IMP>(backgroundPolicy),method_getTypeEncoding(class_getInstanceMethod(base,policy)));
  SEL activate=@selector(activateIgnoringOtherApps:);
  class_addMethod(worker,activate,reinterpret_cast<IMP>(noActivation),method_getTypeEncoding(class_getInstanceMethod(base,activate)));
  objc_registerClassPair(worker);object_setClass(NSApp,worker);
  [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
}
static void hideWorker() {
  if(!owned)return;
  [NSApp setActivationPolicy:NSApplicationActivationPolicyProhibited];
  if(!started && ++startupTicks>10) {
    auto add=reinterpret_cast<int(*)(bool,int,const char*,bool)>(host.get("AddRemoveReaScript"));
    auto run=reinterpret_cast<void(*)(int,int,void*)>(host.get("Main_OnCommandEx"));
    auto project=reinterpret_cast<void*(*)(int,char*,int)>(host.get("EnumProjects"));
    if(add && run && project && project(-1,nullptr,0) && host.get("JS_Window_Show") && host.get("CF_CreatePreview")) {
      std::ifstream input(commandFile);std::string script;std::getline(input,script);
      if(!script.empty()) {
        started=true;
        int command=add(true,0,script.c_str(),true);
        if(command>0)run(command,0,project(-1,nullptr,0));
      }
    }
  }
  struct stat status{};
  if(stat(readyMarker.c_str(),&status)!=0)return;
  for(NSWindow *window in NSApp.windows) {
    std::string title=window.title.UTF8String ?: "";
    if(seen.size()<16 && seen.insert(title).second) NSLog(@"SoundPrep render window: %@",window.title);
    [window orderOut:nil];
  }
}
extern "C" __attribute__((visibility("default"))) int ReaperPluginEntry(void*,WorkerHost *api) {
  if(!api) { if(owned)host.reg("-timer",reinterpret_cast<void*>(hideWorker));owned=false;return 0; }
  if(api->version!=0x20e || !api->get || !api->reg)return 0;
  auto resource=reinterpret_cast<const char*(*)()>(api->get("GetResourcePath"));if(!resource)return 0;
  std::string marker=std::string(resource())+"/.audition-macro-worker";struct stat info{};
  if(stat(marker.c_str(),&info)!=0 || !S_ISREG(info.st_mode))return 0;
  readyMarker=std::string(resource())+"/.audition-macro-worker-ready";
  commandFile=std::string(resource())+"/.audition-macro-worker-command";
  host=*api;owned=true;lockBackgroundPolicy();hideWorker();host.reg("timer",reinterpret_cast<void*>(hideWorker));return 1;
}
