local J=require('am.json')
local M={}
function M.replace(source,target)
  if package.config:sub(1,1)=='\\' and reaper and reaper.APIExists and reaper.APIExists('AM_FileReplace')then
    if reaper.AM_FileReplace(source,target)then return true end
    return nil,'Cannot atomically replace file; check permissions and open file handles'
  end
  return os.rename(source,target)
end
function M.path_equal(a,b,windows)
  if a==b then return true end
  if type(a)~='string' or type(b)~='string'then return false end
  if windows==nil then windows=package.config:sub(1,1)=='\\'end
  if not windows then return false end
  if reaper and reaper.APIExists and reaper.APIExists('AM_PathEqual')then return reaper.AM_PathEqual(a,b)end
  return a:gsub('\\','/'):lower()==b:gsub('\\','/'):lower()
end
function M.read(path)
  local f,e=io.open(path,'rb');if not f then return nil,e end
  local text=f:read('*a');f:close();return text
end
function M.write(path, text)
  local temp=path..'.tmp'
  local f,e=io.open(temp,'wb');if not f then return nil,e end
  local ok,err=f:write(text);local closed,ce=f:close()
  if not ok or not closed then os.remove(temp);return nil,err or ce end
  local moved,me=M.replace(temp,path)
  if not moved then os.remove(temp);return nil,me end
  return true
end
function M.copy_file(source,target)
  local input,e=io.open(source,'rb');if not input then return nil,e end
  local output,err=io.open(target..'.tmp','wb');if not output then input:close();return nil,err end
  local ok,failure=pcall(function()
    while true do
      local bytes,error=input:read(1024*1024);assert(not error,error)
      if not bytes then break end;assert(output:write(bytes))
    end
    assert(output:close());output=nil
    assert(M.replace(target..'.tmp',target))
  end)
  input:close();if output then output:close()end
  if not ok then os.remove(target..'.tmp');return nil,failure end
  return true
end
function M.copy(v)
  if type(v)~='table' or v==J.null then return v end
  local out={};for k,x in pairs(v)do out[k]=M.copy(x)end;return setmetatable(out,getmetatable(v))
end
function M.equal(a,b)
  if a==b then return true end
  if type(a)~='table' or type(b)~='table' or a==J.null or b==J.null then return false end
  for k,v in pairs(a)do if not M.equal(v,b[k])then return false end end
  for k in pairs(b)do if a[k]==nil then return false end end
  return true
end
function M.clamp(v,a,b) return math.max(a,math.min(b,v)) end
function M.finite(v) return type(v)=='number' and v==v and math.abs(v)~=math.huge end
function M.db(g) return g>0 and 20*math.log(g,10) or -150 end
function M.gain(db) return 10^(db/20) end
function M.basename(p) return p:match('([^/\\]+)$') or p end
function M.dirname(p) return p:match('^(.*)[/\\][^/\\]*$') or '.' end
function M.safe_relative(p)
  if type(p)~='string' or p=='' or p:find('[%z\r\n]') or p:match('^[/\\]') or p:match('^%a:') then return false end
  for part in p:gmatch('[^/\\]+')do if part=='..' then return false end end
  return true
end
function M.hash(s)
  local h=2166136261
  for i=1,#s do h=((h ~ s:byte(i))*16777619)&0xffffffff end
  return ('%08x'):format(h)
end
-- Commands are launched via ExecProcess, never via a user-composed shell string.
function M.quote_arg(s, windows)
  assert(not s:find('[%z\r\n]'),'Invalid command argument')
  if windows then return '"'..s:gsub('(\\*)"','%1%1\\"'):gsub('(\\+)$','%1%1')..'"' end
  return "'"..s:gsub("'","'\\''").."'"
end
return M
