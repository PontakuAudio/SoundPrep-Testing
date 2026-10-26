// Cocoa model/view tests; no visible window or system input events required.
#import <Cocoa/Cocoa.h>
#include <cassert>
#include <cstdio>
#import "search.mm"
@interface SearchEditorFixture : NSTextView
@property BOOL fixtureMarked;
@end
@implementation SearchEditorFixture
- (BOOL)hasMarkedText{return self.fixtureMarked;}
@end
@interface SearchFieldFixture : NSTextField
@property(strong) NSText* fixtureEditor;
@end
@implementation SearchFieldFixture
- (NSText*)currentEditor{return self.fixtureEditor;}
@end
static SearchFieldFixture* fixture;
static void* findFixture(void*,int id){return id==1015 ? (__bridge void*)fixture : nullptr;}
static NSDictionary* decoded(const char* text){return [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];}
int main(){@autoreleasepool {
  [NSApplication sharedApplication];
  fixture=[[SearchFieldFixture alloc]initWithFrame:NSMakeRect(0,0,200,26)];find_child=findFixture;
  fixture.stringValue=@"stored";
  assert([decoded(read_search(nullptr))[@"text"] isEqual:@"stored"]);
  assert(!write_search(nullptr,"stale","replaced"));assert(write_search(nullptr,"stored","slam"));
  SearchEditorFixture* editor=[[SearchEditorFixture alloc]initWithFrame:NSMakeRect(0,0,200,26)];fixture.fixtureEditor=editor;
  editor.string=@"typed text";editor.selectedRange=NSMakeRange(8,2);
  assert([decoded(read_search(nullptr))[@"text"] isEqual:@"typed text"]);
  assert(!write_search(nullptr,"slam","lost typing"));
  editor.fixtureMarked=YES;assert([decoded(read_search(nullptr))[@"composing"] boolValue]);
  assert(!write_search(nullptr,"typed text","lost composition"));assert([editor.string isEqual:@"typed text"]);
  editor.fixtureMarked=NO;assert(write_search(nullptr,"typed text","hit"));
  assert([editor.string isEqual:@"hit"] && [fixture.stringValue isEqual:@"hit"] && editor.selectedRange.location==3);
  std::string huge(8193,'a');assert(!write_search(nullptr,"hit",huge.c_str()));
  fixture.fixtureEditor=nil;
  puts("PASS: native search field editor, IME guard, compare-and-set and selection");
}}
