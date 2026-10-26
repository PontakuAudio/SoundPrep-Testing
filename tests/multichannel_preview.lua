local Bank=require('am.bank');local U=require('am.util');local Model=require('am.model')
local definition=Model.defaults();definition.settings.keep_fx_running=true
local input={I_NCHAN=2};local raw={I_NCHAN=2};local a={I_NCHAN=2};local b={I_NCHAN=2}
local r={ValidatePtr=function()return true end,ValidatePtr2=function()return true end,
  GetMediaTrackInfo_Value=function(t,k)return t[k]or 0 end,
  SetMediaTrackInfo_Value=function(t,k,v)t[k]=v end,TrackFX_GetCount=function()return 0 end,
  GetTrackNumSends=function()return 0 end}
local bank=setmetatable({r=r,project={},input=input,raw=raw,macros={a=a,b=b},tracks={input,raw,a,b},
  definition=definition,channels=2,switches=0},Bank)
bank:activate('a',3)
assert(a.I_FXEN==1 and b.I_FXEN==1)
bank:set_channels(6,true)
assert(bank.fx_bypassed and a.I_FXEN==0 and b.I_FXEN==0,'Keep FX running overrode multichannel bypass')
assert(bank.chosen==a and a.B_MAINSEND==1 and bank.active=='a','Bypass changed the selected preset')
assert(a.D_VOL==U.gain(3+definition.settings.monitor_gain_db),'Bypass discarded Macro output gain')
bank:activate('b',-3)
assert(a.I_FXEN==0 and b.I_FXEN==0 and b.B_MAINSEND==1,'Switching a preset reenabled bypassed FX')
bank:set_channels(2,false)
assert(not bank.fx_bypassed and a.I_FXEN==1 and b.I_FXEN==1)
assert(bank.chosen==b and b.D_VOL==U.gain(-3+definition.settings.monitor_gain_db))
definition.settings.keep_fx_running=false;bank:activate('b',-3)
assert(a.I_FXEN==0 and b.I_FXEN==1)
bank:set_channels(2,true)
assert(b.I_FXEN==0,'Same-width policy change failed to bypass FX')
bank:set_channels(2,false);assert(b.I_FXEN==1 and a.I_FXEN==0)
