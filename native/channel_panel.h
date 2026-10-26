// Native microphone buttons anchored to the Media Explorer bar.
@interface AMChannelContent : NSView
@end
@implementation AMChannelContent
- (BOOL)isFlipped{return YES;}
@end
@interface AMChannelPanel : NSViewController <NSPopoverDelegate>
@property(strong) NSPopover* popover;
@property(strong) NSTextField *file,*summary,*page,*notice;
@property(strong) NSArray<NSButton*>* microphones;
@property(strong) NSMutableDictionary<NSString*,NSButton*>* actions;
@property(strong) NSDictionary* state;
@property BOOL suppressClose,paused;
@property void(*send)(NSString*);
- (instancetype)initWithSender:(void(*)(NSString*))sender;
- (void)update:(NSDictionary*)state anchor:(NSView*)anchor paused:(BOOL)paused;
- (void)detach;
@end
@implementation AMChannelPanel
- (NSString*)shortName:(NSString*)name forButton:(NSButton*)button {
  NSDictionary* attributes=@{NSFontAttributeName:button.font};CGFloat width=NSWidth(button.bounds)-18;
  if([name sizeWithAttributes:attributes].width<=width)return name;
  NSString* prefix=name;
  while(prefix.length && [[prefix stringByAppendingString:@"…"] sizeWithAttributes:attributes].width>width)
    prefix=[prefix substringToIndex:[prefix rangeOfComposedCharacterSequenceAtIndex:prefix.length-1].location];
  return [prefix stringByAppendingString:@"…"];
}
- (NSTextField*)label:(NSRect)frame {
  NSTextField* label=[NSTextField labelWithString:@""];label.frame=frame;label.font=[NSFont systemFontOfSize:11];
  label.lineBreakMode=NSLineBreakByTruncatingTail;[self.view addSubview:label];return label;
}
- (NSButton*)button:(NSString*)title command:(NSString*)command frame:(NSRect)frame {
  NSButton* b=[NSButton buttonWithTitle:title target:self action:@selector(pressed:)];b.frame=frame;b.identifier=command;
  b.bezelStyle=NSBezelStyleRounded;b.font=[NSFont systemFontOfSize:11];b.cell.lineBreakMode=NSLineBreakByTruncatingTail;
  [self.view addSubview:b];return b;
}
- (instancetype)initWithSender:(void(*)(NSString*))sender {
  if(!(self=[super init]))return nil;self.send=sender;self.actions=[NSMutableDictionary dictionary];
  self.view=[[AMChannelContent alloc]initWithFrame:NSMakeRect(0,0,520,314)];
  self.file=[self label:NSMakeRect(12,10,496,18)];self.summary=[self label:NSMakeRect(12,32,496,18)];
  NSMutableArray* buttons=[NSMutableArray array];
  for(int i=0;i<8;++i) {
    NSButton* b=[self button:@"" command:@"toggle" frame:NSMakeRect(12+(i%4)*125,58+(i/4)*54,121,48)];
    b.bezelStyle=NSBezelStyleRegularSquare;b.cell.wraps=YES;b.buttonType=NSButtonTypePushOnPushOff;[buttons addObject:b];
  }
  self.microphones=buttons;
  self.actions[@"previous"]=[self button:@"‹ Previous 8" command:@"previous" frame:NSMakeRect(12,172,112,26)];
  self.page=[self label:NSMakeRect(132,177,252,18)];self.page.alignment=NSTextAlignmentCenter;
  self.actions[@"next"]=[self button:@"Next 8 ›" command:@"next" frame:NSMakeRect(396,172,112,26)];
  for(NSArray* item in @[@[@"all",@"All channels"],@[@"downmix",@"Downmix all"],@[@"swap",@"Swap L / R"],@[@"close",@"Done"]]) {
    NSUInteger i=self.actions.count-2;
    self.actions[item[0]]=[self button:item[1] command:item[0] frame:NSMakeRect(12+i*125,206,121,26)];
  }
  self.actions[@"play"]=[self button:@"Play" command:@"play" frame:NSMakeRect(12,242,96,26)];
  self.actions[@"replay"]=[self button:@"Replay" command:@"replay" frame:NSMakeRect(116,242,96,26)];
  self.notice=[self label:NSMakeRect(12,280,496,20)];
  self.popover=[NSPopover new];self.popover.contentViewController=self;self.popover.behavior=NSPopoverBehaviorTransient;
  self.popover.animates=NO;self.popover.delegate=self;return self;
}
- (void)pressed:(NSButton*)sender {
  if([sender.identifier isEqual:@"close"]){[self.popover performClose:nil];return;}
  if(self.paused || ![self.state[@"enabled"] boolValue])return;
  NSMutableDictionary* event=[@{@"op":sender.identifier,@"source":self.state[@"source"]}mutableCopy];
  if([sender.identifier isEqual:@"toggle"])event[@"channel"]=@(sender.tag);
  NSData* bytes=[NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
  self.send([@"channels@" stringByAppendingString:[[NSString alloc]initWithData:bytes encoding:NSUTF8StringEncoding]]);
}
- (void)popoverDidClose:(NSNotification*)note{(void)note;if(!self.suppressClose)self.send(@"channels:close");}
- (void)update:(NSDictionary*)state anchor:(NSView*)anchor paused:(BOOL)paused {
  self.state=state;self.paused=paused;
  if(![state[@"open"] boolValue] || paused || !anchor.window || anchor.hiddenOrHasHiddenAncestor) {
    self.suppressClose=YES;[self.popover close];self.suppressClose=NO;return;
  }
  BOOL enabled=[state[@"enabled"] boolValue];
  self.file.stringValue=state[@"file"];self.file.toolTip=self.file.stringValue;
  self.summary.stringValue=state[@"summary"];self.summary.toolTip=self.summary.stringValue;
  self.page.stringValue=state[@"page"];self.notice.stringValue=[state[@"notice"] length]?state[@"notice"]:@"Click microphones to add or remove them. Changes apply immediately.";
  self.notice.toolTip=self.notice.stringValue;
  NSArray* items=state[@"items"];
  for(NSUInteger i=0;i<self.microphones.count;++i) {
    NSButton* b=self.microphones[i];b.hidden=i>=items.count;if(b.hidden)continue;
    NSDictionary* item=items[i];b.tag=[item[@"channel"] integerValue];NSString* name=item[@"name"];
    NSString* number=[NSString stringWithFormat:@"ch %ld",(long)b.tag];
    b.title=name.length?[NSString stringWithFormat:@"%@\n%@",[self shortName:name forButton:b],number]:[NSString stringWithFormat:@"%ld",(long)b.tag];
    b.toolTip=name.length?[NSString stringWithFormat:@"%@ — %@",number,name]:number;b.accessibilityLabel=b.toolTip;
    b.state=[item[@"selected"] boolValue]?NSControlStateValueOn:NSControlStateValueOff;b.enabled=enabled;
  }
  for(NSString* key in self.actions)self.actions[key].enabled=enabled || [key isEqual:@"close"];
  self.actions[@"previous"].enabled=enabled && [state[@"previous"] boolValue];self.actions[@"next"].enabled=enabled && [state[@"next"] boolValue];
  self.actions[@"swap"].enabled=enabled && [state[@"can_swap"] boolValue];self.actions[@"downmix"].enabled=enabled && [state[@"can_downmix"] boolValue];
  for(NSString* key in @[@"all",@"downmix"]){NSButton* b=self.actions[key];b.buttonType=NSButtonTypePushOnPushOff;b.state=[state[key] boolValue]?NSControlStateValueOn:NSControlStateValueOff;}
  self.actions[@"play"].title=[state[@"playing"] boolValue]?@"Stop":@"Play";
  if(!self.popover.shown)[self.popover showRelativeToRect:anchor.bounds ofView:anchor preferredEdge:NSMaxYEdge];
}
- (void)detach{self.suppressClose=YES;[self.popover close];self.popover.contentViewController=nil;}
@end
