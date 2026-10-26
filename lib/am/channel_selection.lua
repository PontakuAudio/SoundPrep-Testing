-- Input choices belong to a recording layout, shared by Raw and every preset.
local U=require('am.util')
local M={}
function M.valid(channels,selection)
  if not U.finite(channels)or channels%1~=0 or channels<1 or channels>128 or type(selection)~='table'then return false end
  if selection.channels then
    for key in pairs(selection)do if key~='channels'then return false end end
    local list=selection.channels
    if type(list)~='table' or #list<1 or #list>channels then return false end
    local seen={}
    for key,value in pairs(list)do
      if not U.finite(key)or key%1~=0 or key<1 or key>#list or not U.finite(value)or
        value%1~=0 or value<1 or value>channels or seen[value]then return false end
      seen[value]=true
    end
    if #list>2 then for i=2,#list do if list[i]<=list[i-1]then return false end end end
    return true
  end
  for key in pairs(selection)do if key~='left' and key~='right'then return false end end
  for _,key in ipairs{'left','right'}do
    local value=selection[key]
    if not U.finite(value)or value%1~=0 or value<1 or value>channels then return false end
  end
  return true
end
function M.list(selection)
  if selection.channels then return U.copy(selection.channels)end
  return selection.left==selection.right and {selection.left}or {selection.left,selection.right}
end
function M.output(selection)return math.max(2,#M.list(selection))end
function M.csv(selection)return table.concat(M.list(selection),',')end
-- REAPER reserves 67..130 for stereo pairs, splitting mono above ch 64.
function M.take_mode(selection)
  if not selection then return end
  local list=M.list(selection);if #list>2 then return end
  local l,r=list[1],list[2]or list[1]
  if l==r then return l+(l<=64 and 2 or 66)end
  if r==l+1 then return l+(l<=64 and 66 or 130)end
end
function M.get(settings,channels)
  local routes=settings and settings.channel_selections
  return routes and routes[tostring(channels)]
end
function M.validate(routes)
  assert(type(routes)=='table','Invalid input channel selections')
  for key,value in pairs(routes)do
    local channels=type(key)=='string' and tonumber(key)
    assert(channels and tostring(channels)==key and M.valid(channels,value),'Invalid input channel selection')
  end
end
function M.label(selection)
  local list=M.list(selection)
  if #list==1 then return ('Mono ch %d'):format(list[1])end
  if #list==2 then return ('L %d / R %d'):format(list[1],list[2])end
  return 'Ch '..table.concat(list,', ')

end
return M
