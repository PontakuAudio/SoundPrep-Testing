// Assertion failures must fail CI rather than wait for a Windows dialog.
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <cstdlib>
#include <crtdbg.h>
namespace {
struct Runtime {
  Runtime(){
    SetErrorMode(SEM_FAILCRITICALERRORS|SEM_NOGPFAULTERRORBOX|SEM_NOOPENFILEERRORBOX);
    _set_error_mode(_OUT_TO_STDERR);
    _set_abort_behavior(0,_WRITE_ABORT_MSG|_CALL_REPORTFAULT);
  }
} runtime;
}
