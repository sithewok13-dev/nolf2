// ----------------------------------------------------------------------- //
//
// MODULE  : ios_paths.cpp
//
// PURPOSE : iOS only: file names that ignore case, as they do on a Mac.
//
//           The iPhone's file system is case-sensitive; a Mac's is not. The
//           game was written for Windows and asks for its files in whatever
//           case the code happens to use ("Profiles\default.prf",
//           "autoexec.cfg"), while the player's retail copy may be in upper
//           case (PROFILES\DEFAULT.PRF). macbuild/compat/msvc_crt_compat.h
//           routes fopen / stat / opendir / mkdir here on iOS (LT_IOS). Each
//           tries the exact name first -- the common case costs nothing extra
//           -- and only when that is not found looks the name up again, folder
//           by folder, ignoring case.
//
// ----------------------------------------------------------------------- //

#include <dirent.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <strings.h>
#include <sys/stat.h>
#include <sys/types.h>

#include <string>
#include <vector>

// The compat header (force-included) turns these into calls to the functions
// below; here they must be the real ones.
#undef fopen
#undef stat
#undef opendir
#undef mkdir

extern "C" {
FILE *ltios_fopen(const char *pPath, const char *pMode);
int   ltios_stat(const char *pPath, struct stat *pBuf);
DIR  *ltios_opendir(const char *pPath);
int   ltios_mkdir(const char *pPath, mode_t nMode);
void  ltios_ResolvePath(const char *pPath, char *pOut, size_t nOut);
}

namespace
{

bool ios_Exists(const std::string &sPath)
{
	struct stat st;
	return ::stat(sPath.c_str(), &st) == 0;
}

// sDir/sName, sDir being "" for the current directory.
std::string ios_Join(const std::string &sDir, const std::string &sName)
{
	if (sDir.empty())
		return sName;
	if (sDir[sDir.size() - 1] == '/')
		return sDir + sName;
	return sDir + "/" + sName;
}

// The name in sDir that equals sName ignoring case, or "" if none.
std::string ios_FindNoCase(const std::string &sDir, const std::string &sName)
{
	DIR *pDir = ::opendir(sDir.empty() ? "." : sDir.c_str());
	if (!pDir)
		return std::string();
	std::string sHit;
	while (struct dirent *pEnt = readdir(pDir))
	{
		if (strcasecmp(pEnt->d_name, sName.c_str()) == 0)
		{
			sHit = pEnt->d_name;
			break;
		}
	}
	closedir(pDir);
	return sHit;
}

std::string ios_Resolve(const char *pPath)
{
	std::string sIn(pPath ? pPath : "");
	for (size_t i = 0; i < sIn.size(); ++i)
		if (sIn[i] == '\\')
			sIn[i] = '/';
	if (sIn.empty() || ios_Exists(sIn))
		return sIn;

	// Folder by folder: keep each part that exists as written, else take the
	// one that matches ignoring case, else keep it as given (it doesn't exist
	// yet, or doesn't exist at all -- the caller then gets its usual error).
	std::string sOut = (sIn[0] == '/') ? "/" : "";
	bool bFound = true;   // everything so far exists on disk
	size_t nPos = 0;
	while (nPos <= sIn.size())
	{
		size_t nEnd = sIn.find('/', nPos);
		if (nEnd == std::string::npos)
			nEnd = sIn.size();
		std::string sPart = sIn.substr(nPos, nEnd - nPos);
		nPos = nEnd + 1;
		if (sPart.empty())
			continue;

		std::string sNext = ios_Join(sOut, sPart);
		if (bFound && sPart != "." && sPart != ".." && !ios_Exists(sNext))
		{
			std::string sHit = ios_FindNoCase(sOut, sPart);
			if (!sHit.empty())
				sNext = ios_Join(sOut, sHit);
			else
				bFound = false;
		}
		sOut = sNext;
	}
	return sOut;
}

} // anonymous namespace

extern "C" {

void ltios_ResolvePath(const char *pPath, char *pOut, size_t nOut)
{
	if (!pOut || nOut == 0)
		return;
	std::string s = ios_Resolve(pPath);
	strncpy(pOut, s.c_str(), nOut - 1);
	pOut[nOut - 1] = 0;
}

// A '\\' is an ordinary character in a file name on iOS, so a Windows path is
// never tried as written: writing "Profiles\\Player.prf" would otherwise make
// one file of that name next to the Profiles folder instead of one inside it.
static bool ios_HasBackslash(const char *pPath)
{
	return pPath && strchr(pPath, '\\') != NULL;
}

FILE *ltios_fopen(const char *pPath, const char *pMode)
{
	if (ios_HasBackslash(pPath))
		return ::fopen(ios_Resolve(pPath).c_str(), pMode);
	FILE *fp = ::fopen(pPath, pMode);
	if (fp || errno != ENOENT || !pPath)
		return fp;
	std::string s = ios_Resolve(pPath);
	if (s == pPath)
		return NULL;   // errno is still ENOENT
	return ::fopen(s.c_str(), pMode);
}

int ltios_stat(const char *pPath, struct stat *pBuf)
{
	if (ios_HasBackslash(pPath))
		return ::stat(ios_Resolve(pPath).c_str(), pBuf);
	int r = ::stat(pPath, pBuf);
	if (r == 0 || errno != ENOENT || !pPath)
		return r;
	std::string s = ios_Resolve(pPath);
	if (s == pPath)
		return r;
	return ::stat(s.c_str(), pBuf);
}

DIR *ltios_opendir(const char *pPath)
{
	if (ios_HasBackslash(pPath))
		return ::opendir(ios_Resolve(pPath).c_str());
	DIR *p = ::opendir(pPath);
	if (p || errno != ENOENT || !pPath)
		return p;
	std::string s = ios_Resolve(pPath);
	if (s == pPath)
		return NULL;
	return ::opendir(s.c_str());
}

// A folder that already exists under another case counts as existing, so the
// game doesn't make "Save" next to the player's "SAVE" and lose sight of it.
int ltios_mkdir(const char *pPath, mode_t nMode)
{
	if (!pPath)
		return ::mkdir(pPath, nMode);
	std::string s = ios_Resolve(pPath);
	if (s != pPath && ios_Exists(s))
	{
		errno = EEXIST;
		return -1;
	}
	return ::mkdir(s.c_str(), nMode);
}

} // extern "C"
