-- Positions exposed by CF Preview are seconds in the rate-adjusted section.
-- Keep transport bookmarks in original source seconds across Macro changes.
local U=require('am.util')
local M={}
function M.bounds(length,range)return range and range[1] or 0,range and range[2] or length end
function M.source(position,length,range,transform)
  local a,b=M.bounds(length,range)
  local distance=U.clamp(position*transform.rate,0,b-a)
  return transform.reverse and b-distance or a+distance
end
function M.position(source,length,range,transform)
  local a,b=M.bounds(length,range)
  source=U.clamp(source,a,b)
  -- Exactly the end destroys a non-looping SWS preview on its next timer tick.
  local duration=(b-a)/transform.rate
  return U.clamp((transform.reverse and (b-source) or (source-a))/transform.rate,0,math.max(0,duration-1/48000))
end
function M.clock(text)
  local value=text and text:match('^%s*([%d:]+[.,]%d+)')
  if not value then return end
  local total=0
  for part in value:gsub(',','.'):gmatch('[^:]+')do total=total*60+tonumber(part)end
  return total
end
return M
