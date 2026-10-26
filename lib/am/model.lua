local U=require('am.util')
local J=require('am.json')
local M={VERSION=1,DEFAULT_TARGET_LUFS=-18,DEFAULT_TARGET_SONES=36}
function M.macro(id,name)
  return {id=id,name=name,fx_chain='chains/'..id..'.RfxChain',
    source_transform={reverse=false,pitch_semitones=0,rate=1,preserve_pitch=false},
    normalization={enabled=false,metric='lufs_m_max',target_lufs=M.DEFAULT_TARGET_LUFS,target_sones=M.DEFAULT_TARGET_SONES,reference_dbfs=-20,reference_spl_db=79,basis='source_raw',max_boost_db=18},
    output_gain_db=0,source_peak_guard={enabled=false,ceiling_dbtp=-1},
    export={tail_seconds=1,normalize_final=false,true_peak_limit=false,ceiling_dbtp=-1}}
end
function M.raw_settings()
  local raw=M.macro('raw','Raw')
  return {normalization=raw.normalization,source_peak_guard=raw.source_peak_guard}
end
function M.defaults()
  local heavy=M.macro('heavy','Heavy');heavy.source_transform.pitch_semitones=-4;heavy.source_transform.rate=.72
  local dark=M.macro('dark','Dark');dark.source_transform.pitch_semitones=-2
  local rev=M.macro('reverse','Reverse');rev.source_transform.reverse=true
  return {schema_version=1,raw=M.raw_settings(),macros=J.array{heavy,dark,rev},slots={['1']='heavy',['2']='dark',['3']='reverse'},
    settings={autoplay=true,loop=false,keep_fx_running=false,monitor_gain_db=-6,fade_ms=5,preview_fade_ms=0,preview_downmix=false,preview_downmix_mode='auto',
      python='',ffmpeg='',cache_directory='',poll_ms=20,analysis_timeout_seconds=180,insert_handles=true,prepare_drops=false,auto_render_drops=true}}
end
local function number(v,a,b,name)
  assert(U.finite(v) and v>=a and v<=b,name..' outside '..a..'..'..b)
end
local function boolean(v,name) assert(type(v)=='boolean',name..' must be boolean')end
local function normalization(n)
  assert(type(n)=='table' and (n.metric=='lufs_m_max' or n.metric=='zwicker_max' or n.metric=='zwicker_p95')and n.basis=='source_raw','Unsupported normalization mode')
  if n.target_sones==nil then n.target_sones=M.DEFAULT_TARGET_SONES end
  if n.reference_dbfs==nil then n.reference_dbfs=-20 end
  if n.reference_spl_db==nil then n.reference_spl_db=79 end
  boolean(n.enabled,'normalize');number(n.target_lufs,-60,0,'LUFS target');number(n.max_boost_db,0,24,'Max boost')
  number(n.target_sones,.01,256,'Sones target');number(n.reference_dbfs,-120,0,'Reference dBFS');number(n.reference_spl_db,0,140,'Reference SPL')
