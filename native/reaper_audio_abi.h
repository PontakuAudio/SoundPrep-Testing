/***************************************
*** REAPER Plug-in API
**
** Copyright (C) 2006-2015, Cockos Incorporated
**
**    This software is provided 'as-is', without any express or implied
**    warranty.  In no event will the authors be held liable for any damages
**    arising from the use of this software.
**
**    Permission is granted to anyone to use this software for any purpose,
**    including commercial applications, and to alter it and redistribute it
**    freely, subject to the following restrictions:
**
**    1. The origin of this software must not be misrepresented; you must not
**       claim that you wrote the original software. If you use this software
**       in a product, an acknowledgment in the product documentation would be
**       appreciated but is not required.
**    2. Altered source versions must be plainly marked as such, and must not be
**       misrepresented as being the original software.
**    3. This notice may not be removed or altered from any source distribution.
**
** Notes: the C++ interfaces used require MSVC on win32, or at least the MSVC-compatible C++ ABI. Sorry, mingw users :(
**
*/

// Altered: audio-only excerpt of Cockos reaper_plugin.h; public ABI, macOS / Windows x64.
// Source: https://github.com/justinfrankel/reaper-sdk/blob/main/sdk/reaper_plugin.h
#pragma once
#include <cstddef>
#ifdef _WIN32
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#else
#include <pthread.h>
using HWND = void*;
#endif
using ReaSample = double;
class MIDI_eventlist;
struct PCM_source_peaktransfer_t;
class ProjectStateContext;
typedef struct _PCM_source_transfer_t
{
  double time_s; // start time of block

  double samplerate; // desired output samplerate and channels
  int nch;

  int length; // desired length in sample(pair)s of output

  ReaSample *samples; // samples filled in (the caller allocates this)
  int samples_out; // updated with number of sample(pair)s actually rendered

  MIDI_eventlist *midi_events;

  double approximate_playback_latency; // 0.0 if not supported
  double absolute_time_s;
  double force_bpm;
} PCM_source_transfer_t;

class PCM_source
{
  public:
    virtual ~PCM_source() { }

    virtual PCM_source *Duplicate()=0;

    virtual bool IsAvailable()=0;
    virtual void SetAvailable(bool /*avail*/) { } // optional, if called with avail=false, close files/etc, and so on
    virtual const char *GetType()=0;
    virtual const char *GetFileName() { return NULL; } // return NULL if no filename (not purely a file)
    virtual bool SetFileName(const char *newfn)=0; // return TRUE if supported, this will only be called when offline

    virtual PCM_source *GetSource() { return NULL; }
    virtual void SetSource(PCM_source* /*src*/) { }
    virtual int GetNumChannels()=0; // return number of channels
    virtual double GetSampleRate()=0; // returns preferred sample rate. if < 1.0 then it is assumed to be silent (or MIDI)
    virtual double GetLength()=0; // length in seconds
    virtual double GetLengthBeats() { return -1.0; } // length in beats if supported
    virtual int GetBitsPerSample() { return 0; } // returns bits/sample, if available. only used for metadata purposes, since everything returns as doubles anyway
    virtual double GetPreferredPosition() { return -1.0; } // not supported returns -1

    virtual int PropertiesWindow(HWND hwndParent)=0;

    virtual void GetSamples(PCM_source_transfer_t *block)=0;
    virtual void GetPeakInfo(PCM_source_peaktransfer_t *block)=0;

    virtual void SaveState(ProjectStateContext *ctx)=0;
    virtual int LoadState(const char *firstline, ProjectStateContext *ctx)=0; // -1 on error


    // these are called by the peaks building UI to build peaks for files.
    virtual void Peaks_Clear(bool deleteFile)=0;
    virtual int PeaksBuild_Begin()=0; // returns nonzero if building is opened, otherwise it may mean building isn't necessary
    virtual int PeaksBuild_Run()=0; // returns nonzero if building should continue
    virtual void PeaksBuild_Finish()=0; // called when done

    virtual int Extended(int /*call*/, void* /*parm1*/, void* /*parm2*/, void* /*parm3*/) { return 0; } // return 0 if unsupported
};

class IReaperPitchShift
{
  public:
    virtual ~IReaperPitchShift() { };
    virtual void set_srate(double srate)=0;
    virtual void set_nch(int nch)=0;
    virtual void set_shift(double shift)=0;
    virtual void set_formant_shift(double shift)=0; // shift can be <0 for "only shift when in formant preserve mode", so that you can use it for effective rate changes etc in that mode
    virtual void set_tempo(double tempo)=0;

    virtual void Reset()=0;  // reset all buffers/latency
    virtual ReaSample *GetBuffer(int size)=0;
    virtual void BufferDone(int input_filled)=0;

    virtual void FlushSamples()=0; // make sure all output is available

    virtual bool IsReset()=0;

    virtual int GetSamples(int requested_output, ReaSample *buffer)=0; // returns number of samplepairs returned

    virtual void SetQualityParameter(int parm)=0; // set to: (mode<<16)+(submode), or -1 for "project default" (default)
    virtual int Extended(int /*call*/, void* /*parm1*/, void* /*parm2*/, void* /*parm3*/) { return 0; } // return 0 if unsupported
};
typedef struct _REAPER_preview_register_t
{
/*
** Note: you must initialize/deinitialize the cs/mutex (depending on OS) manually, and use it if accessing most parameters while the preview is active.
*/

#ifdef _WIN32
  CRITICAL_SECTION cs;
#else
  pthread_mutex_t mutex;
#endif
  PCM_source *src;
  int m_out_chan; // &1024 means mono, low 10 bits are index of first channel
  double curpos;
  bool loop;
  double volume;

  double peakvol[2];
  void *preview_track; // used for track previews, but only if m_out_chan == -1
} preview_register_t;

