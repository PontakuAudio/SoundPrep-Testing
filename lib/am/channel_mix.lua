local M={}
function M.valid_channels(channels)
  if type(channels)~='number' or channels<4 or channels>121 then return false end
  local order=math.floor(math.sqrt(channels))
  return order*order==channels
end
function M.detected(path,channels)
  if type(path)~='string' or not M.valid_channels(channels)then return false end
  -- Directory names and channel counts cannot identify an Ambisonics format.
  local basename=path:match('[^/\\]+$')or ''
  return (' '..basename:lower()..' '):find('[^a-z0-9]ambix[^a-z0-9]')~=nil
end
function M.resolve(path,channels,preference)
  preference=preference or 'auto'
  if preference=='discrete'then return 1 end
  if preference=='ambix'then
    if not M.valid_channels(channels)then
      return nil,'AmbiX stereo preview requires a full 3D ACN/SN3D source with 4, 9, 16, ... 121 channels.'
    end
    return 2
  end
  if preference~='auto'then return nil,'Unknown preview downmix mode.'end
  return M.detected(path,channels)and 2 or 1
end
function M.describe(path,channels,preference)
  local mode,reason=M.resolve(path,channels,preference)
  if not mode then return 'AmbiX: unavailable',reason end
  local label=mode==2 and 'AmbiX' or 'Discrete'
  return (not preference or preference=='auto')and 'Auto: '..label or label
end
return M
