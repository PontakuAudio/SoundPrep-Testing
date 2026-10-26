#import "settings_layout.h"
@interface AMSettingsSlider : NSSlider
@property BOOL dragging;
@end
@implementation AMSettingsSlider
- (void)mouseDown:(NSEvent*)event {
  self.dragging=YES;[super mouseDown:event];self.dragging=NO;
  [self sendAction:self.action to:self.target];
}
@end
@interface AMSettingsPage : NSView
@end
@implementation AMSettingsPage
- (BOOL)isFlipped{return YES;}
@end
@interface AMSettingsPanel : NSObject <NSWindowDelegate,NSTextFieldDelegate>
@property(strong) NSPanel* window;
@property(strong) NSTabView* tabs;
@property(strong) NSMutableArray<NSControl*>* controls;
@property(strong) NSMutableDictionary<NSNumber*,NSTextField*>* numbers;
@property(strong) NSTextField *cache,*diagnostics,*notice;
@property(strong) NSButton *choose,*defaults,*render;
@property(strong) NSDictionary* state;
@property BOOL paused;
@property(strong) id keyboardMonitor;
@property void(*send)(NSString*);
- (instancetype)initWithSender:(void(*)(NSString*))sender;
- (void)update:(NSDictionary*)state anchor:(NSView*)anchor paused:(BOOL)paused;
- (void)detach;
- (BOOL)editShortcut:(NSEvent*)event;
@end
@implementation AMSettingsPanel
- (instancetype)initWithSender:(void(*)(NSString*))sender {
  if((self=[super init]))self.send=sender;return self;
}
- (NSTextField*)label:(NSString*)text parent:(NSView*)parent frame:(NSRect)frame {
  NSTextField* field=[NSTextField wrappingLabelWithString:text];field.frame=frame;
  field.font=[NSFont systemFontOfSize:12];[parent addSubview:field];return field;
}
- (NSButton*)button:(NSString*)title op:(NSString*)op parent:(NSView*)parent frame:(NSRect)frame {
  NSButton* button=[NSButton buttonWithTitle:title target:self action:@selector(action:)];
  button.identifier=op;button.bezelStyle=NSBezelStyleRounded;button.frame=frame;[parent addSubview:button];return button;
}
- (void)create:(NSView*)anchor {
  self.window=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,640,476)
    styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
  self.window.title=@"SoundPrep — App settings";self.window.releasedWhenClosed=NO;
  self.window.hidesOnDeactivate=NO;self.window.floatingPanel=NO;self.window.level=NSNormalWindowLevel;self.window.delegate=self;
  __weak AMSettingsPanel* weakSelf=self;
  self.keyboardMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event) {
    AMSettingsPanel* owner=weakSelf;
    if(owner.window.isKeyWindow && (!event.window || event.window==owner.window) && [owner editShortcut:event])return nil;
    return event;
  }];
  self.window.contentView=[[AMSettingsPage alloc]initWithFrame:NSMakeRect(0,0,640,476)];
  NSView* root=self.window.contentView;
  [self label:@"App settings" parent:root frame:NSMakeRect(20,12,600,24)].font=[NSFont boldSystemFontOfSize:16];
  self.tabs=[[NSTabView alloc]initWithFrame:NSMakeRect(14,46,612,366)];[root addSubview:self.tabs];
  for(const char* title:amsettings::pages) {
    NSTabViewItem* tab=[[NSTabViewItem alloc]initWithIdentifier:[NSString stringWithUTF8String:title]];
    tab.label=tab.identifier;tab.view=[[AMSettingsPage alloc]initWithFrame:NSMakeRect(0,0,584,326)];[self.tabs addTabViewItem:tab];
  }
  self.controls=[NSMutableArray array];self.numbers=[NSMutableDictionary dictionary];
  for(int i=0;i<amsettings::count;++i) {
    const auto& spec=amsettings::controls[i];NSView* page=self.tabs.tabViewItems[spec.page].view;
    NSString* label=[NSString stringWithUTF8String:spec.label];NSControl* control;
    if(spec.kind==amsettings::toggle) {
      NSButton* button=[NSButton checkboxWithTitle:label target:self action:@selector(changed:)];
      button.frame=NSMakeRect(14,spec.y,554,24);control=button;
    }else {
      [self label:label parent:page frame:NSMakeRect(14,spec.y,450,20)];
      AMSettingsSlider* slider=[[AMSettingsSlider alloc]initWithFrame:NSMakeRect(14,spec.y+24,456,24)];
      slider.minValue=spec.low;slider.maxValue=spec.high;slider.continuous=YES;slider.target=self;slider.action=@selector(changed:);control=slider;
      NSTextField* value=[[NSTextField alloc]initWithFrame:NSMakeRect(482,spec.y+24,80,24)];
      value.tag=i;value.target=self;value.action=@selector(numberChanged:);value.delegate=self;
      value.accessibilityLabel=label;self.numbers[@(i)]=value;[page addSubview:value];
    }
    control.tag=i;control.accessibilityLabel=label;[page addSubview:control];[self.controls addObject:control];
    NSTextField* help=[self label:[NSString stringWithUTF8String:spec.help] parent:page
      frame:NSMakeRect(18,spec.y+(spec.kind==amsettings::toggle?28:52),548,38)];
    help.textColor=NSColor.secondaryLabelColor;help.font=[NSFont systemFontOfSize:11];
  }
  self.render=[self button:@"Render selected drops" op:@"render_drops" parent:self.tabs.tabViewItems[1].view frame:NSMakeRect(14,266,190,28)];
  NSView* cachePage=self.tabs.tabViewItems[2].view;
  [self label:@"Analysis cache folder" parent:cachePage frame:NSMakeRect(14,12,548,24)];
  self.cache=[self label:@"" parent:cachePage frame:NSMakeRect(14,44,548,80)];self.cache.selectable=YES;
  self.choose=[self button:@"Choose folder…" op:@"cache_choose" parent:cachePage frame:NSMakeRect(14,138,154,28)];
  self.defaults=[self button:@"Use default" op:@"cache_default" parent:cachePage frame:NSMakeRect(180,138,138,28)];
  [self label:@"New analysis jobs use this folder. Running jobs finish in their original folder; existing files stay where they are. Rendered project media uses its own location."
    parent:cachePage frame:NSMakeRect(14,184,548,90)].textColor=NSColor.secondaryLabelColor;
  NSView* advanced=self.tabs.tabViewItems[3].view;
  self.diagnostics=[self label:@"" parent:advanced frame:NSMakeRect(14,98,548,42)];
  [self label:@"Source analysis runs in the native helper. No Python or FFmpeg setup is required.\n\nAssign the supplied 0–9 actions in Media Explorer for keyboard preset switching."
    parent:advanced frame:NSMakeRect(14,152,548,110)].textColor=NSColor.secondaryLabelColor;
  self.notice=[self label:@"" parent:root frame:NSMakeRect(20,422,492,44)];self.notice.font=[NSFont systemFontOfSize:11];
  [self button:@"Done" op:@"close" parent:root frame:NSMakeRect(530,426,90,28)].keyEquivalent=@"\033";
  [self.window setFrameAutosaveName:@"SoundPrepAppSettings"];
  NSRect frame=self.window.frame,screen=(anchor.window.screen?:NSScreen.mainScreen).visibleFrame;
  frame.origin.x=MAX(NSMinX(screen),MIN(NSMaxX(screen)-NSWidth(frame),NSMidX(anchor.window.frame)-NSWidth(frame)/2));
  frame.origin.y=MAX(NSMinY(screen),MIN(NSMaxY(screen)-NSHeight(frame),NSMidY(anchor.window.frame)-NSHeight(frame)/2));
  [self.window setFrame:frame display:NO];
}
- (void)event:(NSDictionary*)event {
  if(self.paused)return;
  NSData* data=[NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
  self.send([@"settings@" stringByAppendingString:[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]]);
}
- (void)changed:(NSControl*)sender {
  const auto& spec=amsettings::controls[sender.tag];BOOL numeric=spec.kind==amsettings::number;
  double value=std::round(sender.doubleValue*10)/10;
  if(numeric)self.numbers[@(sender.tag)].stringValue=[NSString stringWithFormat:@"%.1f",value];
  BOOL commit=!numeric || ![(AMSettingsSlider*)sender dragging];
  [self event:@{@"op":@"set",@"key":[NSString stringWithUTF8String:spec.key],@"value":numeric?@(value):@([(NSButton*)sender state]==NSControlStateValueOn),@"commit":@(commit)}];
}
- (void)numberChanged:(NSTextField*)field {
  const auto& spec=amsettings::controls[field.tag];
  NSScanner* scanner=[NSScanner scannerWithString:[field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
  scanner.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];double value;
  if(![scanner scanDouble:&value] || !scanner.isAtEnd || !std::isfinite(value) || value<spec.low || value>spec.high) {
    field.stringValue=[NSString stringWithFormat:@"%.1f",[self.state[@"values"][[NSString stringWithUTF8String:spec.key]] doubleValue]];
    self.notice.stringValue=[NSString stringWithFormat:@"Enter a number between %.0f and %.0f.",spec.low,spec.high];return;
  }
  if(value==[self.state[@"values"][[NSString stringWithUTF8String:spec.key]] doubleValue])return;
  field.doubleValue=value;[self event:@{@"op":@"set",@"key":[NSString stringWithUTF8String:spec.key],@"value":@(value)}];
}
- (void)controlTextDidEndEditing:(NSNotification*)note{[self numberChanged:note.object];}
- (BOOL)windowShouldClose:(NSWindow*)sender {
  (void)sender;[self.window makeFirstResponder:nil];self.send(@"settings:close");[self.window orderOut:nil];return NO;
}
- (void)action:(NSButton*)sender {
  if([sender.identifier isEqual:@"close"]){[self windowShouldClose:self.window];return;}
  [self.window makeFirstResponder:nil];[self event:@{@"op":sender.identifier}];
}
- (void)update:(NSDictionary*)state anchor:(NSView*)anchor paused:(BOOL)paused {
  BOOL wasOpen=[self.state[@"open"] boolValue];BOOL focus=![self.state[@"focus"] isEqual:state[@"focus"]];
  self.state=state;self.paused=paused;
  if(![state[@"open"] boolValue]){[self.window orderOut:nil];return;}
  if(!self.window && anchor.window)[self create:anchor];if(!self.window)return;
  for(int i=0;i<amsettings::count;++i) {
    const auto& spec=amsettings::controls[i];NSControl* control=self.controls[i];control.enabled=!paused;
    NSNumber* value=state[@"values"][[NSString stringWithUTF8String:spec.key]];
    if(spec.kind==amsettings::toggle)[(NSButton*)control setState:value.boolValue?NSControlStateValueOn:NSControlStateValueOff];
    else {
      NSTextField* field=self.numbers[@(i)];field.enabled=!paused;
      if(!field.currentEditor && ![(AMSettingsSlider*)control dragging]){control.doubleValue=value.doubleValue;field.stringValue=[NSString stringWithFormat:@"%.1f",value.doubleValue];}
    }
  }
  self.cache.stringValue=state[@"cache_path"];self.cache.toolTip=self.cache.stringValue;
  self.choose.enabled=!paused && [state[@"cache_available"] boolValue];self.defaults.enabled=self.choose.enabled && ![state[@"cache_default"] boolValue];
  self.render.enabled=!paused;self.diagnostics.stringValue=state[@"diagnostics"];
  self.notice.stringValue=paused?@"Paused — return to the attached project to change settings.":state[@"notice"];
  self.notice.toolTip=self.notice.stringValue;
  if(!wasOpen || focus){
    if(anchor.window && self.window.parentWindow!=anchor.window)[anchor.window addChildWindow:self.window ordered:NSWindowAbove];
    [self.window makeKeyAndOrderFront:nil];
    if(!wasOpen)[self.window makeFirstResponder:self.tabs];
  }
}
- (BOOL)editShortcut:(NSEvent*)event {
  NSResponder* responder=self.window.firstResponder;
  NSTextView* editor=[responder isKindOfClass:NSTextView.class]?(NSTextView*)responder:nil;
  if(editor.hasMarkedText)return NO;
  NSEventModifierFlags flags=event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if(event.keyCode==53 && !(flags & (NSEventModifierFlagCommand|NSEventModifierFlagControl|NSEventModifierFlagOption))) {
    [self windowShouldClose:self.window];return YES;
  }
  if(!(flags & NSEventModifierFlagCommand) || (flags & (NSEventModifierFlagControl|NSEventModifierFlagOption)))return NO;
  NSString* key=event.charactersIgnoringModifiers.lowercaseString;
  if([key isEqual:@"w"]){[self windowShouldClose:self.window];return YES;}
  if(!editor)return NO;
  if([key isEqual:@"a"])[editor selectAll:nil];
  else if([key isEqual:@"c"])[editor copy:nil];
  else if([key isEqual:@"x"])[editor cut:nil];
  else if([key isEqual:@"v"])[editor paste:nil];
  else if([key isEqual:@"z"]){if(flags & NSEventModifierFlagShift)[editor.undoManager redo];else [editor.undoManager undo];}
  else return NO;
  return YES;
}
- (void)detach {
  if(self.keyboardMonitor){[NSEvent removeMonitor:self.keyboardMonitor];self.keyboardMonitor=nil;}
  [self.window.parentWindow removeChildWindow:self.window];self.window.delegate=nil;
  [self.window close];self.window=nil;self.state=nil;
}
@end
