local Names=require('am.channel_names');local U=require('am.util')
local function track(index,name,channel)
  return '<TRACK><CHANNEL_INDEX>'..(channel or index)..'</CHANNEL_INDEX><INTERLEAVE_INDEX>'..index..
    '</INTERLEAVE_INDEX>'..(name==false and ''or '<NAME>'..name..'</NAME>')..'</TRACK>'
end
local function xml(body)return '<?xml version="1.0" encoding="UTF-8"?><BWFXML><TRACK_LIST>'..body..'</TRACK_LIST></BWFXML>\0'end
local function parse(body,n)return Names.parse(xml(body),n or 6)end
local names=parse(track(3,'MKH 416')..track(1,'MixL')..track(2,'')..track(5,'basicUchoL',7)..track(6,'basicUchoR',8))
assert(names[1]=='MixL' and names[2]==nil and names[3]=='MKH 416' and names[4]==nil and names[5]=='basicUchoL' and names[6]=='basicUchoR')
assert(parse(track(1,'basicUchoL',3),1)[1]=='basicUchoL')
assert(parse(track(1,false)..track(2,'Boom'))[2]=='Boom')
assert(parse(track(1,' \r\n '))[1]==nil)
assert(parse(track(1,'A &amp; B &lt;S&gt; &quot;M&quot; &apos;R&apos; &#35;&#x23;'))[1]=='A & B <S> "M" \'R\' ##')
assert(parse(track(1,'風鈴 &#x1F3A4;'))[1]=='風鈴 🎤')
assert(parse(track(1,'<![CDATA[Mic <L> & ##raw]]>'))[1]=='Mic <L> & ##raw')
assert(parse(track(1,'<inner>wrong</inner>'))[1]==nil)
for _,bad in ipairs{'&unknown;','&#0;','&#xD800;','&#x110000;','\255'}do assert(parse(track(1,bad))[1]==nil)end
assert(next(parse(track(0,'zero')..track(7,'too high')..track('1.5','fraction')))==nil)
assert(next(parse(track(1,'one')..track(1,'duplicate')))==nil)
assert(next(parse('<TRACK><NAME>No index</NAME><CHANNEL_INDEX>3</CHANNEL_INDEX></TRACK>'))==nil)
assert(next(parse('<TRACK><INTERLEAVE_INDEX>1</INTERLEAVE_INDEX><NAME>A</NAME><NAME>B</NAME></TRACK>'))==nil)
assert(parse('<!-- <TRACK><NAME>False</NAME></TRACK> -->'..track(1,'True'))[1]=='True')
assert(Names.parse(xml(track(1,'Name')):gsub('<BWFXML>','<BWFXML version="1 > 0">'),6)[1]=='Name')
for _,bad in ipairs{'not XML','<!DOCTYPE BWFXML [<!ENTITY test SYSTEM "file:///x">]><BWFXML/>',
  xml(track(1,'Name')):gsub('</TRACK>','</WRONG>'),xml(track(1,'Name'))..'<BWFXML/>',xml(track(1,'Name')):sub(1,-12),string.rep('x',1024*1024+1)}do
  assert(next(Names.parse(bad,6))==nil)
end
local function chunk(id,body,size)return id..string.pack('<I4',size or #body)..body..(#body%2==1 and '\0'or '')end
local function wave(body)return 'RIFF'..string.pack('<I4',#body+4)..'WAVE'..body end
local path=os.tmpname();local function read(bytes,n)
  assert(U.write(path,bytes));return Names.read(path,n or 6)
end
local metadata=xml(track(1,'Left')..track(2,'')..track(3,'Right'))
assert(read(wave(chunk('JUNK','odd')..chunk('data',string.rep('\0',1024))..chunk('iXML',metadata)))[3]=='Right')
-- Extended WAV sizes, including metadata located after the audio payload.
for _,kind in ipairs{'RF64','BW64'}do
  local body=chunk('data','\0\0\0\0',0xffffffff)..chunk('iXML',metadata)
  local ds=chunk('ds64',string.pack('<I8I8I8I4',4+36+#body,4,2,0))
  assert(read(kind..string.pack('<I4',0xffffffff)..'WAVE'..ds..body)[3]=='Right')
end
for _,bytes in ipairs{wave(chunk('data','audio')),wave('iXML'..string.pack('<I4',1024*1024+1)),
  'RIFF'..string.pack('<I4',9999)..'WAVE',wave('iXML'..string.pack('<I4',100)..'short'),
  'RF64'..string.pack('<I4',0xffffffff)..'WAVEdata'..string.pack('<I4',0xffffffff)}do assert(next(read(bytes))==nil)end
-- File identity and path changes invalidate names; repeated frames do not reread.
local cache={};local original=Names.read;local reads=0
Names.read=function(p,n)reads=reads+1;return {[1]=p..':'..n}end
local a=Names.cached(cache,'one',6,{size=100,mtime=1});assert(a[1]=='one:6')
assert(Names.cached(cache,'one',6,{size=100,mtime=1})==a and reads==1)
Names.cached(cache,'one',6,{size=100,mtime=2});assert(reads==2)
Names.cached(cache,'two',6,{size=100,mtime=2});assert(reads==3)
Names.cached(cache,'two',2,{size=100,mtime=2});assert(reads==4)
Names.read=original;os.remove(path)
assert(next(Names.read(path,6))==nil and next(Names.read(nil,6))==nil)
