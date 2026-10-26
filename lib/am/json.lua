-- Small strict JSON codec. Objects are sorted for readable, stable Git diffs.
local M = { null = {} }
local arrays = { __json_array = true }
function M.array(t) return setmetatable(t or {}, arrays) end
local escapes = { ['"']='\\"', ['\\']='\\\\', ['\b']='\\b', ['\f']='\\f', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t' }
local function quote(s)
  return '"' .. s:gsub('[%z\1-\31\\"]', function(c) return escapes[c] or ('\\u%04x'):format(c:byte()) end) .. '"'
end
function M.encode(value)
  local seen = {}
  local function encode(v, depth)
    local kind = type(v)
    if v == M.null then return 'null' end
    if kind == 'string' then return quote(v) end
    if kind == 'boolean' then return tostring(v) end
    if kind == 'number' then
      assert(v == v and math.abs(v) ~= math.huge, 'JSON number must be finite')
      return ('%.17g'):format(v)
    end
    assert(kind == 'table', 'Cannot encode ' .. kind)
    assert(not seen[v], 'JSON cycle'); seen[v] = true
    local is_array = getmetatable(v) == arrays or #v > 0
    local keys, count = {}, 0
    for k in pairs(v) do
      if is_array then assert(type(k)=='number' and k%1==0 and k>=1 and k<=#v, 'Sparse/mixed JSON array'); count=count+1
      else assert(type(k)=='string', 'Object keys must be strings'); keys[#keys+1]=k end
    end
    -- The length operator returns a boundary, not a count, for sparse tables.
    -- ipairs would otherwise silently stop at a hole and discard later values.
    assert(not is_array or count==#v, 'Sparse/mixed JSON array')
    table.sort(keys)
    local parts, pad, inner = {}, string.rep('  ',depth), string.rep('  ',depth+1)
    if is_array then for _, item in ipairs(v) do parts[#parts+1]=inner..encode(item,depth+1) end
    else for _, k in ipairs(keys) do parts[#parts+1]=inner..quote(k)..': '..encode(v[k],depth+1) end end
    seen[v] = nil
    local a,b = is_array and '[' or '{', is_array and ']' or '}'
    return #parts==0 and a..b or a..'\n'..table.concat(parts,',\n')..'\n'..pad..b
  end
  return encode(value,0)..'\n'
end
function M.decode(s)
  assert(type(s)=='string','JSON input must be a string')
  local i,n=1,#s
  local function fail(msg) error(('JSON at byte %d: %s'):format(i,msg),0) end
  local function ws() local _,b=s:find('^[ \t\r\n]*',i);i=(b or i-1)+1 end
  local function str()
    i=i+1;local out={}
    while i<=n do
      local c=s:sub(i,i);i=i+1
      if c=='"' then return table.concat(out) end
      if c=='\\' then
        local e=s:sub(i,i);i=i+1
        local map={['"']='"',['\\']='\\',['/']='/',b='\b',f='\f',n='\n',r='\r',t='\t'}
        if e=='u' then
          local hex=s:sub(i,i+3);if not hex:match('^%x%x%x%x$') then fail('Invalid unicode escape') end
          local cp=tonumber(hex,16);i=i+4
          if cp>=0xd800 and cp<=0xdbff then
            if s:sub(i,i+1)~='\\u' then fail('Missing low surrogate') end
            local lo=tonumber(s:sub(i+2,i+5),16)
            if not lo or lo<0xdc00 or lo>0xdfff then fail('Invalid low surrogate') end
            cp=0x10000+(cp-0xd800)*0x400+lo-0xdc00;i=i+6
          elseif cp>=0xdc00 and cp<=0xdfff then fail('Unexpected low surrogate') end
          out[#out+1]=utf8.char(cp)
        elseif map[e] then out[#out+1]=map[e] else fail('Invalid escape') end
      elseif c:byte()<32 then fail('Unescaped control character') else out[#out+1]=c end
    end
    fail('Unterminated string')
  end
  local parse
  parse=function(depth)
    if depth>80 then fail('Nesting limit') end
    ws();local c=s:sub(i,i)
    if c=='"' then return str() end
    if c=='{' or c=='[' then
      i=i+1;ws();local arr=c=='[';local t=arr and M.array() or {};local close=arr and ']' or '}'
      if s:sub(i,i)==close then i=i+1;return t end
      while true do
        ws();local key
        if not arr then
          if s:sub(i,i)~='"' then fail('Expected object key') end
          key=str();ws();if s:sub(i,i)~=':' then fail('Expected colon') end;i=i+1
          if t[key]~=nil then fail('Duplicate key') end
        end
        local v=parse(depth+1);if arr then t[#t+1]=v else t[key]=v end
        ws();local sep=s:sub(i,i);i=i+1
        if sep==close then return t end
        if sep~=',' then fail('Expected comma or closing delimiter') end
      end
    end
    for word,v in pairs({['true']=true,['false']=false,['null']=M.null}) do
      if s:sub(i,i+#word-1)==word then i=i+#word;return v end
    end
    local token=s:match('^%-?%d+%.%d+[eE][%+%-]?%d+',i) or s:match('^%-?%d+[eE][%+%-]?%d+',i) or s:match('^%-?%d+%.%d+',i) or s:match('^%-?%d+',i)
    if not token or token:match('^%-?0%d') then fail('Invalid value') end
    local v=tonumber(token);if not v or v~=v or math.abs(v)==math.huge then fail('Invalid number') end
    i=i+#token;return v
  end
  local v=parse(0);ws();if i<=n then fail('Trailing input') end;return v
end
return M
