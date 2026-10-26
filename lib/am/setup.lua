-- First-run ZIP setup shared by the launcher and optional action installer.
local P=require('am.platform')
local M={}
M.restart_notice='SoundPrep is ready. Save your work and restart REAPER, then run SoundPrep.lua again.'
function M.install_native_if_missing(r,root)
  if P.windows(r) and r.GetOS()~='Win64'then
    error('SoundPrep requires the x64 edition of REAPER on Windows.',0)
  end
  -- A loaded helper must only be updated after REAPER exits.
  if r.APIExists('AM_HelperInfo')then return false end
  local platform=r.GetOS()
  if not (P.windows(r) or platform:match('OSX') or platform:match('macOS'))then return false end
  local name=P.helper_name(r)
  local directory=r.GetResourcePath()..'/UserPlugins'
  local target=directory..'/'..name
  if r.file_exists(target)then return false end
  local input=io.open(root..'/build/'..name,'rb')
  assert(input,'Native helper is missing. Extract the complete SoundPrep release ZIP, or reinstall the SoundPrep package through ReaPack.')
  local bytes,read_error=input:read('*a');input:close()
  assert(bytes and #bytes>0,read_error or 'The bundled native helper is empty.')
  r.RecursiveCreateDirectory(directory,0)
  -- Finish the copy before making it visible as a loadable REAPER extension.
  local temporary=target..'.soundprep-new'
  local output,open_error=io.open(temporary,'wb');assert(output,open_error)
  local written,write_error=output:write(bytes)
  local closed,close_error=output:close()
  if not written or not closed then os.remove(temporary);error(write_error or close_error,0)end
  local moved,move_error=os.rename(temporary,target)
  if not moved then os.remove(temporary);error(move_error,0)end
  return true
end
return M
