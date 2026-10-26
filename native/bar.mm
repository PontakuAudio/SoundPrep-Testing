// macOS child view inside Media Explorer. REAPER keeps ownership of its browser.
// Cocoa handles drawing, menus and accessibility; Lua owns all audition state.
#import <Cocoa/Cocoa.h>
#include <deque>
#include <string>
#include <cmath>
#include <cstring>
#include "contract.h"
#import "channel_panel.h"
#import "settings_panel.h"
#import "editor_panel.h"

// Render Unicode with Cocoa rather than SWELL's low-contrast glyph cache.
// The bounded cache avoids shaping each label again on playhead updates.
extern "C" int AMWavePixelScale(void* view) {
  return std::clamp((int)std::lround([(__bridge NSView*)view window].backingScaleFactor),1,2);
}
extern "C" bool AMDrawWaveLabel(void* bitmap,const char* text,int x,int y,int width,int height,unsigned int foreground,unsigned int background,int scale,void*(*lookup)(const char*)) {
  auto bits=reinterpret_cast<unsigned int*(*)(void*)>(lookup("LICE__GetBits"));
  auto stride=reinterpret_cast<int(*)(void*)>(lookup("LICE__GetRowSpan"));
  auto bitmapHeight=reinterpret_cast<int(*)(void*)>(lookup("LICE__GetHeight"));
  auto flipped=reinterpret_cast<bool(*)(void*)>(lookup("LICE__IsFlipped"));
  if(!bits || !stride || !bitmapHeight || !flipped || width<1 || height<1)return false;
  @autoreleasepool {
    NSString* label=[NSString stringWithUTF8String:text];if(!label)return false;
    auto color=[](unsigned int pixel){return [NSColor colorWithDeviceRed:((pixel>>16)&255)/255.0 green:((pixel>>8)&255)/255.0 blue:(pixel&255)/255.0 alpha:1];};
    NSDictionary* attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:11*scale],NSForegroundColorAttributeName:color(foreground)};
    width=std::min(width,(int)std::ceil([label sizeWithAttributes:attributes].width)+2);
    NSString* key=[NSString stringWithFormat:@"%d:%d:%d:%08x:%08x:%@",width,height,scale,foreground,background,label];
    static NSMutableDictionary<NSString*,NSData*>* cache=[NSMutableDictionary dictionary];static NSUInteger bytes=0;
    NSData* raster=cache[key];
    if(!raster) {
      NSBitmapImageRep* rep=[[NSBitmapImageRep alloc]initWithBitmapDataPlanes:nil pixelsWide:width pixelsHigh:height bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:width*4 bitsPerPixel:32];
      if(!rep)return false;
      [NSGraphicsContext saveGraphicsState];[NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
      [color(background)setFill];NSRectFill(NSMakeRect(0,0,width,height));
      [label drawAtPoint:NSMakePoint(0,0) withAttributes:attributes];[NSGraphicsContext restoreGraphicsState];
      raster=[NSData dataWithBytes:rep.bitmapData length:width*height*4];
      if(cache.count>=128 || bytes+raster.length>8*1024*1024){[cache removeAllObjects];bytes=0;}
      cache[key]=raster;bytes+=raster.length;
    }
    auto dest=bits(bitmap);const int pitch=stride(bitmap),bh=bitmapHeight(bitmap);const bool flip=flipped(bitmap);
    if(!dest || pitch<x+width || y+height>bh)return false;
    auto src=static_cast<const unsigned char*>(raster.bytes);
    for(int row=0;row<height;++row)for(int col=0;col<width;++col) {
      auto p=src+(row*width+col)*4;
      dest[(flip?bh-1-y-row:y+row)*pitch+x+col]=0xff000000u|(p[0]<<16)|(p[1]<<8)|p[2];
    }
    return true;
  }
}

