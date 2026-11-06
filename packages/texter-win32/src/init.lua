--
--   local texter = require("texter-win32")
--
-- Uses Uniscribe and DirectWrite to shape and rasterize text for Windows.
-- DirectWrite is used if it's available, GDI otherwise.

local ffi = require("ffi")
local sfnt = require("texter-common").sfnt
local utf8 = require("texter-common").utf8

-- An array of a known size, made in one go rather than grown a rehash at a time: what a line is is
-- a table of a glyph each, and LuaJIT makes one of that size where a table does not.
local table_new = require("table.new")

ffi.cdef [[
	typedef unsigned short WCHAR;
	typedef int BOOL;
	typedef unsigned int UINT;
	typedef unsigned long DWORD;
	typedef unsigned short WORD;
	typedef long LONG;
	typedef void *HDC;
	typedef void *HGDIOBJ;
	typedef void *HANDLE;
	typedef intptr_t INT_PTR;

	typedef struct { LONG x, y; } POINT;
	typedef struct { LONG left, top, right, bottom; } RECT;

	typedef struct {
		LONG lfHeight, lfWidth, lfEscapement, lfOrientation, lfWeight;
		unsigned char lfItalic, lfUnderline, lfStrikeOut, lfCharSet, lfOutPrecision, lfClipPrecision,
			lfQuality, lfPitchAndFamily;
		WCHAR lfFaceName[32];
	} LOGFONTW;

	// Windows writes the whole of this structure and does not check the room: a declaration of the
	// first few fields is a buffer overflow on every font that is measured.
	typedef struct {
		LONG tmHeight, tmAscent, tmDescent, tmInternalLeading, tmExternalLeading, tmAveCharWidth;
		LONG tmMaxCharWidth, tmWeight, tmOverhang, tmDigitizedAspectX, tmDigitizedAspectY;
		WCHAR tmFirstChar, tmLastChar, tmDefaultChar, tmBreakChar;
		unsigned char tmItalic, tmUnderlined, tmStruckOut, tmPitchAndFamily, tmCharSet;
	} TEXTMETRICW;

	typedef struct {
		UINT gmBlackBoxX, gmBlackBoxY;
		POINT gmptGlyphOrigin;
		short gmCellIncX, gmCellIncY;
	} GLYPHMETRICS;

	typedef struct { int abcA, abcB, abcC; } ABC;

	// The matrix a glyph outline is transformed by. Its four numbers are `FIXED` -- a long holding
	// sixteen point sixteen -- and not the shorts the field name suggests: one is a whole pixel, a
	// matrix of the wrong size or the wrong scale is what GDI answers a glyph request with
	// GDI_ERROR to, whatever else about the call was right.
	typedef struct {
		LONG eM11, eM12, eM21, eM22;
	} MAT2;
	typedef struct { LONG du, dv; } GOFFSET;

	// What Uniscribe says about a piece of a line. The two bitfield structures are written out as
	// the words they are -- `eScript` is the low ten bits of the first, `fRTL` the eleventh, and
	// the bidi level the low five bits of the second -- and they are four bytes together rather
	// than the four words a field apiece would be. Uniscribe writes items one after another into
	// the room it is given, so an item that is a word too wide is every item after the first read
	// out of the middle of the one before it.
	typedef struct {
		WORD flags;
		WORD state;
	} SCRIPT_ANALYSIS;

	typedef struct {
		int iCharPos;
		SCRIPT_ANALYSIS a;
	} SCRIPT_ITEM;

	typedef struct { WORD justification; } SCRIPT_VISATTR;
	typedef void *SCRIPT_CACHE;

	HANDLE AddFontResourceExW(const WCHAR *path, DWORD flags, void *reserved);
	BOOL RemoveFontResourceExW(const WCHAR *path, DWORD flags, void *reserved);
	HANDLE AddFontMemResourceEx(const void *font, DWORD size, void *reserved, DWORD *count);
	BOOL RemoveFontMemResourceEx(HANDLE handle);
	HGDIOBJ SelectObject(HDC context, HGDIOBJ object);
	HGDIOBJ GetStockObject(int object);
	HDC CreateCompatibleDC(HDC context);
	BOOL DeleteDC(HDC context);
	void *CreateFontIndirectW(const LOGFONTW *description);
	BOOL DeleteObject(HGDIOBJ object);
	BOOL GetTextMetricsW(HDC context, TEXTMETRICW *metrics);
	DWORD GetGlyphOutlineW(HDC context, UINT character, UINT format, GLYPHMETRICS *metrics, DWORD size,
		void *buffer, const void *transform);
	DWORD GetFontData(HDC context, DWORD table, DWORD offset, void *buffer, DWORD size);
	int GetGlyphIndicesW(HDC context, const WCHAR *text, int count, WORD *glyphs, DWORD flags);
	BOOL GetCharABCWidthsW(HDC context, UINT first, UINT last, ABC *sizes);
	int MultiByteToWideChar(UINT page, DWORD flags, const char *text, int length, WCHAR *wide, int room);

	void ScriptFreeCache(SCRIPT_CACHE *cache);
	UINT ScriptItemize(const WCHAR *text, int count, int most, const void *control, const void *state,
		SCRIPT_ITEM *items, int *used);
	UINT ScriptShape(HDC context, SCRIPT_CACHE *cache, const WCHAR *text, int count, int most, SCRIPT_ANALYSIS *analysis,
		WORD *glyphs, WORD *clusters, SCRIPT_VISATTR *attributes, int *shaped);
	UINT ScriptPlace(HDC context, SCRIPT_CACHE *cache, const WORD *glyphs, int count, const SCRIPT_VISATTR *attributes,
		SCRIPT_ANALYSIS *analysis, int *advances, GOFFSET *offsets, ABC *abc);

	// DirectWrite: the newer of the two rasterisers windows has, and the one the rest of windows
	// draws its own text with. What it is reached through is com -- an object is a pointer to a
	// pointer to a table of functions, each of which takes the object as its first argument -- and
	// a call is the number of the table's slot, so every table below is written out in the order
	// the header declares its methods: the slots this file does not call are `void *`, which keeps
	// the ones it does call at the index the header gives them.
	//
	// The order is `dwrite.h`, `dwrite_1.h` and `dwrite_2.h`, where the method a slot holds is
	// written in the header's own `IDWrite*Vtbl` struct; the index is counted from the three
	// methods every com object has. A slot the interface adds as an overload of one before it --
	// `CreateCustomRenderingParams` and `CreateGlyphRunAnalysis` are both declared three times, with
	// more arguments each time -- is given a name of its own here: the field name is only a label for
	// the slot, and two fields of one name in a struct are one field, at the first of the two.
	typedef unsigned int UINT32;
	typedef unsigned char BYTE;
	typedef unsigned long ULONG;
	typedef long HRESULT;

	// A globally unique identifier: four bytes, then two, then two, then eight, little endian.
	typedef struct { unsigned int a; unsigned short b, c; unsigned char d[8]; } IID;

	typedef struct IDWriteFactory2 IDWriteFactory2;
	typedef struct IDWriteGdiInterop IDWriteGdiInterop;
	typedef struct IDWriteFontFace IDWriteFontFace;
	typedef struct IDWriteGlyphRunAnalysis IDWriteGlyphRunAnalysis;

	typedef struct { float m11, m12, m21, m22, dx, dy; } DWRITE_MATRIX;
	typedef struct { float advanceOffset, ascenderOffset; } DWRITE_GLYPH_OFFSET;

	// One run of glyphs: what a glyph's bitmap is asked for. The advances are the pen's and not the
	// glyph's here -- one nought, because what is wanted is the picture of one glyph at a place on
	// the baseline rather than a line of them -- and the offsets are nothing, which is what says so.
	typedef struct {
		IDWriteFontFace *fontFace;
		float fontEmSize;
		UINT32 glyphCount;
		const unsigned short *glyphIndices;
		const float *glyphAdvances;
		const DWRITE_GLYPH_OFFSET *glyphOffsets;
		BOOL isSideways;
		UINT32 bidiLevel;
	} DWRITE_GLYPH_RUN;

	typedef struct {
		void *QueryInterface; // 0
		void *AddRef;         // 1
		void *Release;        // 2
		// IDWriteFactory
		void *GetSystemFontCollection;    // 3
		void *CreateCustomFontCollection; // 4
		void *RegisterFontCollectionLoader; // 5
		void *UnregisterFontCollectionLoader; // 6
		void *CreateFontFileReference;    // 7
		void *CreateCustomFontFileReference; // 8
		void *CreateFontFace;             // 9
		void *CreateRenderingParams;      // 10
		void *CreateMonitorRenderingParams; // 11
		void *CreateCustomRenderingParams; // 12
		void *RegisterFontFileLoader;     // 13
		void *UnregisterFontFileLoader;   // 14
		void *CreateTextFormat;           // 15
		void *CreateTypography;           // 16
		HRESULT (*GetGdiInterop)(IDWriteFactory2 *, IDWriteGdiInterop **); // 17
		void *CreateTextLayout;           // 18
		void *CreateGdiCompatibleTextLayout; // 19
		void *CreateEllipsisTrimmingSign; // 20
		void *CreateTextAnalyzer;         // 21
		void *CreateNumberSubstitution;   // 22
		void *CreateGlyphRunAnalysis0;    // 23
		// IDWriteFactory1
		void *GetEudcFontCollection;      // 24
		void *CreateCustomRenderingParams1; // 25
		// IDWriteFactory2
		void *GetSystemFontFallback;      // 26
		void *CreateFontFallbackBuilder;  // 27
		void *TranslateColorGlyphRun;     // 28
		void *CreateCustomRenderingParams2; // 29
		// The other call this file makes: a glyph's coverage as grayscale of its own, at a place on
		// the baseline that may be a fraction of a pixel. Only a factory of 8.1 or later has it.
		HRESULT (*CreateGlyphRunAnalysis)(IDWriteFactory2 *, const DWRITE_GLYPH_RUN *run,
			const DWRITE_MATRIX *transform, int rendering, int measuring, int gridFit, int antialias,
			float x, float y, IDWriteGlyphRunAnalysis **analysis); // 30
	} IDWriteFactory2Vtbl;

	struct IDWriteFactory2 { const IDWriteFactory2Vtbl *vtbl; };

	typedef struct {
		void *QueryInterface; // 0
		void *AddRef;         // 1
		void *Release;        // 2
		void *CreateFontFromLOGFONT;    // 3
		void *ConvertFontToLOGFONT;     // 4
		void *ConvertFontFaceToLOGFONT; // 5
		HRESULT (*CreateFontFaceFromHdc)(IDWriteGdiInterop *, HDC, IDWriteFontFace **); // 6
		void *CreateBitmapRenderTarget; // 7
	} IDWriteGdiInteropVtbl;

	struct IDWriteGdiInterop { const IDWriteGdiInteropVtbl *vtbl; };

	typedef struct {
		void *QueryInterface; // 0
		void *AddRef;         // 1
		ULONG (*Release)(IDWriteFontFace *); // 2
	} IDWriteFontFaceVtbl;

	struct IDWriteFontFace { const IDWriteFontFaceVtbl *vtbl; };

	typedef struct {
		void *QueryInterface; // 0
		void *AddRef;         // 1
		ULONG (*Release)(IDWriteGlyphRunAnalysis *); // 2
		HRESULT (*GetAlphaTextureBounds)(IDWriteGlyphRunAnalysis *, int type, RECT *bounds); // 3
		HRESULT (*CreateAlphaTexture)(IDWriteGlyphRunAnalysis *, int type, const RECT *bounds, BYTE *values,
			UINT32 size); // 4
		void *GetAlphaBlendParams; // 5
	} IDWriteGlyphRunAnalysisVtbl;

	struct IDWriteGlyphRunAnalysis { const IDWriteGlyphRunAnalysisVtbl *vtbl; };

	HRESULT DWriteCreateFactory(UINT type, const IID *iid, void **factory);
]]

