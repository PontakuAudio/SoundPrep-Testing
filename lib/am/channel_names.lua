-- Read iXML track names without decoding audio or changing the recording.
-- Keep TRACK records intact: flattened metadata keys can lose empty NAMEs.
local M={}
local MAX_XML,MAX_CHUNKS=1024*1024,4096
local function integer(text,limit)
  local n=type(text)=='string' and tonumber(text:match('^%s*(%d+)%s*$'))
  return n and n>=1 and n<=limit and n%1==0 and n or nil
end
local entities={amp='&',lt='<',gt='>',quot='"',apos="'"}
local function decode(text)
  local invalid=false
  text=text:gsub('&([^;]*);',function(entity)
    if entities[entity]then return entities[entity]end
    local hex=entity:match('^#x(%x+)$');local dec=entity:match('^#(%d+)$')
    local code=hex and tonumber(hex,16)or dec and tonumber(dec)
    if code and (code==9 or code==10 or code==13 or code>=32 and code<=0x10ffff and not(code>=0xd800 and code<=0xdfff))then return utf8.char(code)end
    invalid=true;return ''
  end)
  if invalid then return end
  return text
end
local function clean(text)
  if not text or not utf8.len(text)then return end
  text=text:gsub('[%z\1-\31\127]',' '):gsub('%s+',' '):match('^%s*(.-)%s*$')
  if text~=''then return text end
end
function M.parse(xml,channels)
  if type(xml)~='string' or #xml>MAX_XML then return {}end
  local stack,tracks={},{};local current,field;local pos,nodes,root_seen=1,0,false
  local function append(text,literal)
    if field then
      local value=literal and text or decode(text)
      if not value then current.invalid=true else current[field]=current[field]..value end
    elseif text:find('%S')and #stack==0 then return false end
    return true
  end
  xml=xml:gsub('^\239\187\191',''):gsub('%z+$','')
  while pos<=#xml do
    local at=xml:find('<',pos,true)
    if not at then if not append(xml:sub(pos))then return {}end;break end
    if not append(xml:sub(pos,at-1))then return {}end
    local stop
    if xml:sub(at,at+3)=='<!--'then stop=xml:find('-->',at+4,true);if stop then stop=stop+2 end
    elseif xml:sub(at,at+8)=='<![CDATA['then
      stop=xml:find(']]>',at+9,true)
      if stop then if not append(xml:sub(at+9,stop-1),true)then return {}end;stop=stop+2 end
    elseif xml:sub(at,at+1)=='<?'then stop=xml:find('?>',at+2,true);if stop then stop=stop+1 end
    else
      local cursor=at+1
      while true do
        stop=xml:find("[\"'>]",cursor);if not stop then return {}end
        local char=xml:sub(stop,stop)
        if char=='>'then break end
        cursor=xml:find(char,stop+1,true);if not cursor then return {}end;cursor=cursor+1
      end
      local token=xml:sub(at+1,stop-1)
      local closing,name,rest=token:match('^%s*(/?)([%w_:%-]+)(.-)%s*$')
      if not name then return {}end -- DTD/external entities are never resolved.
      local empty=rest:match('/%s*$')~=nil
      if empty then rest=rest:gsub('/%s*$','')end
      if closing=='/'and rest:find('%S')then return {}end
      while rest:find('%S')do
        local finish=rest:match('^%s+[%w_:%-]+%s*=%s*"[^"]*"()')or rest:match("^%s+[%w_:%-]+%s*=%s*'[^']*'()")
        if not finish then return {}end;rest=rest:sub(finish)
      end
      if closing=='/'then
        if empty or stack[#stack]~=name then return {}end
        if field and #stack==4 then field=nil end
        if current and #stack==3 and name=='TRACK'then tracks[#tracks+1]=current;current=nil end
        stack[#stack]=nil
      else
        nodes=nodes+1;if nodes>16384 or #stack>=32 then return {}end
        if #stack==0 then
          if name~='BWFXML' or root_seen then return {}end;root_seen=true
        end
        if #stack==2 and stack[1]=='BWFXML'and stack[2]=='TRACK_LIST'and name=='TRACK'then current={}end
        if current and #stack==3 and (name=='NAME' or name=='INTERLEAVE_INDEX')then
          if current[name]~=nil then current.invalid=true end
          current[name]='';field=name
        elseif field then current.invalid=true end
        stack[#stack+1]=name
        if empty then
          if field and #stack==4 then field=nil end
          if current and #stack==3 and name=='TRACK'then tracks[#tracks+1]=current;current=nil end
          stack[#stack]=nil
        end
      end
    end
    if not stop then return {}end;pos=stop+1
  end
  if #stack~=0 then return {}end
  local names,seen={},{}
  for _,track in ipairs(tracks)do
    local channel=integer(track.INTERLEAVE_INDEX,channels)
    if channel then
      -- An ambiguous duplicate index must never label the wrong microphone.
      if seen[channel]then names[channel]=nil
      elseif not track.invalid then names[channel]=clean(track.NAME)end
      seen[channel]=true
    end
  end
  return names
end
local function chunk(input)
  local size=assert(input:seek('end'));assert(size>=12)
  assert(input:seek('set',0));local header=assert(input:read(12))
  local kind=header:sub(1,4);local extended=kind=='RF64' or kind=='BW64'
  if header:sub(9)~='WAVE' or (kind~='RIFF' and not extended)then return end
  local limit=extended and size or string.unpack('<I4',header,5)+8
  assert(limit>=12 and limit<=size)
  local offset,data_size,tables=12,nil,{}
  for _=1,MAX_CHUNKS do
    if offset+8>limit then return end
    assert(input:seek('set',offset));local tag,length=string.unpack('<c4I4',assert(input:read(8)))
    local body=offset+8
    if length==0xffffffff then
      if not extended then return end
      if tag=='data'then length=data_size
      else local list=tables[tag];length=list and table.remove(list,1)end
    end
    assert(length and length>=0 and length<=limit-body)
    if tag=='iXML'then
      if length>MAX_XML then return end
      return input:read(length)
    elseif tag=='ds64' and extended then
      assert(length>=28 and length<=MAX_XML)
      local bytes=assert(input:read(length));local riff,frames,count
      riff,data_size,frames,count=string.unpack('<I8I8I8I4',bytes)
      assert(riff>=4 and riff<=size-8 and data_size>=0 and count<=(length-28)//12)
      limit=riff+8
      for i=1,count do
        local id,n=string.unpack('<c4I8',bytes,29+(i-1)*12);assert(n>=0)
        tables[id]=tables[id]or {};tables[id][#tables[id]+1]=n
      end
    end
    offset=body+length+length%2
  end
end
function M.read(path,channels)
  if not path or not channels or channels<1 or channels>128 then return {}end
  local file=io.open(path,'rb');if not file then return {}end
  local ok,xml=pcall(chunk,file);file:close()
  if not ok or not xml then return {}end
  local parsed,names=pcall(M.parse,xml,channels)
  return parsed and names or {}
end
-- One source per picker; refresh on selection/file identity changes, not frames.
function M.cached(cache,path,channels,identity)
  local size,mtime=identity and identity.size,identity and identity.mtime
  if cache.names==nil or cache.path~=path or cache.channels~=channels or cache.size~=size or cache.mtime~=mtime then
    cache.path,cache.channels,cache.size,cache.mtime=path,channels,size,mtime
    cache.names=M.read(path,channels)
  end
  return cache.names
end
return M
