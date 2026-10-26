-- Remove render-only channel padding without decoding or rounding samples.
-- RIFF/WAVE and RF64 (EBU Tech 3306); all non-audio chunks remain byte exact.
local M={}
local MAX32=0xffffffff
local MAX_SAFE=9007199254740991
local COPY_BYTES=1024*1024
local function integer(value)return type(value)=='number' and value==math.floor(value) and value>=0 and value<=MAX_SAFE end
local function read(file,count)
  local value=assert(file:read(count),'Truncated WAV file')
  assert(#value==count,'Truncated WAV file');return value
end
local function seek(file,position)assert(file:seek('set',position),'Cannot seek WAV file')end
local function u64(bytes,position)
  local value=string.unpack('<I8',bytes,position)
  assert(integer(value),'Unsupported WAV size');return value
end
local function inspect(file,wanted)
  local size=assert(file:seek('end'),'Cannot read WAV size')
  assert(integer(size) and size>=12,'Invalid WAV size');seek(file,0)
  local header=read(file,12);local id=header:sub(1,4)
  assert((id=='RIFF' or id=='RF64') and header:sub(9,12)=='WAVE','Unsupported WAV container')
  local rf64=id=='RF64';local riff_size=string.unpack('<I4',header,5)
  local ds,fmt,data;local occurrences={}
  if rf64 then
    local chunk=read(file,8);local length=string.unpack('<I4',chunk,5)
    assert(chunk:sub(1,4)=='ds64' and length>=28 and length~=MAX32 and 20+length+length%2<=size,'Invalid RF64 ds64 chunk')
    local body=read(file,28)
    ds={offset=20,length=length,riff_size=u64(body,1),data_size=u64(body,9),samples=u64(body,17),count=string.unpack('<I4',body,25)}
    assert(28+12*ds.count<=length,'Truncated RF64 size table')
    if riff_size==MAX32 then riff_size=ds.riff_size end
  end
  assert(riff_size+8==size,'Truncated or inconsistent WAV container')
  local function chunk_size(name,value)
    if value~=MAX32 then return value end
    assert(ds,'Missing RF64 size information')
    if name=='data'then return ds.data_size end
    -- The table may list repeated chunk IDs; use their occurrence order.
    local occurrence=(occurrences[name]or 0)+1;occurrences[name]=occurrence
    local found=0
    seek(file,ds.offset+28)
    for _=1,ds.count do
      local entry=read(file,12)
      if entry:sub(1,4)==name then
        found=found+1;if found==occurrence then return u64(entry,5)end
      end
    end
    error('Missing RF64 chunk size')
  end
  local offset=12
  while offset<size do
    assert(size-offset>=8,'Truncated WAV chunk header');seek(file,offset)
    local chunk=read(file,8);local name=chunk:sub(1,4);local raw_size=string.unpack('<I4',chunk,5)
    local length=chunk_size(name,raw_size);local body=offset+8
    assert(integer(length) and length<=size-body and length%2<=size-body-length,'Truncated WAV chunk')
    if name=='fmt 'then
      assert(not fmt and length>=16,'Invalid WAV format chunk');seek(file,body)
      local bytes=read(file,math.min(length,40))
      local format,channels,rate,byte_rate,align,bits=string.unpack('<I2I2I4I4I2I2',bytes)
      assert(channels>=1 and channels<=128 and wanted<=channels,'Invalid WAV channel count')
      assert(bits>0 and bits<=64 and bits%8==0,'Unsupported WAV sample width')
      assert(rate>0 and align==channels*(bits//8) and byte_rate==rate*align,'Invalid WAV sample alignment')
      if length~=16 then
        assert(length>=18 and 18+string.unpack('<I2',bytes,17)<=length,'Truncated WAV format extension')
      end
      if format==0xfffe then
        assert(length>=40 and string.unpack('<I2',bytes,17)>=22,'Invalid extensible WAV format')
        local valid=string.unpack('<I2',bytes,19)
        assert(valid>0 and valid<=bits,'Invalid WAV valid bit count')
        local subtype=string.unpack('<I4',bytes,25)
        assert(bytes:sub(29,40)=='\0\0\16\0\128\0\0\170\0\56\155\113','Unsupported WAV subtype')
        format=subtype
      end
      assert(format==1 or format==3 and (bits==32 or bits==64),'Unsupported WAV sample format')
      local new_align=wanted*(bits//8)
      local replacement=bytes:sub(1,2)..string.pack('<I2I4I4I2I2',wanted,rate,rate*new_align,new_align,bits)..bytes:sub(17)
      if string.unpack('<I2',bytes)==0xfffe then replacement=replacement:sub(1,20)..string.pack('<I4',0)..replacement:sub(25)end
      fmt={offset=body,original=bytes,replacement=replacement,align=align,new_align=new_align}
    elseif name=='data'then
      assert(fmt and not data,'Missing WAV format or multiple data chunks')
      assert(length%fmt.align==0,'Unaligned WAV audio data')
      local frames=length//fmt.align
      data={offset=body,length=length,new_length=frames*fmt.new_align,frames=frames,raw_size=raw_size}
    elseif name=='ds64'then
      assert(rf64 and offset==12,'Unexpected WAV ds64 chunk')
    end
    offset=body+length+length%2
  end
  assert(fmt and data,'Missing WAV format or audio data')
  local output_size=size-data.length-data.length%2+data.new_length+data.new_length%2
  if not rf64 then assert(output_size-8<=MAX32 and data.new_length<=MAX32,'WAV output exceeds RIFF size limit')end
  return {size=size,output_size=output_size,rf64=rf64,fmt=fmt,data=data,ds=ds}
end
local function copy(input,output,count)
  while count>0 do
    local bytes=read(input,math.min(count,COPY_BYTES));assert(output:write(bytes));count=count-#bytes
  end
end
function M.trim(input_path,output_path,wanted_channels)
  assert(integer(wanted_channels) and wanted_channels>=1 and wanted_channels<=128,'Invalid target channel count')
  assert(type(input_path)=='string' and type(output_path)=='string' and input_path~=output_path,'Use a separate WAV output path')
  local exists=io.open(output_path,'rb');if exists then exists:close();error('WAV output already exists')end
  local input=assert(io.open(input_path,'rb'));local output,created
  local ok,err=xpcall(function()
    local info=inspect(input,wanted_channels);local fmt,data=info.fmt,info.data
    local patches={
      {offset=4,length=4,bytes=string.pack('<I4',info.rf64 and MAX32 or info.output_size-8)},
      {offset=fmt.offset,length=#fmt.original,bytes=fmt.replacement},
      {offset=data.offset-4,length=4,bytes=string.pack('<I4',info.rf64 and data.raw_size==MAX32 and MAX32 or data.new_length)},
      {offset=data.offset,length=data.length+data.length%2,audio=true}
    }
    if info.ds then patches[#patches+1]={offset=info.ds.offset,length=24,
      bytes=string.pack('<I8I8I8',info.output_size-8,data.new_length,data.frames)}end
    table.sort(patches,function(a,b)return a.offset<b.offset end)
    output=assert(io.open(output_path,'wb'));created=true
    local position=0
    for _,patch in ipairs(patches)do
      seek(input,position);copy(input,output,patch.offset-position)
      if patch.audio then
        local pattern=fmt.align~=fmt.new_align and '('..('.'):rep(fmt.new_align)..')'..('.'):rep(fmt.align-fmt.new_align)or nil
        local remaining=data.frames
        while remaining>0 do
          local frames=math.min(8192,remaining);local bytes=read(input,frames*fmt.align)
          if pattern then
            local count;bytes,count=bytes:gsub(pattern,'%1');assert(count==frames,'Cannot trim WAV channel frames')
          end
          assert(output:write(bytes));remaining=remaining-frames
        end
        if data.new_length%2==1 then
          -- Reuse an existing data pad byte when present, otherwise add one.
          assert(output:write(data.length%2==1 and read(input,1)or '\0'))
        end
      else assert(output:write(patch.bytes))end
      position=patch.offset+patch.length
    end
    seek(input,position);copy(input,output,info.size-position)
    assert(output:close());output=nil
  end,function(reason)return tostring(reason)end)
  input:close();if output then output:close()end
  if not ok then if created then os.remove(output_path)end;error(err,0)end
  return true
end
return M