-- GGO_GRAY8_BITMAP: the glyph as eight bits of coverage a pixel, which is what an atlas packs. What
-- it hands back counts to sixty-four rather than to two hundred and fifty-six, and is scaled here.
local GGO_GRAY8_BITMAP = 6
local GGO_GLYPH_INDEX = 0x0080
local COVERAGE_STEPS = 64

-- One, in the sixteen point sixteen fixed point a `MAT2` is written in.
local FIXED_ONE = 0x10000

-- Where the bits of what an item was analyzed as sit: the eScript is the low ten and fRTL the
-- eleventh, and the bidi level is the low five bits of the state.
local BIDI_LEVEL = 32
local RIGHT_TO_LEFT = 1024
local LOGICAL_ORDER = 16384

-- What Uniscribe answers with when some of the characters of an item are not in the font: it has
-- shaped the run all the same, and what it put where they were is the font's own missing glyph,
-- which is what a caller is shown rather than an error.
local E_GLYPH_MISSING = 0x80040201

-- FR_PRIVATE: the font is registered for this process alone, which is what a font file an app
-- brought with it is.
local FR_PRIVATE = 0x10

-- The index of the glyph for a character GDI is asked for: the character is a codepoint unless this
-- is asked for, and what is wanted here is the glyph.
local DEFAULT_CHARSET = 1
local OUT_TT_PRECIS = 4
local CLIP_DEFAULT_PRECIS = 0
local ANTIALIASED_QUALITY = 4
local FF_DONTCARE = 0

