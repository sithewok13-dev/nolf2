// ----------------------------------------------------------------------- //
//
// MODULE  : ios_paths_check.cpp
//
// PURPOSE : A build-time check, no code: after the C and C++ standard headers
//           the engine uses, the iOS file-name redirects from
//           macbuild/compat/msvc_crt_compat.h must still be in force. Some C++
//           libraries' <cstdio> #undef fopen; if Apple's ever does, the build
//           stops here instead of the game silently missing files whose names
//           differ in case (see ios_paths.cpp).
//
// ----------------------------------------------------------------------- //

#include <stdio.h>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <sys/stat.h>
#include <dirent.h>

#if defined(LT_IOS)
#  if !defined(fopen) || !defined(stat) || !defined(opendir) || !defined(mkdir)
#    error "a standard header removed the iOS file-name redirects (see ios_paths.cpp)"
#  endif
#endif
