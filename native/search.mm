// Native search text access. Respect Cocoa's field editor and marked IME text.
#import <Cocoa/Cocoa.h>
#include <string>
static void*(*find_child)(void*,int);
static void*(*lookup)(const char*);
static NSTextField* control(void* parent) {
  if(!find_child && lookup)find_child=(decltype(find_child))lookup("JS_Window_FindChildByID");
  id value=find_child ? (__bridge id)find_child(parent,1015) : nil;
  return [value isKindOfClass:NSTextField.class] ? value : nil;
}
static NSString* value(NSTextField* field) {
  NSText* editor=field.currentEditor;return editor ? editor.string : field.stringValue;
}
static bool composing(NSTextField* field) {
  NSText* editor=field.currentEditor;
  return [editor isKindOfClass:NSTextView.class] && [(NSTextView*)editor hasMarkedText];
}
static const char* read_search(void* parent) {
  static std::string result;
  @autoreleasepool {
    NSTextField* field=control(parent);
    NSDictionary* state=field ? @{@"text":value(field),@"composing":@(composing(field))} : @{};
    NSData* data=[NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    result.assign((const char*)data.bytes,data.length);return result.c_str();
  }
}
static bool write_search(void* parent,const char* expected,const char* text) {
  @autoreleasepool {
    NSTextField* field=control(parent);
    if(!field || !expected || !text || strlen(text)>8192 || composing(field))return false;
    NSString* before=[NSString stringWithUTF8String:expected],*next=[NSString stringWithUTF8String:text];
    if(!before || !next || ![value(field) isEqualToString:before])return false;
    NSText* editor=field.currentEditor;NSRange selection=editor.selectedRange;
    field.stringValue=next;
    if(editor) {
      editor.string=next;selection.location=MIN(selection.location,next.length);
      selection.length=MIN(selection.length,next.length-selection.location);editor.selectedRange=selection;
    }
    return true;
  }
}
static void* read_var(void** p,int n){return n==1 ? const_cast<char*>(read_search(p[0])) : nullptr;}
static void* write_var(void** p,int n){return (void*)(intptr_t)(n==3 && write_search(p[0],(const char*)p[1],(const char*)p[2]));}
extern "C" void AMSearchRegister(int(*reg)(const char*,void*),void*(*get)(const char*)) {
  lookup=get;
  reg("API_AM_SearchRead",(void*)read_search);reg("APIvararg_AM_SearchRead",(void*)read_var);
  reg("APIdef_AM_SearchRead",(void*)"const char*\0void*\0parent\0Read native search text and IME composition state as JSON.");
  reg("API_AM_SearchWrite",(void*)write_search);reg("APIvararg_AM_SearchWrite",(void*)write_var);
  reg("APIdef_AM_SearchWrite",(void*)"bool\0void*,const char*,const char*\0parent,expected,text\0Replace matching native search text unless an IME composition is active. Caller sends the native search notification.");
}
