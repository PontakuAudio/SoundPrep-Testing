local P=require('am.platform');local U=require('am.util')
local win={GetOS=function()return 'Win64'end};local mac={GetOS=function()return 'OSX64'end}
assert(P.windows(win) and not P.windows(mac))
assert(P.helper_name(win)=='reaper_audition_macro.dll' and P.worker_name(win)=='reaper_audition_macro_worker.dll')
assert(P.helper_name(mac)=='reaper_audition_macro.dylib')
assert(U.path_equal([[C:\素材\Foo.WAV]],'c:/素材/foo.wav',true))
assert(U.path_equal([[\\server\音\a.wav]],'//SERVER/音/a.wav',true))
assert(not U.path_equal('/audio/A.wav','/audio/a.wav',false))
assert(not U.path_equal([[C:\素材\a.wav]],[[D:\素材\a.wav]],true))
-- Windows command lines use CRT argument quoting, not shell expansion/escaping.
local args={[[C:\Program Files\Python\python.exe]],[[D:\音 素材\worker.py]],[[%PATH% & literal]],[[tail\]],[[a\"b]]}
assert(P.command(win,args)==[["C:\Program Files\Python\python.exe" "D:\音 素材\worker.py" "%PATH% & literal" "tail\\" "a\\\"b"]])
assert(P.command(mac,{'/opt/python','/tmp/a b.py'})=='"/opt/python" "/tmp/a b.py"')
for _,bad in ipairs{'\0','line\nbreak','\r'}do assert(not pcall(P.command,win,{bad}))end
assert(not pcall(P.command,mac,{'/tmp/$(no)'}))
local original=os.getenv
os.getenv=function(key)return ({PATH=[[C:\WindowsApps;C:\Tools;"D:\Program Files\Python"]],LOCALAPPDATA=[[C:\Users\音\AppData\Local]],ProgramFiles=[[C:\Program Files]]})[key]end
local candidates=P.candidates(win,'python3');assert(candidates[1]==[[C:\Tools/python.exe]] and candidates[2]==[[D:\Program Files\Python/python.exe]])
for _,path in ipairs(candidates)do assert(not path:lower():find('windowsapps',1,true))end
assert(P.candidates(win,'ffmpeg')[1]==[[C:\Tools/ffmpeg.exe]])
os.getenv=original
