local W=require('am.wave_channels');local U=require('am.util')
local input=os.tmpname();local output=os.tmpname();os.remove(input);os.remove(output)
local function chunk(id,bytes,pad,size)return id..string.pack('<I4',size or #bytes)..bytes..(#bytes%2==1 and(pad or '\0')or '')end
local function format(channels,bits,kind,extensible)
  local align=channels*(bits//8)
  local base=string.pack('<I2I2I4I4I2I2',extensible and 0xfffe or kind,channels,48000,48000*align,align,bits)
  return extensible and base..string.pack('<I2I2I4I4',22,bits,0x3ffff,kind)..'\0\0\16\0\128\0\0\170\0\56\155\113' or base
end
local function wave(fmt,data,before,after,rf64)
  local body=(before or '')..chunk('fmt ',fmt)..chunk('data',data,'D',rf64 and 0xffffffff)..(after or '')
  if rf64 then
    local ds=chunk('ds64',string.pack('<I8I8I8I4',#body+4+36,#data,#data//string.unpack('<I2',fmt,13),0))
    return 'RF64'..string.pack('<I4',0xffffffff)..'WAVE'..ds..body
  end
  return 'RIFF'..string.pack('<I4',#body+4)..'WAVE'..body
end
local function parts(bytes)
  local found={};local offset=13;local ds_data
  while offset<=#bytes do
    local id=bytes:sub(offset,offset+3);local size=string.unpack('<I4',bytes,offset+4)
    if id=='data'and size==0xffffffff then size=ds_data end
    local body=bytes:sub(offset+8,offset+7+size)
    found[id]={bytes=body,size=size,pad=size%2==1 and bytes:sub(offset+8+size,offset+8+size)or '',raw=bytes:sub(offset,offset+7+size+size%2)}
    if id=='ds64'then ds_data=string.unpack('<I8',body,9)end
    offset=offset+8+size+size%2
  end
  assert(offset==#bytes+1);return found
end
local function trimmed(source,n)
  assert(U.write(input,source));assert(W.trim(input,output,n))
  assert(U.read(input)==source,'Channel trimming modified input')
  local result=assert(U.read(output));os.remove(output);return result,parts(result)
end
local function rejected(source,n)
  assert(U.write(input,source));os.remove(output)
  assert(not pcall(W.trim,input,output,n or 3),'Invalid WAV was accepted')
  assert(U.read(output)==nil,'Failed WAV trim left output behind')
  assert(U.read(input)==source,'Failed trim modified input')
end
local ok,err=xpcall(function()
  -- More than one processing block, with arbitrary bytes including NUL and LF.
  local frames,expected={},{}
  for frame=1,8201 do
    local row={};for channel=1,4 do row[channel]=string.pack('<I3',(frame*997+channel*131)%0x1000000)end
    frames[frame]=table.concat(row);expected[frame]=table.concat(row,'',1,3)
  end
  local extra=chunk('JUNK','abc','P')..chunk('LIST','metadata','Q')
  local tail=chunk('bext','tail\0metadata','R')
  local source=wave(format(4,24,1),table.concat(frames),extra,tail)
  local result,p=trimmed(source,3)
  assert(p.data.bytes==table.concat(expected) and p.data.pad=='\0')
  assert(p.JUNK.raw==parts(source).JUNK.raw and p.LIST.raw==parts(source).LIST.raw and p.bext.raw==parts(source).bext.raw)
  local kind,n,rate,byte_rate,align,bits=string.unpack('<I2I2I4I4I2I2',p['fmt '].bytes)
  assert(kind==1 and n==3 and rate==48000 and byte_rate==48000*9 and align==9 and bits==24)
  assert(string.unpack('<I4',result,5)==#result-8)

  frames={};expected={}
  for frame=1,17 do
    local row={};for channel=1,10 do row[channel]=string.pack('<f',(frame-channel)/32)end
    frames[frame]=table.concat(row);expected[frame]=table.concat(row,'',1,9)
  end
  source=wave(format(10,32,3,true),table.concat(frames),chunk('fact',string.pack('<I4',17)),extra)
  result,p=trimmed(source,9)
  assert(p.data.bytes==table.concat(expected) and p.fact.raw==parts(source).fact.raw)
  assert(string.unpack('<I2',p['fmt '].bytes,3)==9 and string.unpack('<I2',p['fmt '].bytes,13)==36)
  assert(string.unpack('<I4',p['fmt '].bytes,21)==0 and p['fmt '].bytes:sub(25)==parts(source)['fmt '].bytes:sub(25))

  -- RF64 keeps its container and marker fields; ds64 counts describe output.
  source=wave(format(4,16,1,true),string.rep('\1\2\3\4\5\6\7\8',9),extra,tail,true)
  result,p=trimmed(source,3)
  assert(result:sub(1,4)=='RF64' and string.unpack('<I4',result,5)==0xffffffff)
  local riff_size,data_size,samples,table_size=string.unpack('<I8I8I8I4',p.ds64.bytes)
  assert(riff_size==#result-8 and data_size==54 and samples==9 and table_size==0)
  assert(string.unpack('<I4',p.data.raw,5)==0xffffffff and p.data.bytes==string.rep('\1\2\3\4\5\6',9))

  -- Optional RF64 size tables can describe metadata beyond the data chunk.
  -- Their contents and unusual pad bytes must survive unchanged.
  local audio=string.rep('\1\2\3\4',7)
  local table_data='JUNK'..string.pack('<I8',3)
  local rf_body=chunk('fmt ',format(4,8,1))..chunk('data',audio,nil,0xffffffff)..chunk('JUNK','xyz','Z',0xffffffff)
  local ds_body=string.pack('<I8I8I8I4',4+8+28+#table_data+#rf_body,#audio,7,1)..table_data
  source='RF64'..string.pack('<I4',0xffffffff)..'WAVE'..chunk('ds64',ds_body)..rf_body
  assert(U.write(input,source));assert(W.trim(input,output,3));result=assert(U.read(output));os.remove(output)
  assert(U.read(input)==source and result:sub(-12)==source:sub(-12))
  assert(string.unpack('<I8',result,21)==#result-8 and string.unpack('<I8',result,29)==21)
  assert(result:sub(49,60)==table_data)
  rejected(source:sub(1,48)..'FAIL'..source:sub(53))

  -- An existing odd data pad remains byte exact; same-width copies are valid.
  source=wave(format(3,8,1),'abcdefghi',extra,tail)
  result,p=trimmed(source,1);assert(p.data.bytes=='adg' and p.data.pad=='D')
  result=trimmed(source,3);assert(result==source)

  -- Maximum channel count and 64-bit floating-point samples exercise the
  -- largest pattern, including high channels that a stereo API would lose.
  local row={};for channel=1,128 do row[channel]=string.pack('<d',channel/128)end
  result,p=trimmed(wave(format(128,64,3),table.concat(row)),127)
  assert(p.data.bytes==table.concat(row,'',1,127))

  local valid=wave(format(4,24,1),string.rep('\0',24))
  for _,n in ipairs{0,129,5,2.5,-1,math.huge}do rejected(valid,n)end
  rejected('not wave');rejected(valid:sub(1,-2));rejected(valid..'unexpected')
  rejected(wave(format(4,24,1),'unaligned'))
  rejected(wave(format(4,24,6),string.rep('\0',24)))
  rejected(wave(format(4,24,3),string.rep('\0',24)))
  rejected(wave(format(4,24,1):sub(1,12)..string.pack('<I2',1)..string.pack('<I2',24),string.rep('\0',24)))
  rejected(wave(format(4,24,1,true):sub(1,39)..'x',string.rep('\0',24)))
  rejected(wave(format(4,24,1,true):sub(1,18)..string.pack('<I2',25)..format(4,24,1,true):sub(21),string.rep('\0',24)))
  rejected(wave(format(4,24,1),string.rep('\0',24),nil,chunk('data',string.rep('\0',24))))
  rejected('RF64'..string.pack('<I4',0xffffffff)..'WAVE'..chunk('fmt ',format(4,24,1)))

  -- A write failure removes only this invocation's partial output.
  assert(U.write(input,valid));local open=io.open
  io.open=function(path,mode)
    local file,reason=open(path,mode)
    if file and path==output and mode=='wb'then
      local writes=0
      return {write=function(_,bytes)
        writes=writes+1;if writes==2 then return nil,'Injected write failure'end
        return file:write(bytes)
      end,close=function()return file:close()end}
    end
    return file,reason
  end
  local written,reason=pcall(W.trim,input,output,3);io.open=open
  assert(not written and tostring(reason):find('Injected write failure',1,true))
  assert(U.read(output)==nil and U.read(input)==valid)
  assert(U.write(input,valid));assert(U.write(output,'keep existing'))
  assert(not pcall(W.trim,input,output,3) and U.read(output)=='keep existing')
  assert(not pcall(W.trim,input,input,3) and U.read(input)==valid)
end,debug.traceback)
os.remove(input);os.remove(output)
assert(ok,err)
