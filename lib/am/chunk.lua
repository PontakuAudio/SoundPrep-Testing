-- Read balanced RPP blocks; FX payloads can themselves contain nested blocks.
local M={}
function M.read_track(r,track)
  if r.SNM_CreateFastString and r.SNM_GetSetObjectState then
    local fs=r.SNM_CreateFastString('')
    local ok,value=pcall(function()
      assert(r.SNM_GetSetObjectState(track,fs,false,false),'Cannot read FX state')
      return r.SNM_GetFastString(fs)
    end)
    r.SNM_DeleteFastString(fs)
    if ok then return value end
  end
  local ok,chunk=r.GetTrackStateChunk(track,'',false)
  assert(ok,'Cannot read track state (large plugin state may need SWS FastString)')
  return chunk
end
function M.read_item(r,item)
  if r.SNM_CreateFastString and r.SNM_GetSetObjectState then
    local fs=r.SNM_CreateFastString('')
    local ok,value=pcall(function()
      assert(r.SNM_GetSetObjectState(item,fs,false,false),'Cannot read item state')
      return r.SNM_GetFastString(fs)
    end)
    r.SNM_DeleteFastString(fs)
    if ok then return value end
  end
  local ok,chunk=r.GetItemStateChunk(item,'',false);assert(ok,'Cannot read item state');return chunk
end
function M.write_item(r,item,chunk)
  if r.SNM_CreateFastString and r.SNM_GetSetObjectState then
    local fs=r.SNM_CreateFastString(chunk)
    local ok,result=pcall(r.SNM_GetSetObjectState,item,fs,true,false)
    r.SNM_DeleteFastString(fs)
    assert(ok and result,'Cannot write item FX state')
  else assert(r.SetItemStateChunk(item,chunk,false),'Cannot write item FX state')end
end
function M.block(text,tag)
  local depth,start,finish=0,nil,nil
  local pos=1
  for line,nl in (text..'\n'):gmatch('([^\n]*)(\n)') do
    local clean=line:gsub('\r$',''):match('^%s*(.-)%s*$')
    if not start and clean:match('^<'..tag..'[%s>]?') and clean:match('^<([%w_]+)')==tag then start=pos;depth=1
    elseif start then
      if clean:sub(1,1)=='<' then depth=depth+1 end
      if clean=='>' then depth=depth-1;if depth==0 then finish=pos+#line-1;break end end
    end
    pos=pos+#line+#nl
  end
  if start and not finish then error('Unbalanced '..tag..' chunk')end
  if start then return text:sub(start,finish),start,finish end
end
function M.chain_body(chain)
  assert(type(chain)=='string' and not chain:find('%z'),'Invalid FX chain')
  chain=chain:gsub('\r\n','\n')
  local tag=chain:match('^%s*<([%w_]+)')
  local block=(tag=='FXCHAIN' or tag=='TAKEFX') and M.block(chain,tag)
  if block then chain=block:match('^[^\n]*\n(.*)\n%s*>$') or '' end
  -- Validate that the body cannot escape the FXCHAIN/track it will be inserted into.
  local depth=0
  for line in (chain..'\n'):gmatch('([^\n]*)\n')do
    local c=line:match('^%s*(.-)%s*$')
    if c:sub(1,1)=='<' then depth=depth+1 elseif c=='>' then depth=depth-1 end
    assert(depth>=0,'FX chain has an unexpected closing delimiter')
  end
  assert(depth==0,'FX chain has an unclosed block')
  return chain
end
function M.replace(track,chain,tag)
  tag=tag or 'FXCHAIN';assert(tag=='FXCHAIN' or tag=='TAKEFX','Invalid FX block')
  local body=M.chain_body(chain)
  local replacement='<'..tag..'\n'..body..'\n>'
  local _,a,b=M.block(track,tag)
  if a then return track:sub(1,a-1)..replacement..track:sub(b+1) end
  local p=assert(track:match('()\n%s*>%s*$'),'Invalid track chunk')
  return track:sub(1,p)..replacement..'\n'..track:sub(p+1)
end
function M.fresh(chain, guid)
  local body=M.chain_body(chain):gsub('FXID {[^}]+}',function()return 'FXID '..guid()end)
    :gsub('SHOW %-?%d+','SHOW -1'):gsub('FLOATPOS [^\n]+','FLOATPOS 0 0 0 0')
  -- Minimal chains can omit SHOW. REAPER then opens a chain window while
  -- loading it, before TrackFX_Show/TakeFX_Show can close it again.
  if not ('\n'..body):match('\n%s*SHOW %-?%d+')then body='SHOW -1\n'..body end
  return body
end
function M.portable(chain)
  local lines={}
  for line in (M.chain_body(chain)..'\n'):gmatch('([^\n]*)\n')do
    local value=line
    if not line:match('^%s*FXID%s+{[^}]+}%s*$')then
      if line:match('^%s*SHOW %-?%d+%s*$')then value='SHOW -1'
      elseif line:match('^%s*FLOATPOS ')then value='FLOATPOS 0 0 0 0' end
      lines[#lines+1]=value
    end
  end
  return table.concat(lines,'\n'):gsub('\n+$','')..'\n'
end
function M.pdc_options(chain,replacement,replace)
  local lines,depth,original={},0,nil
  for line in (M.chain_body(chain)..'\n'):gmatch('([^\n]*)\n')do
    local c=line:match('^%s*(.-)%s*$')
    if depth==0 and c:match('^PDC_OPTIONS%s')then original=c
    else lines[#lines+1]=line end
    if c:sub(1,1)=='<'then depth=depth+1 elseif c=='>'then depth=depth-1 end
  end
  if not replace then return original end
  if replacement then table.insert(lines,1,replacement)end
  return table.concat(lines,'\n'):gsub('\n+$','')..'\n'
end
return M