-- How a glyph is asked of DirectWrite: natural symmetric grayscale, which is a glyph drawn from its
-- outline at eight bits of coverage a pixel with the stems where the font puts them. GDI's
-- grayscale is hinted to the pixel grid and comes back in sixty-five steps, which is coarser than
-- the outline deserves. The grid fit is left at its default rather than turned off, because what
-- makes a font legible at fifteen pixels is the outline being fitted to the grid at all; the
-- fraction of a pixel the pen is at is folded in on top of that, which is what the analysis is
-- asked for at a baseline that is not a whole number of pixels.
local DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC = 5
local DWRITE_MEASURING_MODE_NATURAL = 0
local DWRITE_GRID_FIT_MODE_DEFAULT = 0
local DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE = 1
local DWRITE_TEXTURE_ALIASED_1x1 = 0
local DWRITE_FACTORY_TYPE_SHARED = 0

-- The character height a line is *placed* at, whatever height it is drawn at. GDI hints a font to
-- the pixel grid, and what Uniscribe places a line with at a small size is each glyph's advance
-- rounded to whole pixels, nearly always up: a word of Inter at fifteen pixels comes to two pixels
-- wider than the font says, spread one glyph at a time, which reads as "F ugazi". At this height
-- the rounding is a few thousandths of a pixel once scaled down, which is the font's own spacing --
-- the fractions FreeType and CoreText answer with -- while the ink is still drawn at the size asked.
local DESIGN_HEIGHT = 2048

local gdi = ffi.load("gdi32")
local kernel = ffi.load("kernel32")
local usp = ffi.load("usp10")

-- The DirectWrite library and the factory and interop it made, if any
local direct = { library = nil, factory = nil, interop = nil }

-- Where a call writes the object it made, kept for as long as the module is: a pointer read out of
-- one is the whole handle there is on what windows made.
local madeFactory = ffi.new("void *[1]")
local madeInterop = ffi.new("IDWriteGdiInterop *[1]")

do
	local isLoaded, library = pcall(ffi.load, "dwrite")

	if isLoaded then
		-- IID_IDWriteFactory2, as `dwrite_2.h` spells it: 0439fc60-ca44-4994-8dee-3a9af7b732ec.
		local iid = ffi.new("IID")

		iid.a = 0x0439fc60
		iid.b = 0xca44
		iid.c = 0x4994
		ffi.copy(iid.d,
			ffi.new("unsigned char[8]", 0x8d, 0xee, 0x3a, 0x9a, 0xf7, 0xb7, 0x32, 0xec), 8)

		local isCalled, result = pcall(function()
			return library.DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, iid, madeFactory)
		end)

		if isCalled and result == 0 then
			direct.library, direct.factory = library, ffi.cast("IDWriteFactory2 *", madeFactory[0])

			if direct.factory.vtbl.GetGdiInterop(direct.factory, madeInterop) ~= 0 then
				direct.factory = nil
			else
				direct.interop = madeInterop[0]
			end
		end
	end
end

-- What GDI is handed is a family, and a file is what an app has: the family is read out of the
-- file's own name table, which is `texter-common`'s because every platform needs the same thing.
---@class texter.win32.Face

local win32 = {}

---@class texter.win32.Face
---@field path string
---@field index number
---@field family string
---@field data string? # The font's bytes, where it was registered from memory rather than from `path`
---@field buffer ffi.cdata*? # Those bytes where the system reads them, kept for as long as the face
---@field memory HANDLE? # What AddFontMemResourceEx answered, kept for as long as the face
---@field context HDC # A device context with the font selected into it, kept
---@field font HANDLE
---@field height number
---@field em number # The character height the font selected now was made at: what DirectWrite draws a glyph at
---@field direct ffi.cdata*|false? # The IDWriteFontFace of this family, made once; false where there is none to make
---@field stack ffi.cdata* # Where a glyph's ink is copied, kept
---@field room number # How many pixels that stack holds, grown as glyphs need
---@field cache ffi.cdata* # The SCRIPT_CACHE of the font this face has selected, given back when it changes
---@field design HANDLE? # The same font at the height lines are placed at: see `DESIGN_HEIGHT`
---@field designCache ffi.cdata* # The SCRIPT_CACHE of that one
---@field designScale number # What a distance at that height is at the height asked for
---@field distant table<number, number> # What a character outside the basic plane came to, kept
local Face = {}

---@return boolean
function win32.available()
	return true
end

---@return string?
function win32.why()
	return nil
end

