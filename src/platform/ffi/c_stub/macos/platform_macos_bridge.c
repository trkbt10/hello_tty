// Bridge file to conditionally compile the Objective-C macOS platform adapter.
// On macOS, clang handles .m includes natively.
// On Linux/other platforms, this compiles to nothing (avoids cc1obj requirement).

#if defined(__APPLE__)
#include "platform_macos.m"
#endif
