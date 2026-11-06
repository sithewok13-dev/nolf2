// ----------------------------------------------------------------------- //
//
// MODULE  : render_dxt.h
//
// PURPOSE : CPU decoder for S3TC (DXT1 / DXT3 / DXT5) texture data into
//           8-bit BGRA, the byte order of MTLPixelFormatBGRA8Unorm and of the
//           engine's own BPP_32 textures. BACKEND-NEUTRAL, plain C++.
//
//           Why: Metal on iPhones (and iPads before the M1) has no BC texture
//           formats (MTLDevice.supportsBCTextureCompression is NO), and most of
//           NOLF2's art is DXT. Without this those textures draw untextured.
//
// ----------------------------------------------------------------------- //
#ifndef __RENDER_DXT_H__
#define __RENDER_DXT_H__

#include <stddef.h>
#include <stdint.h>

enum ERenderDXT
{
	RENDER_DXT1 = 1,   // 8 bytes per 4x4 block, colour + 1-bit alpha
	RENDER_DXT3 = 3,   // 16 bytes: explicit 4-bit alpha, then a DXT1 colour block
	RENDER_DXT5 = 5    // 16 bytes: interpolated alpha, then a DXT1 colour block
};

// Bytes in one 4x4 block of the given format.
size_t RenderDXT_BlockBytes(ERenderDXT eFmt);

// Decodes a whole image of nWidth x nHeight pixels (any size; partial edge
// blocks are clipped) from pSrc, which holds ceil(w/4) * ceil(h/4) blocks in
// row order. Writes nWidth * nHeight * 4 bytes to pDst, rows tightly packed,
// each pixel B, G, R, A.
void RenderDXT_Decode(ERenderDXT eFmt, const uint8_t *pSrc,
                      uint32_t nWidth, uint32_t nHeight, uint8_t *pDst);

#endif // __RENDER_DXT_H__