end
function M.validate(bank)
  assert(type(bank)=='table' and bank.schema_version==M.VERSION,'Unsupported bank schema')
  assert(type(bank.macros)=='table' and #bank.macros<=require('am.native_contract').bar.max_macros,'A bank supports up to nine macros')
  if bank.raw==nil then bank.raw=M.raw_settings()end
  local raw=bank.raw;assert(type(raw)=='table','Invalid Raw settings')
  local n=raw.normalization;local p=raw.source_peak_guard
  normalization(n)
  assert(type(p)=='table','Invalid Raw peak guard');boolean(p.enabled,'Raw peak guard');number(p.ceiling_dbtp,-12,0,'Raw peak ceiling')
  local ids={}
  for _,m in ipairs(bank.macros)do
    assert(type(m.id)=='string' and m.id~='raw' and m.id:match('^[a-z0-9_-]+$') and not ids[m.id],'Invalid/duplicate macro ID')
    ids[m.id]=true
    assert(type(m.name)=='string' and #m.name>0 and #m.name<=128,'Macro name required (max 128 bytes)')
    assert(U.safe_relative(m.fx_chain) and m.fx_chain:lower():match('%.rfxchain$'),'Chain must be a relative .RfxChain path')
    local t=m.source_transform;assert(type(t)=='table','Missing transform')
    boolean(t.reverse,'reverse');boolean(t.preserve_pitch,'preserve_pitch')
    number(t.pitch_semitones,-24,24,'Pitch');number(t.rate,.1,4,'Rate')
    normalization(m.normalization)
    number(m.output_gain_db,-60,12,'Output gain')
    local p=m.source_peak_guard;boolean(p.enabled,'source peak guard');number(p.ceiling_dbtp,-12,0,'Source peak ceiling')
    local e=m.export;number(e.tail_seconds,0,30,'Tail');boolean(e.normalize_final,'Export normalization');boolean(e.true_peak_limit,'Export limiter');number(e.ceiling_dbtp,-12,0,'Export ceiling')
  end
  assert(type(bank.slots)=='table','Missing slot mapping')
  for k,id in pairs(bank.slots)do assert(k:match('^[1-9]$') and ids[id],'Invalid shortcut mapping')end
  local s=bank.settings;assert(type(s)=='table','Missing settings')
  if s.cache_directory==nil then s.cache_directory='' end
  assert(type(s.cache_directory)=='string' and not s.cache_directory:find('[%z\r\n]') and
    (s.cache_directory=='' or s.cache_directory:match('^/') or s.cache_directory:match('^%a:[/\\]') or
      s.cache_directory:match('^\\\\[^\\]+\\[^\\]+')),'Cache folder must be an absolute path')
  -- Additive schema-1 migration: existing banks retain full processed handles.
  if s.insert_handles==nil then s.insert_handles=true end
  if s.prepare_drops==nil then s.prepare_drops=false end
  if s.auto_render_drops==nil then s.auto_render_drops=true end
  if s.preview_fade_ms==nil then s.preview_fade_ms=0 end
  if s.preview_downmix==nil then s.preview_downmix=false end
  if s.preview_downmix_mode==nil then s.preview_downmix_mode='auto' end
  if s.channel_selections==nil then s.channel_selections={} end
  require('am.channel_selection').validate(s.channel_selections)
  boolean(s.preview_downmix,'Preview downmix')
  assert(s.preview_downmix_mode=='auto' or s.preview_downmix_mode=='discrete' or s.preview_downmix_mode=='ambix','Invalid preview downmix mode')
  number(s.preview_fade_ms,0,50,'Preview fade')
  boolean(s.prepare_drops,'prepare_drops')
  boolean(s.auto_render_drops,'auto_render_drops')
  boolean(s.insert_handles,'insert_handles')
  boolean(s.autoplay,'autoplay');boolean(s.loop,'loop');boolean(s.keep_fx_running,'keep_fx_running')
  number(s.monitor_gain_db,-60,0,'Monitor gain');number(s.fade_ms,0,50,'Fade');number(s.poll_ms,10,200,'Poll')
  number(s.analysis_timeout_seconds,5,3600,'Analysis timeout')
  assert(type(s.python)=='string' and type(s.ffmpeg)=='string','Invalid worker paths')
  return bank
end
function M.find(bank,id)for i,m in ipairs(bank.macros)do if m.id==id then return m,i end end end
function M.effective(bank,id,reverse_override)
  local m=id and M.find(bank,id) or nil
  local out=U.copy(m or M.macro('raw','Raw'))
  if not m then
    out.fx_chain=nil;out.export.tail_seconds=0
    local raw=bank.raw or M.raw_settings()
    out.normalization=U.copy(raw.normalization);out.source_peak_guard=U.copy(raw.source_peak_guard)
  end
  if reverse_override~=nil then out.source_transform.reverse=reverse_override end
  return out
end
function M.editable(bank,id)return id=='raw' and M.effective(bank,nil) or M.find(bank,id)end
function M.load(path)
  local text,e=U.read(path);if not text then return nil,e end
  local ok,bank=pcall(function()return M.validate(J.decode(text))end)
  return ok and bank or nil,not ok and bank or nil
end
function M.save(path,bank)
  local ok,err=pcall(M.validate,bank);if not ok then return nil,err end
  return U.write(path,J.encode(bank))
end
return M