---@param text string
---@return WCHAR*, number
local function wide(text)
	local buffer = ffi.new("WCHAR[?]", #text + 1)

	return buffer, kernel.MultiByteToWideChar(65001, 0, text, #text, buffer, #text + 1)
end

-- What a run is cut into before it is shaped: the stretches of it that are one cluster of a
-- character outside the basic plane each, and the stretches of the basic plane between them.
local from, to = {}, {}

--- Whether a unit is the first half of a character outside the basic plane, and whether the unit
--- after it is the second half.
---@param units ffi.cdata*
---@param at number
---@return boolean
local function aPair(units, at)
	local high = units[at] or 0
	local low = units[at + 1] or 0

	return high >= 0xD800 and high <= 0xDBFF and low >= 0xDC00 and low <= 0xDFFF
end

--- Cuts a run of units into what is shaped one at a time, which is the whole of it unless it holds
--- a character outside the basic plane.
---
--- What is written after such a character is part of the picture of it rather than a character of
--- its own -- the joiner that adds another, the selector that says whether it is drawn as a picture
--- or as a character, the modifier that changes the colour of a person -- and what is cut is a
--- character with all of that.
---@param units ffi.cdata*
---@param first number
---@param last number
---@return number count
local function cutInto(units, first, last)
	local at, count, open = first, 0, nil

	while at < last do
		if aPair(units, at) then
			if open ~= nil then
				count = count + 1
				from[count], to[count] = open, at
				open = nil
			end

			local after = at + 2

			while after < last do
				local unit = units[after]

				if unit == 0x200D then
					-- A joiner and what it joins, which is one more picture.
					after = after + (aPair(units, after + 1) and 3 or 2)
				elseif unit == 0xFE0E or unit == 0xFE0F or (unit >= 0x1F3FB and unit <= 0x1F3FF) then
					after = after + 1
				else
					break
				end
			end

			after = math.min(after, last)
			count = count + 1
			from[count], to[count] = at, after
			at = after
		else
			open = open or at
			at = at + 1
		end
	end

	if open ~= nil then
		count = count + 1
		from[count], to[count] = open, last
	end

	return count
end

-- What shaping is handed and what it answers with, kept and grown rather than made again: a line is
-- shaped every frame in a screen that rebuilds its view, and six buffers a call are six buffers the
-- collector pays for. What a buffer holds is read before the next call rather than kept.
local room = 0

---@type ffi.cdata*
local items, out, clusters, attributes, advances, offsets = nil, nil, nil, nil, nil, nil

--- A glyph with nothing to draw: a space, and a glyph a font has no picture of, both answer with
--- it. It is one value rather than one a call, because what it says is the same every time and a line
--- of text is mostly spaces.
local NOTHING = { width = 0, height = 0, left = 0, top = 0 }

-- What a glyph's outline is asked for with and what GDI writes it into, made once: a glyph is packed
-- once a frame in a screen that rebuilds its view, and four buffers a glyph are four buffers the
-- collector then has to pay for. None of them is kept: what a caller is handed is the face's own
-- buffer, copied into before the next glyph is asked for.
local rawMetrics = ffi.new("GLYPHMETRICS")
local rawTransform = ffi.new("MAT2", FIXED_ONE, 0, 0, FIXED_ONE)
local rawRoom = 0

---@type ffi.cdata*
local raw = nil

-- What a glyph is asked of DirectWrite with and where the answer is read, made once for the same
-- reason: a run of one glyph, whose advance is nought -- a pen that does not move is a glyph drawn
-- where it was put rather than after itself -- and the box its coverage comes back in. Nothing here
-- changes from glyph to glyph but the font face, the em and the glyph itself, and what is written
-- into the box is the face's own stack, as GDI's bitmap is.
local glyphIndex = ffi.new("unsigned short[1]")
local glyphAdvance = ffi.new("float[1]", 0.0)
local glyphBounds = ffi.new("RECT")
local analysisOut = ffi.new("IDWriteGlyphRunAnalysis *[1]")
local fontFaceOut = ffi.new("IDWriteFontFace *[1]")
local glyphRun = ffi.new("DWRITE_GLYPH_RUN")

glyphRun.glyphCount = 1
glyphRun.glyphIndices = glyphIndex
glyphRun.glyphAdvances = glyphAdvance

-- What Uniscribe answers the counts of, made once. What it keeps of a shaped font is the cache
-- each face holds: what a cache holds is one font *at one size* in one device context, and a
-- cache kept across a font change answers a line of the new size with the metrics of the old
-- one -- see `Face:forget`, which is where it is given back.
local used = ffi.new("int[1]")
local shaped = ffi.new("int[1]")

--- Grows what shaping is handed to hold a line of this many units and a run of this many glyphs.
---@param units number
---@param glyphs number
local function grow(units, glyphs)
	if room >= units and room >= glyphs then
		return
	end

	room = math.max(units, glyphs)
	items = ffi.new("SCRIPT_ITEM[?]", room + 1)
	out = ffi.new("WORD[?]", room * 3 + 16)
	clusters = ffi.new("WORD[?]", room)
	attributes = ffi.new("SCRIPT_VISATTR[?]", room)
	advances = ffi.new("int[?]", room)
	offsets = ffi.new("GOFFSET[?]", room)
end

--- A face of a family GDI has already been given, whether from a file or from memory.
---@param family string
---@param path string
---@param index number?
---@param memory HANDLE?
---@param data string?
---@param buffer ffi.cdata*?
---@return texter.win32.Face
local function fromFamily(family, path, index, memory, data, buffer)
	local face = setmetatable({
		path = path,
		index = index or 0,
		family = family,
		data = data,
		buffer = buffer,
		memory = memory,
		context = gdi.CreateCompatibleDC(nil),
		font = nil,
		height = 0,
		em = 0,
		direct = nil,
		stack = ffi.new("unsigned char[?]", 1 << 16),
		room = 1 << 16,
		cache = ffi.new("SCRIPT_CACHE[1]"),
		design = nil,
		designCache = ffi.new("SCRIPT_CACHE[1]"),
		designScale = 1,
		distant = {},
	}, { __index = Face })

	-- A font of the family is made at a size, and a device context with none selected in it is a
	-- context nothing is measured in: the size a caller asks for is what makes the first one.
	face:size(12)

	return face
end

--- Reads a font file: it is registered with the process, its family is read out of it, and a font
--- of that family is made at the size it is asked for.
---@param path string
---@param index number?
---@return texter.win32.Face? face
---@return string? err
function win32.face(path, index)
	local file = io.open(path, "rb")

	if file == nil then
		return nil, "Could not read " .. path
	end

	local content = file:read("*all")

	file:close()

	local family = sfnt.family(content)

	if family == nil then
		return nil, path .. " says no family name, so GDI cannot be asked for it"
	end

	local widePath = wide(path)

	if gdi.AddFontResourceExW(widePath, FR_PRIVATE, nil) == 0 then
		return nil, "windows would not take the font " .. path
	end

	return fromFamily(family, path, index)
end

--- Reads a font from its bytes: Windows registers the buffer with the process and the properties
--- are read out of the same bytes, so no file is made.
---@param content string
---@param index number?
---@return texter.win32.Face? face
---@return string? err
function win32.faceBytes(content, index)
	local family = sfnt.family(content)

	if family == nil then
		return nil, "the embedded font says no family name, so GDI cannot be asked for it"
	end

	local buffer = ffi.new("unsigned char[?]", #content)
	ffi.copy(buffer, content, #content)

	local count = ffi.new("DWORD[1]")
	local memory = gdi.AddFontMemResourceEx(buffer, #content, nil, count)

	if memory == nil then
		return nil, "windows would not take the embedded font"
	end

	return fromFamily(family, "<memory>", index, memory, content, buffer)
end

--- One font of this family, at the character height GDI is asked for: a negative height is what
--- says the height is one of a character rather than of a cell.
---@param self texter.win32.Face
---@param height number
---@return HANDLE
function Face:make(height)
	local description = ffi.new("LOGFONTW")
	local wideFamily = wide(self.family)

	description.lfHeight = -height
	description.lfCharSet = DEFAULT_CHARSET
	description.lfOutPrecision = OUT_TT_PRECIS
	description.lfClipPrecision = CLIP_DEFAULT_PRECIS
	description.lfQuality = ANTIALIASED_QUALITY
	description.lfPitchAndFamily = FF_DONTCARE
	ffi.copy(description.lfFaceName, wideFamily, (#self.family + 1) * 2)

	local font = gdi.CreateFontIndirectW(description)

	assert(font ~= nil, "windows would not make a font of " .. self.family)

	gdi.SelectObject(self.context, font)

	return font
end

--- Puts the font at the size a pixel height comes to.
---
--- A pixel height is how tall a *line* of text is, and what GDI is asked for is the height of a
--- character, which is a smaller number the font itself relates: a font of Arial asked for at
--- twenty pixels comes to a line of twenty-three, and one asked for at fifteen comes to seventeen.
---
--- What the font is asked for next is therefore the size that would come to the line wanted, which
--- comes from the two points that are known -- nothing asked for is a line of nought -- and the
--- sizes either side of it are tried as well, because a font is rasterised in whole pixels: there
--- is no size of Arial whose line is exactly twenty, the ones either side come to nineteen and
--- twenty-one, and what stays is the closest of what was tried. Most sizes land exactly on the line
--- asked for; the ones that do not are a pixel out, which is what a rasteriser of whole pixels is.
---@param self texter.win32.Face
---@param pixelHeight number
function Face:size(pixelHeight)
	if self.height == pixelHeight then
		return
	end

	self:forget()

	local wanted = math.max(1, math.floor(pixelHeight + 0.5))
	local made = self:make(wanted)
	local metrics = ffi.new("TEXTMETRICW")

	--- How far the line the font now selected into the context comes to is from what was asked for.
	---@return number
	local function offBy()
		gdi.GetTextMetricsW(self.context, metrics)

		return math.abs(tonumber(metrics.tmAscent) + tonumber(metrics.tmDescent) - wanted)
	end

	local closest, current = offBy(), wanted
	local chosen = wanted

	-- What a font of a size comes to is a line through the sizes, and what is known of it is that a
	-- size of nought is a line of nought and that the size just asked for came to the line measured.
	local guess = math.max(1, math.floor(wanted * wanted / math.max(closest + wanted, 1) + 0.5))

	for _, request in ipairs({ guess, guess - 1, guess + 1 }) do
		if request >= 1 and request ~= wanted then
			-- The font just made is selected into the context and the one before it is given back:
			-- deleting a font that a context still has selected is a context that fails on
			-- everything asked of it afterwards, in ways that look like the font being wrong.
			local next_ = self:make(request)

			gdi.DeleteObject(made)
			made, current = next_, request

			local off = offBy()

			if off < closest then
				closest, chosen = off, request
			end
		end
	end

	-- What is selected now is the last size tried and not the closest one: that one is made again,
	-- and what was selected is given back the same way round as everything else here.
	if chosen ~= current then
		local final = self:make(chosen)

		gdi.DeleteObject(made)
		made = final
	end

	if self.font ~= nil then
		gdi.DeleteObject(self.font)
	end

	-- The font lines are placed with, at a height its hinting no longer moves anything: made, then
	-- the font drawn with selected again, and the one it replaces given back once nothing has it.
	local designHeight = math.max(chosen, DESIGN_HEIGHT)
	local design = self:make(designHeight)

	gdi.SelectObject(self.context, made)

	if self.design ~= nil then
		gdi.DeleteObject(self.design)
	end

	self.font, self.height = made, pixelHeight
	self.design, self.designScale = design, chosen / designHeight

	-- The height GDI was asked for is the font's em in pixels, and an em is what DirectWrite draws a
	-- glyph at: what it is handed is this, rather than the height of a line, which is what a caller
	-- of this asks for.
	self.em = chosen
end

--- What Uniscribe has kept of the font this face had selected, given back.
---
--- A cache is Uniscribe's, and what it holds is one font at one size in one device context: a cache
--- filled at one size and handed a line of another answers with the *first* size's advances rather
--- than the new size's. A face is one file at every size it is read at -- what keeps a screen from
--- reading a font again for every size on it -- so a screen with a heading and a paragraph on it was
--- drawing every line after the first at the spacing of the size the first line was shaped at: the
--- letters of everything else ran together or stood apart, whichever way the size went, while the
--- ink of each of them was the size it was asked for.
---
--- What it costs is the cache of the size being left behind, which is what Uniscribe documents for a
--- font change, and what a screen pays once for each time it moves from one size to another.
---@param self texter.win32.Face
function Face:forget()
	for _, cache in ipairs({ self.cache, self.designCache }) do
		if cache ~= nil and cache[0] ~= nil then
			usp.ScriptFreeCache(cache)

			cache[0] = nil
		end
	end
end

---@param codepoint number
---@return boolean
function Face:hasGlyph(codepoint)
	-- GDI answers with the missing glyph -- index nought -- for a character it has not got.
	return self:glyphFor(codepoint) ~= 0
end

--- The glyph a codepoint is in this font, or nought where it is not one of its own.
---
--- GDI's character map is a map of UTF-16 units and has no idea that a surrogate pair is one
--- character, so a character outside the basic plane -- which every emoji is -- is a pair of units
--- that maps to nothing there: what knows the pair is one character is the shaper, and what is asked
--- about a character of those is the shaper, which is why an emoji is a glyph here at all. What it
--- costs is a line of one character shaped, which is what is kept afterwards: a screen asks about
--- the same emoji over and over.
---@param codepoint number
---@return number
function Face:glyphFor(codepoint)
	if codepoint >= 0x10000 then
		local known = self.distant[codepoint]

		if known ~= nil then
			return known
		end

		local line = win32.shape(self, utf8.encode(codepoint), self.height > 0 and self.height or 16)
		local glyph = #line.glyphs > 0 and line.glyphs[1].glyph or 0

		self.distant[codepoint] = glyph

		return glyph
	end

	local glyphs = ffi.new("WORD[1]")
	local characters = ffi.new("WCHAR[1]", codepoint)

	if gdi.GetGlyphIndicesW(self.context, characters, 1, glyphs, GGO_GLYPH_INDEX) == -1 then
		return 0
	end

	return glyphs[0]
end

---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function Face:metrics(pixelHeight)
	self:size(pixelHeight)

	local metrics = ffi.new("TEXTMETRICW")

	gdi.GetTextMetricsW(self.context, metrics)

	return tonumber(metrics.tmAscent), -tonumber(metrics.tmDescent), tonumber(metrics.tmExternalLeading)
end

---@param codepoint number
---@param pixelHeight number
---@return number
function Face:advance(codepoint, pixelHeight)
	self:size(pixelHeight)

	local sizes = ffi.new("ABC[1]")

	-- Measured in the font lines are placed with, for the same reason a line is: see `DESIGN_HEIGHT`.
	gdi.SelectObject(self.context, self.design)
	gdi.GetCharABCWidthsW(self.context, codepoint, codepoint, sizes)
	gdi.SelectObject(self.context, self.font)

	return tonumber(sizes[0].abcA + sizes[0].abcB + sizes[0].abcC) * self.designScale
end

--- The DirectWrite face of this family, made the first time a glyph is asked for and kept, or
--- nothing where there is none to make.
---
--- A face is a typeface and not a size -- what is drawn at a size is a run of glyphs whose em is
--- that size -- so one of them answers every size this face is asked for. What it is made from is
--- the device context this face keeps with its font selected into it, which is what makes a font an
--- app brought with it, registered from its bytes, answer the same way a font of the system's does.
---@param self texter.win32.Face
---@return ffi.cdata*?
function Face:directFace()
	if self.direct ~= nil then
		return self.direct or nil
	end

	if direct.factory == nil then
		self.direct = false

		return nil
	end

	if direct.interop.vtbl.CreateFontFaceFromHdc(direct.interop, self.context, fontFaceOut) ~= 0 then
		self.direct = false

		return nil
	end

	self.direct = fontFaceOut[0]

	return self.direct
end

--- A glyph as DirectWrite draws it, its origin at a fraction of a pixel to the right of the pen.
---
--- What a glyph is drawn from is its outline, rasterised where the pen is rather than resampled from
--- a whole pixel afterwards: a stem that sits at half a pixel covers the two pixels either side of
--- it in unequal amounts, which is what a caller packing an atlas from this and drawing it at whole
--- pixels needs. The box comes back in whole pixels from the pen and the baseline, which is the
--- same convention GDI's ink is in; the fraction moves the coverage inside the box, and grows it a
--- pixel where the outline crosses into one the glyph at a whole pixel did not reach.
---
--- What is asked for is natural symmetric grayscale, which is how windows draws its own text: eight
--- bits of coverage a pixel with the outline's own weight, rather than GDI's sixty-five hinted
--- steps. What it costs is one analysis a glyph, which is what GDI's outline was.
---@param self texter.win32.Face
---@param dwriteFace ffi.cdata* # The IDWriteFontFace of this face
---@param glyph number
---@param offset number # How far right of the pen the glyph's origin is, in pixels, from nought to one
---@return texter.Ink? ink # Nothing where DirectWrite answered nothing at all
function Face:drawn(dwriteFace, glyph, offset)
	glyphRun.fontFace = dwriteFace
	glyphRun.fontEmSize = self.em
	glyphIndex[0] = glyph

	local result = direct.factory.vtbl.CreateGlyphRunAnalysis(direct.factory, glyphRun, nil,
		DWRITE_RENDERING_MODE_NATURAL_SYMMETRIC, DWRITE_MEASURING_MODE_NATURAL, DWRITE_GRID_FIT_MODE_DEFAULT,
		DWRITE_TEXT_ANTIALIAS_MODE_GRAYSCALE, offset, 0.0, analysisOut)

	if result ~= 0 then
		return nil
	end

	local analysis = analysisOut[0]

	if analysis.vtbl.GetAlphaTextureBounds(analysis, DWRITE_TEXTURE_ALIASED_1x1, glyphBounds) ~= 0 then
		analysis.vtbl.Release(analysis)

		return nil
	end

	local left, top = tonumber(glyphBounds.left), tonumber(glyphBounds.top)
	local width, height = tonumber(glyphBounds.right) - left, tonumber(glyphBounds.bottom) - top

	-- A space, and a glyph a font has no picture of, are a box of nought wide.
	if width <= 0 or height <= 0 then
		analysis.vtbl.Release(analysis)

		return NOTHING
	end

	local count = width * height

	-- A glyph is as much room as its own box, the same as the GDI path: a large size of a wide
	-- glyph is more than the room a font was opened with.
	if count > self.room then
		self.room = count
		self.stack = ffi.new("unsigned char[?]", self.room)
	end

	local stack = self.stack

	-- The coverage is one byte a pixel with no padding, which is what an atlas packs and what an
	-- aliased texture of one by one is: the face's own stack is what it is written into.
	if analysis.vtbl.CreateAlphaTexture(analysis, DWRITE_TEXTURE_ALIASED_1x1, glyphBounds, stack, count) ~= 0 then
		analysis.vtbl.Release(analysis)

		return nil
	end

	analysis.vtbl.Release(analysis)

	return { width = width, height = height, left = left, top = top, pixels = stack }
end

--- A glyph as GDI draws it, which is what a machine without this DirectWrite is left with.
---
--- What GDI hands back is hinted to the pixel grid and counts to sixty-four steps of coverage, which
--- is coarser than the eight bits a pixel holds. The fraction of the pen is not something it can be
--- asked about: a glyph is drawn at the whole pixel it is at.
---@param self texter.win32.Face
---@param glyph number
---@return texter.Ink
function Face:hinted(glyph)
	local metrics = rawMetrics
	local transform = rawTransform
	local size = gdi.GetGlyphOutlineW(self.context, glyph, GGO_GRAY8_BITMAP + GGO_GLYPH_INDEX, metrics, 0, nil,
		transform)

	if size == 0xFFFFFFFF or size == 0 then
		return NOTHING
	end

	-- What GDI pads its rows to is four bytes, whatever the glyph is wide.
	local stride = math.floor((metrics.gmBlackBoxX + 3) / 4) * 4

	if size > rawRoom then
		rawRoom = size
		raw = ffi.new("unsigned char[?]", rawRoom)
	end

	local buffer = raw

	gdi.GetGlyphOutlineW(self.context, glyph, GGO_GRAY8_BITMAP + GGO_GLYPH_INDEX, metrics, size, buffer, transform)

	local stack = self.stack

	local width, height = tonumber(metrics.gmBlackBoxX), tonumber(metrics.gmBlackBoxY)

	-- A glyph is as much room as its own box: a large size of a wide glyph is more than the room a
	-- font was opened with, and what is short of it is written past the end of it.
	if width * height > self.room then
		self.room = width * height
		self.stack = ffi.new("unsigned char[?]", self.room)
		stack = self.stack
	end

	-- What GDI hands back is a bitmap whose first row is the *first* one of the glyph -- whatever it
	-- is drawn as is what is written -- and what an atlas packs is a glyph from the top down, which
	-- is the same thing. A row is padded to four bytes, whatever the glyph is wide, and it is the
	-- glyph's own rows that are read rather than the padding.
	for row = 0, height - 1 do
		local from = buffer + row * stride

		for column = 0, width - 1 do
			-- Sixty-four steps of coverage rather than the two hundred and fifty-six a pixel holds.
			stack[row * width + column] = math.floor((from[column] * 255 + 32) / COVERAGE_STEPS)
		end
	end

	return {
		width = tonumber(metrics.gmBlackBoxX),
		height = tonumber(metrics.gmBlackBoxY),
		left = tonumber(metrics.gmptGlyphOrigin.x),
		top = -tonumber(metrics.gmptGlyphOrigin.y),
		pixels = stack,
	}
end

--- The ink of a glyph, drawn where the pen is.
---
--- The pen's place may be a fraction of a pixel -- a line laid out with the font's own advances
--- leaves glyphs between pixels -- and what a glyph drawn there is, is one rasterised at that place
--- rather than one drawn at a pixel and moved: `offset` is that fraction, and DirectWrite is what
--- draws it. Where there is no DirectWrite -- or where it would not draw a glyph at all -- what is
--- answered is GDI's, and the fraction is dropped: a glyph is drawn at the pixel it starts at.
---@param self texter.win32.Face
---@param glyph number
---@param pixelHeight number
---@param offset number?
---@return texter.Ink
function Face:inkOf(glyph, pixelHeight, offset)
	self:size(pixelHeight)

	local dwriteFace = self:directFace()

	if dwriteFace ~= nil then
		local ink = self:drawn(dwriteFace, glyph, offset or 0)

		if ink ~= nil then
			return ink
		end
	end

	return self:hinted(glyph)
end

---@param ink texter.Ink
function Face:freeInk(_ink)
end

---@param codepoint number
---@param pixelHeight number
---@return texter.Ink
function Face:ink(codepoint, pixelHeight)
	self:size(pixelHeight)

	return self:inkOf(self:glyphFor(codepoint), pixelHeight)
end

--- Shapes a line: Uniscribe cuts it into items -- one direction and one script each, by the bidi
--- algorithm -- and shapes each item into the glyphs it is drawn from.
---@param face texter.win32.Face
---@param text string
---@param pixelHeight number
---@return texter.Line
function win32.shape(face, text, pixelHeight, _opts)
	face:size(pixelHeight)

	local wide = utf8.units(text)
	local characters, bytes, count = wide.units, wide.offsets, wide.count

	-- A line of nothing is a line of no glyphs and not a call to Uniscribe: what it makes of an
	-- empty string is an argument it refuses, and a caller that passes one is asking for nothing to
	-- be drawn rather than for an error.
	if count == 0 then
		return { glyphs = {}, width = 0, rtl = false, runs = {}, text = text }
	end

	-- What a run can come to is more glyphs than units, and Uniscribe is given room for three of
	-- them a unit: what it answers with is placed into buffers that hold as many as it was offered.
	grow(count, count * 3 + 16)

	assert(usp.ScriptItemize(characters, count, count + 1, nil, nil, items, used) == 0,
		"Uniscribe could not arrange " .. text)

	-- What Uniscribe hands back a glyph's cluster as is the unit of the line it came from, and what
	-- a caller is told is the byte of the line, which is a different number for everything that is
	-- not one byte a character.
	---@param unit number
	---@return number
	local function byteOf(unit)
		local at = unit >= 0 and bytes[unit] or nil

		return (at or (#text + 1)) - 1
	end

	local glyphs, runs, x = table_new(string.len(text) * 2, 0), {}, 0.0

	for index = 0, used[0] - 1 do
		local item = items[index]
		local analysis = ffi.new("SCRIPT_ANALYSIS")

		ffi.copy(analysis, item.a, ffi.sizeof("SCRIPT_ANALYSIS"))

		local first = item.iCharPos
		local last = (index < used[0] - 1) and items[index + 1].iCharPos or count
		local flags = item.a.flags
		local rtl = math.floor(flags / RIGHT_TO_LEFT) % 2 == 1
		local logical = math.floor(flags / LOGICAL_ORDER) % 2 == 1
		local level = item.a.state % BIDI_LEVEL

		runs[#runs + 1] = { first = first + 1, last = last, rtl = rtl, level = level }

		-- What a run is shaped as is the whole of it, unless it holds a character outside the basic
		-- plane: Uniscribe counts a line in units and answers a glyph's cluster as the unit of the
		-- line it came from, and what it says of a surrogate pair is not that -- two emoji come back
		-- as two glyphs that both came from the first character of the run -- so each of those is
		-- shaped where it is, and what comes back is clustered where it was shaped.
		local ranges = cutInto(characters, first, last)

		for which = 1, ranges do
			local at, upto = from[which], to[which]
			local length = upto - at
			local cache = assert(face.cache)
			local result = usp.ScriptShape(face.context, cache, characters + at, length, length * 3 + 16, analysis,
				out, clusters, attributes, shaped)

			assert(result == 0 or result == E_GLYPH_MISSING, "Uniscribe could not shape a run of " .. text)

			local abc = ffi.new("ABC[1]")

			-- Placed in the font at the height lines are placed at, and scaled to the height asked for:
			-- the glyphs a run is shaped into are the same at every size, and their advances at the
			-- size drawn are rounded to whole pixels. See `DESIGN_HEIGHT`.
			gdi.SelectObject(face.context, face.design)

			local placed = usp.ScriptPlace(face.context, assert(face.designCache), out, shaped[0], attributes, analysis,
				advances, offsets, abc)

			gdi.SelectObject(face.context, face.font)

			assert(placed == 0, "Uniscribe could not place a run of " .. text)

			local scale = face.designScale

			if rtl and logical then
				-- What Uniscribe shapes into is the order the glyphs are drawn in, from the left, which
				-- is what a renderer wants and what every other platform answers -- unless it was asked
				-- for the logical order, which is the order the characters are in, and then a right to
				-- left run is placed backwards from the right end of it.
				local total = 0

				for step = 0, shaped[0] - 1 do
					total = total + advances[step] * scale
				end

				local trailing = total

				for step = shaped[0] - 1, 0, -1 do
					trailing = trailing - advances[step] * scale

					glyphs[#glyphs + 1] = {
						glyph = out[step],
						cluster = byteOf(clusters[step] + at),
						x = x + trailing + offsets[step].du * scale,
						y = -offsets[step].dv * scale,
						advance = advances[step] * scale,
					}
				end

				x = x + total
			else
				for step = 0, shaped[0] - 1 do
					glyphs[#glyphs + 1] = {
						glyph = out[step],
						cluster = byteOf(clusters[step] + at),
						x = x + offsets[step].du * scale,
						y = -offsets[step].dv * scale,
						advance = advances[step] * scale,
					}

					x = x + advances[step] * scale
				end
			end
		end
	end

	-- Uniscribe places the items in the order they are drawn in, so the line is as it came back:
	-- what a line reads as is what the first item was analyzed as.
	local rtl = used[0] > 0 and math.floor(items[0].a.flags / RIGHT_TO_LEFT) % 2 == 1 or false

	return { glyphs = glyphs, width = x, rtl = rtl, runs = runs, text = text }
end

--- Whether a glyph is drawn at the fraction of a pixel the pen is at. DirectWrite is what can draw
--- one there; GDI draws every glyph at a whole pixel, however it was asked, so a machine whose
--- DirectWrite this is not says no and a caller places glyphs on whole pixels.
win32.subpixel = direct.factory ~= nil

---@param face texter.win32.Face
---@param glyph number
---@param pixelHeight number
---@param opts texter.InkOpts?
---@return texter.Ink
function win32.ink(face, glyph, pixelHeight, opts)
	return face:inkOf(glyph, pixelHeight, opts and opts.offset or 0)
end

---@param face texter.win32.Face
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function win32.metrics(face, pixelHeight)
	return face:metrics(pixelHeight)
end

---@param line texter.Line
---@param byte number
---@return number
function win32.penOf(line, byte)
	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		if glyph.cluster >= byte then
			return pen
		end

		pen = pen + glyph.advance
	end

	return line.width
end

---@param line texter.Line
---@param x number
---@return number
function win32.byteAt(line, x)
	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		if x < pen + glyph.advance / 2 then
			return glyph.cluster
		end

		pen = pen + glyph.advance
	end

	return #line.text + 1
end

-- What a UI library asks a reader of fonts for -- see `wonderland.font.Provider`: the faces, and the
-- shaping a screen that draws its lines as glyphs rather than characters needs.
---@type wonderland.font.Provider
win32.provider = {
	open = function(path, index)
		return win32.face(path, index)
	end,
	openBytes = function(content, index)
		return win32.faceBytes(content, index)
	end,
	shape = function(face, text, pixelHeight, opts)
		return win32.shape(face, text, pixelHeight, opts)
	end,
	ink = function(face, glyph, pixelHeight, opts)
		return win32.ink(face, glyph, pixelHeight, opts)
	end,
	subpixel = win32.subpixel,
}

return win32