struct AMCocoaValue {
  id value;
  amcontract::Kind kind() const {
    if(!value)return amcontract::Kind::missing;
    if([value isKindOfClass:[NSDictionary class]])return amcontract::Kind::object;
    if([value isKindOfClass:[NSArray class]])return amcontract::Kind::array;
    if([value isKindOfClass:[NSString class]])return amcontract::Kind::string;
    if([value isKindOfClass:[NSNumber class]]) {
      if(CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID())return amcontract::Kind::boolean;
      if(std::isfinite([value doubleValue]))return amcontract::Kind::number;
    }
    return amcontract::Kind::null_value;
  }
  AMCocoaValue child(const char* name) const { return {[(NSDictionary *)value objectForKey:[NSString stringWithUTF8String:name]]}; }
  std::size_t size() const { return [(NSArray *)value count]; }
  double number() const { return [(NSNumber *)value doubleValue]; }
  AMCocoaValue at(std::size_t index) const { return {[(NSArray *)value objectAtIndex:index]}; }
};

static std::deque<std::string> events;
static void enqueue(NSString *value) {
  if (!value) return;
  if (events.size() == 64) events.pop_front();
  events.emplace_back(value.UTF8String ?: "");
}

@interface AMAuditionBar : NSView
@property(nonatomic, weak) NSView *list;
@property(nonatomic, weak) NSView *host;
@property(nonatomic) NSRect baseFrame;
@property(nonatomic) NSRect appliedFrame;
@property(nonatomic) BOOL adjusting;
@property(nonatomic) BOOL restoring;
@property(nonatomic) BOOL wasPosting;
@property(nonatomic) BOOL paused;
@property(nonatomic, strong) NSArray<NSControl *> *controls;
@property(nonatomic, strong) NSArray<NSButton *> *presets;
@property(nonatomic, strong) NSButton *raw;
@property(nonatomic, strong) NSButton *normalize;
@property(nonatomic, strong) NSButton *downmix;
@property(nonatomic, strong) NSPopUpButton *targets;
@property(nonatomic, strong) NSPopUpButton *monitor;
@property(nonatomic, strong) NSTextField *status;
@property(nonatomic, strong) NSDictionary *state;
@property(nonatomic, strong) AMChannelPanel *channelPanel;
@property(nonatomic, strong) AMSettingsPanel *settingsPanel;
@property(nonatomic, strong) AMEditorPanel *editorPanel;
@property(nonatomic, weak) NSView *returnFocus;
@property(nonatomic) NSRange returnSelection;
@property(nonatomic) BOOL returnHasSelection;
@property(nonatomic, strong) id mouseMonitor;
- (instancetype)initWithHost:(NSView *)host list:(NSView *)list;
- (void)restore;
- (void)reflow;
- (void)update:(NSDictionary *)state;
- (void)rememberFocus;
@end

