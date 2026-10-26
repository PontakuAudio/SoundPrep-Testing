// Exercise the shared Lua code with the actual Windows file/path adapter.
// No REAPER process or user configuration is involved.
extern "C" {
#include "lua.h"
#include "lualib.h"
#include "lauxlib.h"
}
#include <string>
#include <cstdio>
extern "C" void AMPlatformRegister(int(*)(const char*,void*),void*(*)(const char*));
namespace {
bool(*replaceFile)(const char*,const char*);
bool(*equalPath)(const char*,const char*);
int registration(const char* name,void* value){
  if(std::string(name)=="API_AM_FileReplace")replaceFile=reinterpret_cast<decltype(replaceFile)>(value);
  if(std::string(name)=="API_AM_PathEqual")equalPath=reinterpret_cast<decltype(equalPath)>(value);
  return 1;
}
int replace(lua_State* state){lua_pushboolean(state,replaceFile(luaL_checkstring(state,1),luaL_checkstring(state,2)));return 1;}
int equal(lua_State* state){lua_pushboolean(state,equalPath(luaL_checkstring(state,1),luaL_checkstring(state,2)));return 1;}
int exists(lua_State* state){std::string name=luaL_checkstring(state,1);lua_pushboolean(state,name=="AM_FileReplace" || name=="AM_PathEqual");return 1;}
}
int main(int argc,char** argv){
  if(argc!=2)return 2;
  AMPlatformRegister(registration,+[](const char*)->void*{return nullptr;});
  lua_State* state=luaL_newstate();if(!state)return 2;luaL_openlibs(state);
  lua_newtable(state);
  lua_pushcfunction(state,exists);lua_setfield(state,-2,"APIExists");
  lua_pushcfunction(state,replace);lua_setfield(state,-2,"AM_FileReplace");
  lua_pushcfunction(state,equal);lua_setfield(state,-2,"AM_PathEqual");
  lua_setglobal(state,"reaper");
  int status=luaL_dofile(state,argv[1]);if(status)std::fprintf(stderr,"%s\n",lua_tostring(state,-1));
  lua_close(state);return status?1:0;
}
