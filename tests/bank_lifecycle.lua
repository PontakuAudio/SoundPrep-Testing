local Bank=require('am.bank')
local function fixture()
  local input,raw,live={valid=true},{valid=true},{valid=true}
  local reads,deletes={},{ }
  local r={ValidatePtr=function()return true end,
    ValidatePtr2=function(_,t)return t.valid end,
    DeleteTrack=function(t)t.valid=false;deletes[#deletes+1]=t end,
    TrackFX_GetCount=function(t)reads[#reads+1]=t;return 0 end}
  local bank=setmetatable({r=r,project={},input=input,raw=raw,tracks={input,raw,live},
    macros={live=live},pdc_options={[live]='PDC_OPTIONS 3'},preserve={[live]=true}},Bank)
  return bank,live,reads,deletes
end

-- README: the bank owns only its temporary Preview tracks. A deleted track
-- must leave that ownership set even if REAPER later reuses the same pointer.
local bank,removed,reads,deletes=fixture()
bank:remove('live')
assert(#deletes==1 and deletes[1]==removed and not bank.macros.live)
assert(#bank.tracks==2,'Deleted Macro tracks remain in the periodic PDC scan')
assert(not bank.pdc_options[removed] and not bank.preserve[removed],
  'Deleted Macro tracks remain retained by auxiliary state')
removed.valid=true -- A fresh unrelated track at the same native address.
for _,track in ipairs(bank.tracks)do bank:live_pdc(track)end
for _,track in ipairs(reads)do assert(track~=removed,'PDC scan touched a reused unrelated track')end
bank:remove('missing');assert(#deletes==1,'Removing a missing Macro changed a live track')

-- Repeated create/delete operations must remain bounded by the current bank,
-- which supports at most nine Macros, rather than by the editing history.
for _=1,2000 do
  local track={valid=true};bank.tracks[#bank.tracks+1]=track;bank.macros.live=track
  bank.pdc_options[track]='PDC_OPTIONS 3';bank:remove('live')
end
assert(#bank.tracks==2 and next(bank.pdc_options)==nil)

-- An externally deleted Macro also needs to be forgotten without DeleteTrack.
bank,removed,reads,deletes=fixture();removed.valid=false;bank:remove('live')
assert(#deletes==0 and #bank.tracks==2 and not bank.pdc_options[removed])

-- A failed FX import during Macro creation must not leave a dead PDC key.
bank,removed=fixture()
local failed={valid=true}
bank.add_track=function(self)self.tracks[#self.tracks+1]=failed;return failed end
bank.load=function(self,t)self.pdc_options[t]='PDC_OPTIONS 2';error('fixture load failure')end
bank.definition={settings={monitor_gain_db=-6}}
bank.root='/fixture'
local ok,err=pcall(bank.add_macro,bank,{id='failed',name='Failed',fx_chain='failed.RfxChain',output_gain_db=0})
assert(not ok and tostring(err):find('fixture load failure',1,true))
assert(not failed.valid and not bank.macros.failed and not bank.pdc_options[failed])
assert(#bank.tracks==3 and bank.tracks[3]==removed and bank.pdc_options[removed]=='PDC_OPTIONS 3',
  'Failed creation damaged a surviving Macro')