@implementation AMAuditionBar
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return NO; }
- (NSButton *)button:(NSString *)title command:(NSString *)command toggle:(BOOL)toggle {
  NSButton *b=[NSButton buttonWithTitle:title target:self action:@selector(pressed:)];
  b.bezelStyle=NSBezelStyleRounded;
  b.buttonType=toggle ? NSButtonTypePushOnPushOff : NSButtonTypeMomentaryPushIn;
  b.identifier=command; b.font=[NSFont systemFontOfSize:11]; b.toolTip=title;
  b.controlSize=NSControlSizeSmall;
  b.cell.lineBreakMode=NSLineBreakByTruncatingTail;
  return b;
}
- (NSPopUpButton *)popup:(NSString *)command {
  NSPopUpButton *b=[[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
  b.target=self; b.action=@selector(picked:); b.identifier=command;
  b.font=[NSFont systemFontOfSize:11]; b.controlSize=NSControlSizeSmall; return b;
}
- (instancetype)initWithHost:(NSView *)host list:(NSView *)list {
  if (!(self=[super initWithFrame:NSZeroRect])) return nil;
  self.host=host; self.list=list; self.baseFrame=list.frame; self.appliedFrame=list.frame;
  NSMutableArray<NSControl *> *controls=[NSMutableArray array];
  for (const auto &spec:amcontract::controls) {
    NSString *title=[NSString stringWithUTF8String:spec.title];
    NSString *command=[NSString stringWithUTF8String:spec.command];
    NSControl *control=spec.kind==amcontract::ControlKind::popup ? [self popup:command] :
      [self button:title command:command toggle:spec.kind==amcontract::ControlKind::toggle];
    control.toolTip=[NSString stringWithUTF8String:spec.tooltip]; control.accessibilityLabel=title;
    [controls addObject:control]; [self addSubview:control];
  }
  self.controls=controls;
  self.raw=(NSButton *)controls[amcontract::raw];
  self.normalize=(NSButton *)controls[amcontract::normalize];
  self.downmix=(NSButton *)controls[amcontract::downmix];
  self.targets=(NSPopUpButton *)controls[amcontract::target];
  self.monitor=(NSPopUpButton *)controls[amcontract::monitor];
  NSMutableArray<NSButton *> *presets=[NSMutableArray array];
  for (NSUInteger i=0;i<amcontract::max_macros;i++) {
    NSButton *button=[self button:@"" command:@"macro:" toggle:YES];
    button.hidden=YES; [presets addObject:button]; [self addSubview:button];
  }
  self.presets=presets;
  self.channelPanel=[[AMChannelPanel alloc]initWithSender:enqueue];
  self.settingsPanel=[[AMSettingsPanel alloc]initWithSender:enqueue];
  self.editorPanel=[[AMEditorPanel alloc]initWithSender:enqueue];
  self.status=[NSTextField labelWithString:@""]; self.status.font=[NSFont systemFontOfSize:10];
  self.status.textColor=[NSColor secondaryLabelColor]; self.status.lineBreakMode=NSLineBreakByTruncatingTail;
  [self addSubview:self.status]; [host addSubview:self];
  self.wasPosting=list.postsFrameChangedNotifications; list.postsFrameChangedNotifications=YES;
  [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(frameChanged:)
    name:NSViewFrameDidChangeNotification object:list];
  __weak AMAuditionBar *weakSelf=self;
  self.mouseMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown handler:^NSEvent *(NSEvent *event) {
    AMAuditionBar *owner=weakSelf;
    if (owner && event.window==owner.window) [owner rememberFocus];
    return event;
  }];
  [self rememberFocus];
  [self reflow]; return self;
}
- (void)frameChanged:(NSNotification *)note {
  (void)note;
  if (self.adjusting || self.restoring || !self.list) return;
  NSRect frame=self.list.frame;
  if (NSEqualRects(frame,self.appliedFrame)) return;
  self.baseFrame=frame; [self reflow];
}
- (void)reflow {
  if (!self.list || !self.host || self.restoring) return;
  self.adjusting=YES;
  NSRect base=self.baseFrame;
  // Match Windows: presets share the top row; audition controls wrap below.
  BOOL compact=base.size.width<amcontract::compact_width || base.size.height<amcontract::compact_height;
  BOOL minimal=base.size.height<amcontract::minimal_height;
  NSUInteger rows=1; CGFloat x=3;
  for (NSUInteger i=1;i<self.controls.count;i++) {
    if (i==amcontract::downmix && ![self.state[@"multichannel"] boolValue]) continue;
    CGFloat width=compact ? amcontract::controls[i].compact_width : amcontract::controls[i].width;
    if (!width) continue;
    if (x+width>base.size.width-3) { rows++; x=3; }
    x+=width+3;
  }
  CGFloat height=minimal ? 30 : 28+rows*26+(compact ? 0 : 18);
  if (base.size.height<height+amcontract::min_list_height || base.size.width<amcontract::min_width) {
    self.hidden=YES; self.list.frame=base; self.appliedFrame=base; self.adjusting=NO; return;
  }
  self.hidden=NO;
  NSRect strip=base, files=base;
  strip.size.height=height; files.size.height-=height;
  if (self.host.isFlipped) files.origin.y+=height;
  else strip.origin.y+=base.size.height-height;
  self.frame=strip; self.list.frame=files; self.appliedFrame=files;
  NSArray *macros=self.state[@"macros"] ?: @[];
  NSUInteger count=1+macros.count;
  CGFloat available=base.size.width-(minimal ? 84 : 6);
  CGFloat width=std::floor(MIN(156,(available-(count-1)*3)/count));
  self.raw.title=width<50 ? @"0" : @"0 Raw";
  self.raw.hidden=NO; self.raw.frame=NSMakeRect(3,2,width,24);
  for (NSUInteger i=0;i<self.presets.count;i++) {
    NSButton *b=self.presets[i]; b.hidden=i>=macros.count;
    if (b.hidden) continue;
    NSString *label=macros[i][@"label"];
    if (width<64) {
      NSRange separator=[label rangeOfString:@"  "];
      NSString *slot=separator.location==NSNotFound ? nil : [label substringToIndex:separator.location];
      if (slot && ![slot isEqual:@"–"]) label=slot;
      else {
        NSString *name=slot ? [label substringFromIndex:NSMaxRange(separator)] : label;
        __block NSUInteger end=0,characters=0;
        [name enumerateSubstringsInRange:NSMakeRange(0,name.length) options:NSStringEnumerationByComposedCharacterSequences
          usingBlock:^(NSString *text,NSRange range,NSRange enclosing,BOOL *stop) {
            (void)text; (void)enclosing; end=NSMaxRange(range); *stop=++characters==3;
          }];
        label=[name substringToIndex:end];
      }
    }
    b.title=label; b.frame=NSMakeRect(3+(i+1)*(width+3),2,width,24);
  }
  for (NSUInteger i=1;i<self.controls.count;i++) if(amcontract::controls[i].kind!=amcontract::ControlKind::popup)
    ((NSButton *)self.controls[i]).title=[NSString stringWithUTF8String:compact ? amcontract::controls[i].compact_title : amcontract::controls[i].title];
  x=minimal ? base.size.width-78 : 3; CGFloat y=minimal ? 2 : 28;
  for (NSUInteger i=1;i<self.controls.count;i++) {
    NSControl *c=self.controls[i];
    c.hidden=(i==amcontract::downmix && ![self.state[@"multichannel"] boolValue]) ||
      (minimal ? !amcontract::controls[i].minimal : (compact && amcontract::controls[i].compact_width==0));
    if (c.hidden) continue;
    CGFloat toolWidth=compact ? amcontract::controls[i].compact_width : amcontract::controls[i].width;
    if (!minimal && x+toolWidth>base.size.width-3) { x=3; y+=26; }
    c.frame=NSMakeRect(x,y,toolWidth,24); x+=toolWidth+3;
  }
  self.status.hidden=compact;
  self.status.frame=NSMakeRect(6,height-18,MAX(0,base.size.width-12),16);
  self.adjusting=NO;
}
- (void)rememberFocus {
  NSResponder *responder=self.window.firstResponder;
  NSRange selection=NSMakeRange(0,0); BOOL hasSelection=NO;
  if ([responder isKindOfClass:[NSTextView class]] && [(NSTextView *)responder isFieldEditor]) {
    NSTextView *editor=(NSTextView *)responder;
    selection=editor.selectedRange; hasSelection=YES;
    if ([editor.delegate isKindOfClass:[NSView class]]) responder=(NSResponder *)editor.delegate;
  }
  if (![responder isKindOfClass:[NSView class]]) return;
  NSView *view=(NSView *)responder;
  if (view==self || [view isDescendantOf:self] || ![view isDescendantOf:self.host]) return;
  self.returnFocus=view; self.returnSelection=selection; self.returnHasSelection=hasSelection;
}
- (void)focusBrowser {
  NSView *previous=self.returnFocus;
  if (previous && previous.window==self.window && !previous.hiddenOrHasHiddenAncestor &&
      [previous isDescendantOf:self.host] && [self.window makeFirstResponder:previous]) {
    if (self.returnHasSelection && [previous isKindOfClass:[NSControl class]]) {
      NSText *editor=[(NSControl *)previous currentEditor];
      if (editor && NSMaxRange(self.returnSelection)<=editor.string.length) editor.selectedRange=self.returnSelection;
    }
    return;
  }
  NSView *list=self.list;
  NSView *focus=[list isKindOfClass:[NSScrollView class]] ? [(NSScrollView *)list documentView] : list;
  if (focus) [self.window makeFirstResponder:focus];
}
- (void)pressed:(NSButton *)sender {
  [self rememberFocus]; // Accessibility actions need not generate mouse events.
  if (self.paused && ![sender.identifier isEqualToString:@"quit"]) return;
  enqueue(sender.identifier); [self focusBrowser];
}
- (void)picked:(NSPopUpButton *)sender {
  [self rememberFocus];
  if (self.paused) return;
  NSString *value=sender.selectedItem.representedObject;
  if (value) enqueue([NSString stringWithFormat:@"%@:%@",sender.identifier,value]);
  if (sender==self.targets && [value isEqual:@"custom"]) {
    NSString *target=[NSString stringWithFormat:@"%.1f",[self.state[@"target"] doubleValue]];
    for (NSMenuItem *item in sender.itemArray)
      if ([item.representedObject isEqual:target]) [sender selectItem:item];
  }
  [self focusBrowser];
}
- (void)fill:(NSPopUpButton *)popup values:(NSArray<NSDictionary *> *)values selected:(NSString *)selected {
  [popup removeAllItems];
  for (NSDictionary *v in values) {
    [popup addItemWithTitle:v[@"label"] ?: @""];
    popup.lastItem.representedObject=v[@"id"];
    if ([v[@"id"] isEqual:selected]) [popup selectItem:popup.lastItem];
  }
}
- (void)update:(NSDictionary *)state {
  if (![state isKindOfClass:[NSDictionary class]]) return;
  [self rememberFocus];
  NSDictionary *previous=self.state;
  self.state=state; self.paused=[state[@"paused"] boolValue];
  NSArray *macros=state[@"macros"];
  if (![previous[@"macros"] isEqual:macros]) {
    for (NSUInteger i=0;i<self.presets.count;i++) {
      NSButton *b=self.presets[i];
      if (i>=macros.count) { b.hidden=YES; continue; }
      b.identifier=[@"macro:" stringByAppendingString:macros[i][@"id"]];
      b.toolTip=macros[i][@"label"]; b.accessibilityLabel=b.toolTip;
    }
  }
  if (![previous[@"macros"] isEqual:macros] || [previous[@"multichannel"] boolValue]!=[state[@"multichannel"] boolValue]) [self reflow];
  for (NSUInteger i=0;i<macros.count;i++) {
    NSButton *b=self.presets[i]; b.enabled=!self.paused;
    b.state=[state[@"active"] isEqual:macros[i][@"id"]] ? NSControlStateValueOn : NSControlStateValueOff;
  }
  self.raw.state=[state[@"active"] isEqual:@"raw"] ? NSControlStateValueOn : NSControlStateValueOff;
  self.normalize.state=[state[@"normalize"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  self.downmix.state=[state[@"downmix"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
  if (![previous[@"target"] isEqual:state[@"target"]] || ![(previous[@"target_label"] ?: @"") isEqual:(state[@"target_label"] ?: @"")]) {
    NSString *target=[NSString stringWithFormat:@"%.1f",[state[@"target"] doubleValue]];
    NSMutableArray *targets=[NSMutableArray array];
    if (state[@"target_label"]) [targets addObject:@{@"id":target,@"label":state[@"target_label"]}];
    else {
      BOOL found=NO;
      for (double n:amcontract::target_options) {
        NSString *s=[NSString stringWithFormat:@"%.1f",n];
        [targets addObject:@{@"id":s,@"label":[NSString stringWithFormat:@"Norm %@ LUFS",s]}]; if ([s isEqual:target]) found=YES;
      }
      if (!found) [targets addObject:@{@"id":target,@"label":[NSString stringWithFormat:@"Norm %@ LUFS",target]}];
    }
    [targets addObject:@{@"id":@"custom",@"label":@"Custom…"}];
    [self fill:self.targets values:targets selected:target];
  }
  if (![previous[@"monitor"] isEqual:state[@"monitor"]]) {
    NSString *gain=[NSString stringWithFormat:@"%.1f",[state[@"monitor"] doubleValue]];
    NSMutableArray *gains=[NSMutableArray array];BOOL found=NO;
    for (double n:amcontract::monitor_options) {
      NSString *s=[NSString stringWithFormat:@"%.1f",n];
      [gains addObject:@{@"id":s,@"label":[NSString stringWithFormat:@"Monitor %@ dB",s]}]; if ([s isEqual:gain]) found=YES;
    }
    if (!found) [gains addObject:@{@"id":gain,@"label":[NSString stringWithFormat:@"Monitor %@ dB",gain]}];
    [self fill:self.monitor values:gains selected:gain];
  }
  for (NSControl *c in self.controls) c.enabled=!self.paused || [c.identifier isEqual:@"quit"];
  self.normalize.enabled=!self.paused; self.targets.enabled=!self.paused;
  self.status.stringValue=state[@"status"] ?: @""; self.status.toolTip=self.status.stringValue;
  NSView* channelAnchor=self.controls[amcontract::channels];
  if(channelAnchor.hiddenOrHasHiddenAncestor)channelAnchor=self.controls[amcontract::edit];
  [self.channelPanel update:state[@"channels"] anchor:channelAnchor paused:self.paused];
  [self.settingsPanel update:state[@"settings"] anchor:self.controls[amcontract::edit] paused:self.paused];
  [self.editorPanel update:state[@"editor"] anchor:self.controls[amcontract::edit] paused:self.paused];
  if([previous[@"channels"][@"open"] boolValue] && ![state[@"channels"][@"open"] boolValue] && self.window.isKeyWindow)[self focusBrowser];
}
- (void)restore {
  self.restoring=YES;[self.channelPanel detach];[self.settingsPanel detach];[self.editorPanel detach];
  if (self.mouseMonitor) { [NSEvent removeMonitor:self.mouseMonitor]; self.mouseMonitor=nil; }
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  NSView *list=self.list;
  if (list) {
    if (NSEqualRects(list.frame,self.appliedFrame)) list.frame=self.baseFrame;
    list.postsFrameChangedNotifications=self.wasPosting;
  }
  [self removeFromSuperview];
}
- (void)dealloc {
  if (self.mouseMonitor) [NSEvent removeMonitor:self.mouseMonitor];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
}
@end

static AMAuditionBar *bar;
static __weak id parentWindow;
extern "C" bool AMBarAttach(void *parent,void *listPointer) {
  @autoreleasepool {
    id host=(__bridge id)parent; id candidate=(__bridge id)listPointer;
    if (![candidate isKindOfClass:[NSView class]]) return false;
    NSView *list=candidate;
    if ([list enclosingScrollView]) list=[list enclosingScrollView];
    NSView *container=list.superview;
    if (!container || (![host isKindOfClass:[NSView class]] && ![host isKindOfClass:[NSWindow class]])) return false;
    if (bar && parentWindow==host && bar.list==list && bar.superview==container) return true;
    [bar restore]; bar=nil; events.clear();
    bar=[[AMAuditionBar alloc] initWithHost:container list:list]; parentWindow=host;
    return bar!=nil;
  }
}
extern "C" bool AMBarSetState(const char *text) {
  if (!bar || !text || std::strlen(text)>amcontract::max_json_bytes) return false;
  @autoreleasepool {
    NSData *data=[[NSString stringWithUTF8String:text] dataUsingEncoding:NSUTF8StringEncoding];
    id state=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (!amcontract::valid_bar_state(AMCocoaValue{state})) return false;
    [bar update:state]; return true;
  }
}
extern "C" const char *AMBarPoll() {
  static std::string result;
  result=events.empty() ? "" : events.front();
  if (!events.empty()) events.pop_front(); return result.c_str();
}
extern "C" void AMBarDetach() { [bar restore]; bar=nil; parentWindow=nil; events.clear(); }
// Geometry is useful for verifying resize/restore without relying on screenshots.
extern "C" const char *AMBarGeometry() {
  static std::string result;
  @autoreleasepool {
    if (!bar || !bar.list) { result="{}"; return result.c_str(); }
    NSRect b=bar.baseFrame,f=bar.list.frame,s=bar.frame;
    NSDictionary *v=@{@"attached":@(bar.superview==bar.list.superview),@"hidden":@(bar.hidden),
      @"width":@(s.size.width),@"height":@(s.size.height),@"base_height":@(b.size.height),@"list_height":@(f.size.height),
      @"downmix_visible":@(!bar.hidden && !bar.downmix.hidden),@"downmix":@(bar.downmix.state==NSControlStateValueOn),
      @"same_window":@(bar.window==bar.list.window),@"microphones_open":@(bar.channelPanel.popover.shown),@"settings_open":@(bar.settingsPanel.window.visible),@"editor_open":@(bar.editorPanel.window.visible),@"control_count":@(bar.controls.count+[bar.state[@"macros"] count])};
    NSData *d=[NSJSONSerialization dataWithJSONObject:v options:0 error:nil];
    result=[[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding].UTF8String; return result.c_str();
  }
}
