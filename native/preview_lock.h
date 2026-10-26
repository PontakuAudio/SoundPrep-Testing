#pragma once
#include "reaper_audio_abi.h"
// REAPER locks this exact member. Never substitute std::mutex in the public ABI.
#ifdef _WIN32
inline void am_preview_init(preview_register_t& p){InitializeCriticalSection(&p.cs);}
inline void am_preview_destroy(preview_register_t& p){DeleteCriticalSection(&p.cs);}
inline void am_preview_lock(preview_register_t& p){EnterCriticalSection(&p.cs);}
inline void am_preview_unlock(preview_register_t& p){LeaveCriticalSection(&p.cs);}
inline bool am_preview_trylock(preview_register_t& p){return TryEnterCriticalSection(&p.cs)!=FALSE;}
#else
inline void am_preview_init(preview_register_t& p){pthread_mutex_init(&p.mutex,nullptr);}
inline void am_preview_destroy(preview_register_t& p){pthread_mutex_destroy(&p.mutex);}
inline void am_preview_lock(preview_register_t& p){pthread_mutex_lock(&p.mutex);}
inline void am_preview_unlock(preview_register_t& p){pthread_mutex_unlock(&p.mutex);}
inline bool am_preview_trylock(preview_register_t& p){return pthread_mutex_trylock(&p.mutex)==0;}
#endif
