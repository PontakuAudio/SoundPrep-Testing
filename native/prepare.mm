// Parent-side utilities. Focus is restored only from the owned worker PID.
#import <Cocoa/Cocoa.h>
#include <mach-o/dyld.h>
#include <string>
#include <vector>
extern "C" const char *AMExecutablePath() {
  static std::string path;
  if(path.empty()) {
    uint32_t size=0;_NSGetExecutablePath(nullptr,&size);
    std::vector<char> bytes(size);
    if(_NSGetExecutablePath(bytes.data(),&size)==0)path=bytes.data();
  }
  return path.c_str();
}
extern "C" void AMPrepareFocus(int pid) {
  NSRunningApplication *front=NSWorkspace.sharedWorkspace.frontmostApplication;
  if(pid>0 && front.processIdentifier==pid)[NSApp activateIgnoringOtherApps:YES];
}
