// ----------------------------------------------------------------------- //
//
// MODULE  : render_dxt.cpp
//
// PURPOSE : See render_dxt.h. The block layouts are the D3D9 / S3TC ones the
//           DTX files carry (DXT1, DXT3, DXT5), all little-endian.
//
// ----------------------------------------------------------------------- //

#include "render_dxt.h"

#include <string.h>

size_t RenderDXT_BlockBytes(ERenderDXT eFmt)
{
	return (eFmt == RENDER_DXT1) ? 8 : 16;
}

// RGB565 -> 8 bits per channel, by bit replication (what GPUs do).
static inline void dxt_Expand565(uint16_t c, int &r, int &g, int &b)
{
	r = (c >> 11) & 0x1F;  r = (r << 3) | (r >> 2);
	g = (c >> 5)  & 0x3F;  g = (g << 2) | (g >> 4);
	b =  c        & 0x1F;  b = (b << 3) | (b >> 2);
}

// One 8-byte colour block -> 16 BGRA pixels (out[16][4]).
// bFourColour: the DXT3/DXT5 rule -- their colour block is always the
// four-colour form, whatever the order of the two endpoints. Only DXT1 uses the
// three-colour + transparent form when c0 <= c1.
static void dxt_DecodeColour(const uint8_t *p, bool bFourColour, uint8_t out[16][4])
{
	const uint16_t c0 = (uint16_t)(p[0] | (p[1] << 8));
	const uint16_t c1 = (uint16_t)(p[2] | (p[3] << 8));

	int r0, g0, b0, r1, g1, b1;
	dxt_Expand565(c0, r0, g0, b0);
	dxt_Expand565(c1, r1, g1, b1);

	uint8_t pal[4][4];   // B, G, R, A
	pal[0][0] = (uint8_t)b0; pal[0][1] = (uint8_t)g0; pal[0][2] = (uint8_t)r0; pal[0][3] = 255;
	pal[1][0] = (uint8_t)b1; pal[1][1] = (uint8_t)g1; pal[1][2] = (uint8_t)r1; pal[1][3] = 255;

	if (bFourColour || c0 > c1)
	{
		pal[2][0] = (uint8_t)((2 * b0 + b1) / 3);
		pal[2][1] = (uint8_t)((2 * g0 + g1) / 3);
		pal[2][2] = (uint8_t)((2 * r0 + r1) / 3);
		pal[2][3] = 255;
		pal[3][0] = (uint8_t)((b0 + 2 * b1) / 3);
		pal[3][1] = (uint8_t)((g0 + 2 * g1) / 3);
		pal[3][2] = (uint8_t)((r0 + 2 * r1) / 3);
		pal[3][3] = 255;
	}
	else
	{
		pal[2][0] = (uint8_t)((b0 + b1) / 2);
		pal[2][1] = (uint8_t)((g0 + g1) / 2);
		pal[2][2] = (uint8_t)((r0 + r1) / 2);
		pal[2][3] = 255;
		pal[3][0] = pal[3][1] = pal[3][2] = pal[3][3] = 0;   // transparent black
	}

	const uint32_t idx = (uint32_t)p[4] | ((uint32_t)p[5] << 8)
	                   | ((uint32_t)p[6] << 16) | ((uint32_t)p[7] << 24);
	for (int i = 0; i < 16; ++i)
		memcpy(out[i], pal[(idx >> (2 * i)) & 3], 4);
}

// DXT3: 64 bits of explicit 4-bit alpha, pixel 0 in the low nibble.
static void dxt_DecodeAlpha3(const uint8_t *p, uint8_t out[16][4])
{
	for (int i = 0; i < 16; ++i)
	{
		const int a = (p[i >> 1] >> ((i & 1) * 4)) & 0xF;
		out[i][3] = (uint8_t)(a * 17);
	}
}

// DXT5: two 8-bit endpoints and sixteen 3-bit indices (48 bits).
static void dxt_DecodeAlpha5(const uint8_t *p, uint8_t out[16][4])
{
	const int a0 = p[0], a1 = p[1];
	int pal[8];
	pal[0] = a0;
	pal[1] = a1;
	if (a0 > a1)
	{
		for (int i = 1; i < 7; ++i)
			pal[i + 1] = ((7 - i) * a0 + i * a1) / 7;
	}
	else
	{
		for (int i = 1; i < 5; ++i)
			pal[i + 1] = ((5 - i) * a0 + i * a1) / 5;
		pal[6] = 0;
		pal[7] = 255;
	}

	uint64_t bits = 0;
	for (int i = 0; i < 6; ++i)
		bits |= (uint64_t)p[2 + i] << (8 * i);
	for (int i = 0; i < 16; ++i)
		out[i][3] = (uint8_t)pal[(bits >> (3 * i)) & 7];
}

void RenderDXT_Decode(ERenderDXT eFmt, const uint8_t *pSrc,
                      uint32_t nWidth, uint32_t nHeight, uint8_t *pDst)
{
	const uint32_t nBlocksW = (nWidth  + 3) / 4;
	const uint32_t nBlocksH = (nHeight + 3) / 4;
	const size_t   nBlock   = RenderDXT_BlockBytes(eFmt);

	uint8_t px[16][4];
	for (uint32_t by = 0; by < nBlocksH; ++by)
	{
		for (uint32_t bx = 0; bx < nBlocksW; ++bx)
		{
			const uint8_t *p = pSrc + ((size_t)by * nBlocksW + bx) * nBlock;
			switch (eFmt)
			{
				case RENDER_DXT1:
					dxt_DecodeColour(p, false, px);
					break;
				case RENDER_DXT3:
					dxt_DecodeColour(p + 8, true, px);
					dxt_DecodeAlpha3(p, px);
					break;
				case RENDER_DXT5:
					dxt_DecodeColour(p + 8, true, px);
					dxt_DecodeAlpha5(p, px);
					break;
			}

			for (uint32_t y = 0; y < 4; ++y)
			{
				const uint32_t py = by * 4 + y;
				if (py >= nHeight)
					break;
				for (uint32_t x = 0; x < 4; ++x)
				{
					const uint32_t pxX = bx * 4 + x;
					if (pxX >= nWidth)
						break;
					memcpy(pDst + ((size_t)py * nWidth + pxX) * 4, px[y * 4 + x], 4);
				}
			}
		}
	}
}
