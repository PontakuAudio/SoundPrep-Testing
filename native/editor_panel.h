#import "editor_layout.h"
// Reuse the Settings panel's native text shortcuts, window lifetime and widgets.
@interface AMEditorPanel : AMSettingsPanel
@property(strong) NSView* presetStrip;
@property(strong) NSMutableArray<NSButton*>* presets;
@property CGFloat presetOffset;
@property(strong) NSTextField *source,*saved,*measurement;
@property(strong) NSMutableArray<NSButton*>* actions;
@property(strong) NSButton *save,*revert,*fx,*play,*replay,*ab;
@property BOOL updating;
@end
@implementation AMEditorPanel
- (void)create:(NSView*)anchor {
  self.window=[[NSPanel alloc]initWithContentRect:NSMakeRect(0,0,700,738) styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskResizable backing:NSBackingStoreBuffered defer:NO];
  self.window.title=@"SoundPrep — Presets & Tools";self.window.releasedWhenClosed=NO;self.window.hidesOnDeactivate=NO;
  self.window.floatingPanel=NO;self.window.level=NSNormalWindowLevel;self.window.delegate=self;
  __weak AMEditorPanel* weakSelf=self;
  self.keyboardMonitor=[NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown handler:^NSEvent*(NSEvent* event){
    AMEditorPanel* owner=weakSelf;if(owner.window.isKeyWindow && (!event.window || event.window==owner.window) && [owner editShortcut:event])return nil;return event;
  }];
  NSView* root=[[AMSettingsPage alloc]initWithFrame:NSMakeRect(0,0,700,700)];
  NSScrollView* scroll=[[NSScrollView alloc]initWithFrame:NSMakeRect(0,0,700,738)];scroll.hasVerticalScroller=YES;scroll.autohidesScrollers=YES;scroll.documentView=root;
  self.window.contentView=scroll;self.window.contentMinSize=NSMakeSize(700,380);self.window.contentMaxSize=NSMakeSize(700,900);
  self.presetStrip=[[AMSettingsPage alloc]initWithFrame:NSMakeRect(20,14,660,30)];[root addSubview:self.presetStrip];
  self.presets=[NSMutableArray array];self.presetOffset=0;
  self.save=[self button:@"Save preset" op:@"save" parent:root frame:NSMakeRect(20,14,110,30)];
  self.revert=[self button:@"Revert saved" op:@"revert" parent:root frame:NSMakeRect(136,14,120,30)];
  self.fx=[self button:@"Edit FX…" op:@"fx" parent:root frame:NSMakeRect(262,14,96,30)];
  self.saved=[self label:@"" parent:root frame:NSMakeRect(20,52,660,22)];
  self.source=[self label:@"" parent:root frame:NSMakeRect(20,78,660,24)];self.source.lineBreakMode=NSLineBreakByTruncatingMiddle;
  self.play=[self button:@"Play" op:@"play" parent:root frame:NSMakeRect(20,108,90,28)];
  self.replay=[self button:@"Replay" op:@"replay" parent:root frame:NSMakeRect(116,108,90,28)];
  self.ab=[self button:@"Raw / Processed" op:@"ab" parent:root frame:NSMakeRect(212,108,150,28)];
  [self button:@"Focus ME" op:@"focus" parent:root frame:NSMakeRect(368,108,100,28)];
  self.tabs=[[NSTabView alloc]initWithFrame:NSMakeRect(14,148,672,486)];[root addSubview:self.tabs];
  for(const char* name:ameditor::pages){NSTabViewItem* tab=[[NSTabViewItem alloc]initWithIdentifier:[NSString stringWithUTF8String:name]];
    tab.label=tab.identifier;tab.view=[[AMSettingsPage alloc]initWithFrame:NSMakeRect(0,0,644,446)];[self.tabs addTabViewItem:tab];}
  self.controls=[NSMutableArray array];self.numbers=[NSMutableDictionary dictionary];self.actions=[NSMutableArray array];
  for(int i=0;i<ameditor::count;++i){
    const auto& s=ameditor::controls[i];NSView* page=self.tabs.tabViewItems[s.page].view;NSControl* control;
    NSString* label=[NSString stringWithUTF8String:s.label];
    if(s.kind==ameditor::toggle){control=[NSButton checkboxWithTitle:label target:self action:@selector(changed:)];control.frame=NSMakeRect(14,s.y,610,26);}
    else {
      [self label:label parent:page frame:NSMakeRect(14,s.y+4,204,28)];
      if(s.kind==ameditor::number){
        AMSettingsSlider* slider=[[AMSettingsSlider alloc]initWithFrame:NSMakeRect(222,s.y,282,26)];slider.minValue=s.low;slider.maxValue=s.high;
        slider.continuous=YES;slider.target=self;slider.action=@selector(changed:);control=slider;
        NSTextField* value=[[NSTextField alloc]initWithFrame:NSMakeRect(514,s.y,108,26)];value.tag=i;value.delegate=self;
        value.target=self;value.action=@selector(fieldChanged:);value.accessibilityLabel=label;self.numbers[@(i)]=value;[page addSubview:value];
      }else if(s.kind==ameditor::choice){
        NSPopUpButton* popup=[[NSPopUpButton alloc]initWithFrame:NSMakeRect(222,s.y,400,28) pullsDown:NO];
        for(const char* meter:ameditor::meters)[popup addItemWithTitle:[NSString stringWithUTF8String:meter]];
        popup.target=self;popup.action=@selector(changed:);control=popup;
      }else {
        NSTextField* field=[[NSTextField alloc]initWithFrame:NSMakeRect(222,s.y,400,26)];field.delegate=self;field.target=self;field.action=@selector(fieldChanged:);control=field;
      }
    }
    control.tag=i;control.accessibilityLabel=label;[page addSubview:control];[self.controls addObject:control];
  }
  for(const auto& s:ameditor::actions){NSButton* button=[self button:[NSString stringWithUTF8String:s.title] op:[NSString stringWithUTF8String:s.op]
    parent:self.tabs.tabViewItems[s.page].view frame:NSMakeRect(s.x,s.y,s.w,30)];[self.actions addObject:button];}
  self.measurement=[self label:@"" parent:self.tabs.tabViewItems[4].view frame:NSMakeRect(14,12,608,100)];self.measurement.selectable=YES;
  const int helpY[]={294,404,208,312,340};
  for(int i=0;i<5;++i){NSTextField* help=[self label:[NSString stringWithUTF8String:ameditor::help[i]] parent:self.tabs.tabViewItems[i].view frame:NSMakeRect(14,helpY[i],608,i==1?42:104)];help.font=[NSFont systemFontOfSize:11];help.textColor=NSColor.secondaryLabelColor;help.toolTip=help.stringValue;}
  self.notice=[self label:@"" parent:root frame:NSMakeRect(20,644,554,46)];self.notice.font=[NSFont systemFontOfSize:11];
  [self button:@"Done" op:@"close" parent:root frame:NSMakeRect(590,650,90,28)];
  [self.window setFrameAutosaveName:@"SoundPrepPresetEditor"];
  NSRect frame=self.window.frame,screen=(anchor.window.screen?:NSScreen.mainScreen).visibleFrame;
  frame.size.height=MIN(frame.size.height,NSHeight(screen));
  frame.origin.x=MAX(NSMinX(screen),MIN(NSMaxX(screen)-NSWidth(frame),NSMidX(anchor.window.frame)-NSWidth(frame)/2));
  frame.origin.y=MAX(NSMinY(screen),MIN(NSMaxY(screen)-NSHeight(frame),NSMidY(anchor.window.frame)-NSHeight(frame)/2));[self.window setFrame:frame display:NO];
}
- (void)event:(NSDictionary*)event {
  if(self.paused || self.updating)return;
  NSMutableDictionary* payload=[event mutableCopy];payload[@"id"]=self.state[@"id"];
  NSData* data=[NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
  self.send([@"editor@" stringByAppendingString:[[NSString alloc]initWithData:data encoding:NSUTF8StringEncoding]]);
}
- (void)changed:(NSControl*)sender {
  const auto& s=ameditor::controls[sender.tag];id value;
  if(s.kind==ameditor::toggle)value=@([(NSButton*)sender state]==NSControlStateValueOn);
  else if(s.kind==ameditor::choice)value=[NSString stringWithUTF8String:ameditor::metrics[[(NSPopUpButton*)sender indexOfSelectedItem]]];
  else {double scale=!strcmp(s.key,"slot")?1:100;double n=std::round(sender.doubleValue*scale)/scale;value=@(n);self.numbers[@(sender.tag)].stringValue=[NSString stringWithFormat:!strcmp(s.key,"slot")?@"%.0f":@"%.2f",n];}
  [self event:@{@"op":@"set",@"key":[NSString stringWithUTF8String:s.key],@"value":value}];
}
- (void)fieldChanged:(NSTextField*)field {
  if(self.updating)return;const auto& s=ameditor::controls[field.tag];NSString* key=[NSString stringWithUTF8String:s.key];id value=field.stringValue;
  if(s.kind==ameditor::number){
    NSScanner* scanner=[NSScanner scannerWithString:[field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]];
    scanner.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];double n;
    if(![scanner scanDouble:&n] || !scanner.isAtEnd || !std::isfinite(n) || n<s.low || n>s.high || (!strcmp(s.key,"slot") && std::floor(n)!=n)){
      field.stringValue=[NSString stringWithFormat:!strcmp(s.key,"slot")?@"%.0f":@"%.2f",[self.state[@"values"][key] doubleValue]];
      self.notice.stringValue=[NSString stringWithFormat:@"Enter %@ between %g and %g.",!strcmp(s.key,"slot")?@"an integer":@"a number",s.low,s.high];return;
    }value=@(n);
  }
  if(![value isEqual:self.state[@"values"][key]])[self event:@{@"op":@"set",@"key":key,@"value":value}];
}
- (void)controlTextDidEndEditing:(NSNotification*)note{[self fieldChanged:note.object];}
- (void)layoutPresets {
  NSArray* choices=self.state[@"presets"];
  while(self.presets.count>choices.count){[self.presets.lastObject removeFromSuperview];[self.presets removeLastObject];}
  while(self.presets.count<choices.count){
    NSButton* b=[NSButton buttonWithTitle:@"" target:self action:@selector(selected:)];
    b.bezelStyle=NSBezelStyleRounded;[b setButtonType:NSButtonTypePushOnPushOff];b.lineBreakMode=NSLineBreakByTruncatingTail;
    [self.presets addObject:b];[self.presetStrip addSubview:b];
  }
  ameditor::PresetLayout layout;
  for(NSUInteger i=0;i<choices.count;++i){
    NSDictionary* p=choices[i];NSButton* b=self.presets[i];b.title=p[@"label"];b.identifier=p[@"id"];b.toolTip=b.title;b.accessibilityLabel=b.title;
    int width=static_cast<int>(std::ceil([b.title sizeWithAttributes:@{NSFontAttributeName:b.font}].width));
    auto r=layout.add(width);b.frame=NSMakeRect(r.x,r.y,r.w,r.h);
  }
  CGFloat offset=layout.height();NSView* root=self.presetStrip.superview;
  for(NSView* child in root.subviews)if(child!=self.presetStrip){NSRect frame=child.frame;frame.origin.y+=offset-self.presetOffset;child.frame=frame;}
  [self.presetStrip setFrameSize:NSMakeSize(660,offset-8)];[root setFrameSize:NSMakeSize(700,700+offset)];self.presetOffset=offset;
}
- (void)selected:(NSButton*)sender {
  NSString* id=sender.identifier;[self.window makeFirstResponder:sender];
  for(NSButton* b in self.presets)b.state=[b.identifier isEqual:self.state[@"id"]]?NSControlStateValueOn:NSControlStateValueOff;
  [self event:@{@"op":@"select",@"value":id}];
}
- (BOOL)windowShouldClose:(NSWindow*)sender {
  (void)sender;[self.window makeFirstResponder:nil];self.send(@"editor:close");[self.window orderOut:nil];return NO;
}
- (void)action:(NSButton*)sender {
  if([sender.identifier isEqual:@"close"]){[self windowShouldClose:self.window];return;}
  [self.window makeFirstResponder:self.tabs];[self event:@{@"op":sender.identifier}];
}
- (void)update:(NSDictionary*)state anchor:(NSView*)anchor paused:(BOOL)paused {
  BOOL wasOpen=[self.state[@"open"] boolValue],focus=![self.state[@"focus"] isEqual:state[@"focus"]],changed=![self.state[@"id"] isEqual:state[@"id"]];
  self.updating=YES;if(changed)[self.window endEditingFor:nil];NSDictionary* previous=self.state;self.state=state;self.paused=paused;
  if(![state[@"open"] boolValue]){[self.window orderOut:nil];self.updating=NO;return;}
  if(!self.window && anchor.window)[self create:anchor];if(!self.window){self.updating=NO;return;}
  BOOL raw=[state[@"id"] isEqual:@"raw"],zwicker=![state[@"values"][@"metric"] isEqual:@"lufs_m_max"];
  if(!self.presets.count || ![previous[@"presets"] isEqual:state[@"presets"]])[self layoutPresets];
  for(NSButton* b in self.presets){b.state=[b.identifier isEqual:state[@"id"]]?NSControlStateValueOn:NSControlStateValueOff;b.enabled=!paused;}
  self.save.enabled=!paused;self.revert.enabled=!paused;self.fx.enabled=!paused && !raw;
  self.play.enabled=!paused;self.replay.enabled=!paused;self.ab.enabled=!paused;self.play.title=[state[@"playing"] boolValue]?@"Stop":@"Play";
  self.saved.stringValue=[state[@"dirty"] boolValue]?@"Unsaved changes — auditioning live":@"Saved";
  self.source.stringValue=state[@"source"];self.source.toolTip=self.source.stringValue;
  for(int i=0;i<ameditor::count;++i){const auto& s=ameditor::controls[i];NSControl* c=self.controls[i];BOOL enabled=!paused && ameditor::enabled(s,raw,zwicker);c.enabled=enabled;id value=state[@"values"][[NSString stringWithUTF8String:s.key]];
    if(s.kind==ameditor::toggle)[(NSButton*)c setState:[value boolValue]?NSControlStateValueOn:NSControlStateValueOff];
    else if(s.kind==ameditor::choice){for(int k=0;k<3;++k)if([value isEqual:[NSString stringWithUTF8String:ameditor::metrics[k]]])[(NSPopUpButton*)c selectItemAtIndex:k];}
    else if(s.kind==ameditor::text){if(!c.currentEditor)c.stringValue=value;}
    else {NSTextField* f=self.numbers[@(i)];f.enabled=enabled;if(!f.currentEditor && ![(AMSettingsSlider*)c dragging]){c.doubleValue=[value doubleValue];f.stringValue=[NSString stringWithFormat:!strcmp(s.key,"slot")?@"%.0f":@"%.2f",[value doubleValue]];}}
  }
  int i=0;for(const auto& s:ameditor::actions){NSButton* b=self.actions[i++];b.enabled=!paused && (!s.macroOnly || !raw);
    if(!strcmp(s.op,"new") || !strcmp(s.op,"duplicate"))b.enabled=b.enabled && [state[@"presets"] count]<10;
    if(!strcmp(s.op,"confirm_delete") || !strcmp(s.op,"cancel_delete"))b.hidden=![state[@"deleting"] boolValue];}
  self.measurement.stringValue=state[@"measurement"];self.measurement.toolTip=self.measurement.stringValue;
  self.notice.stringValue=paused?@"Paused — return to the attached project to edit.":state[@"notice"];self.notice.toolTip=self.notice.stringValue;
  if(!wasOpen || focus){if([state[@"page"] integerValue]>=0)[self.tabs selectTabViewItemAtIndex:[state[@"page"] integerValue]];
    if(anchor.window && self.window.parentWindow!=anchor.window)[anchor.window addChildWindow:self.window ordered:NSWindowAbove];
    [self.window makeKeyAndOrderFront:nil];[self.window makeFirstResponder:self.tabs];}
  self.updating=NO;
}
@end
