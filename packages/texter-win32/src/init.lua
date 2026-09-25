-- Uniscribe and GDI: the text windows already has.
--
--   local texter = require("texter-win32")
--
-- Two libraries that every windows has and no program ships: Uniscribe turns a string into glyphs
-- -- joining, reordering, and arranging a line of two directions, which is what `ScriptItemize`,
-- `ScriptShape` and `ScriptPlace` are -- and GDI draws those glyphs and measures the font they are
-- drawn from.
--
-- It has been run on a windows machine, and what is written below is what that machine answered
-- with. Two things about it were worked out from the machine rather than read off the
-- documentation: the coverage a glyph comes back with counts to sixty-four, which is what an
-- atlas is scaled from, and the matrix a glyph is asked for is four sixteen point sixteen longs
-- rather than something shorter -- nothing about the wrong size of it is refused loudly, and every
-- glyph in the font comes back as an error that reads like the glyph or the buffer being at fault.
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

local gdi = ffi.load("gdi32")
local kernel = ffi.load("kernel32")
local usp = ffi.load("usp10")

-- What GDI is handed is a family, and a file is what an app has: the family is read out of the
-- file's own name table, which is `texter-common`'s because every platform needs the same thing.
---@class texter.win32.Face

local win32 = {}

---@class texter.win32.Face
---@field path string
---@field index number
---@field family string
---@field context HDC # A device context with the font selected into it, kept
---@field font HANDLE
---@field height number
---@field stack ffi.cdata* # Where a glyph's ink is copied, kept
---@field room number # How many pixels that stack holds, grown as glyphs need
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

-- What Uniscribe answers the counts of, made once, and the cache it keeps a shaped font in. The
-- cache is not the caller's to share: what it holds is one font in one device context, and a cache
-- made for one font that is handed a run of another answers with a shape that is not the font's --
-- which is why what it is made for is remembered, and why another font gives it back first.
local used = ffi.new("int[1]")
local shaped = ffi.new("int[1]")
local cached = ffi.new("SCRIPT_CACHE[1]")
local cachedFor = nil

--- The cache of one device context, given back when the context being shaped in is not the one it
--- was made for.
---@param context HDC
---@return SCRIPT_CACHE*
local function cacheFor(context)
	if cachedFor ~= context then
		if cachedFor ~= nil then
			usp.ScriptFreeCache(cached)

			cached[0] = nil
		end

		cachedFor = context
	end

	return cached
end

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

	local face = setmetatable({
		path = path,
		index = index or 0,
		family = family,
		context = gdi.CreateCompatibleDC(nil),
		font = nil,
		height = 0,
		stack = ffi.new("unsigned char[?]", 1 << 16),
		room = 1 << 16,
		distant = {},
	}, { __index = Face })

	-- A font of the family is made at a size, and a device context with none selected in it is a
	-- context nothing is measured in: the size a caller asks for is what makes the first one.
	face:size(12)

	return face
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

	self.font, self.height = made, pixelHeight
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

	gdi.GetCharABCWidthsW(self.context, codepoint, codepoint, sizes)

	return tonumber(sizes[0].abcA + sizes[0].abcB + sizes[0].abcC)
end

---@param glyph number
---@param pixelHeight number
---@return texter.Ink
function Face:inkOf(glyph, pixelHeight)
	self:size(pixelHeight)

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
			local cache = cacheFor(face.context)
			local result = usp.ScriptShape(face.context, cache, characters + at, length, length * 3 + 16, analysis,
				out, clusters, attributes, shaped)

			assert(result == 0 or result == E_GLYPH_MISSING, "Uniscribe could not shape a run of " .. text)

			local abc = ffi.new("ABC[1]")

			assert(usp.ScriptPlace(face.context, cache, out, shaped[0], attributes, analysis, advances, offsets, abc) == 0,
				"Uniscribe could not place a run of " .. text)

			if rtl and logical then
				-- What Uniscribe shapes into is the order the glyphs are drawn in, from the left, which
				-- is what a renderer wants and what every other platform answers -- unless it was asked
				-- for the logical order, which is the order the characters are in, and then a right to
				-- left run is placed backwards from the right end of it.
				local total = 0

				for step = 0, shaped[0] - 1 do
					total = total + advances[step]
				end

				local trailing = total

				for step = shaped[0] - 1, 0, -1 do
					trailing = trailing - advances[step]

					glyphs[#glyphs + 1] = {
						glyph = out[step],
						cluster = byteOf(clusters[step] + at),
						x = x + trailing + offsets[step].du,
						y = -offsets[step].dv,
						advance = advances[step],
					}
				end

				x = x + total
			else
				for step = 0, shaped[0] - 1 do
					glyphs[#glyphs + 1] = {
						glyph = out[step],
						cluster = byteOf(clusters[step] + at),
						x = x + offsets[step].du,
						y = -offsets[step].dv,
						advance = advances[step],
					}

					x = x + advances[step]
				end
			end
		end
	end

	-- Uniscribe places the items in the order they are drawn in, so the line is as it came back:
	-- what a line reads as is what the first item was analyzed as.
	local rtl = used[0] > 0 and math.floor(items[0].a.flags / RIGHT_TO_LEFT) % 2 == 1 or false

	return { glyphs = glyphs, width = x, rtl = rtl, runs = runs, text = text }
end

---@param face texter.win32.Face
---@param glyph number
---@param pixelHeight number
---@return texter.Ink
function win32.ink(face, glyph, pixelHeight)
	return face:inkOf(glyph, pixelHeight)
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

-- What a screen packs a glyph from and shapes a line with: the faces this module opens, in the shape
-- `wonderland` asks a reader of fonts for -- see `wonderland.font.Provider`. The faces are what an
-- atlas needs; `shape` and `ink` are here because a screen that draws text shapes its lines and
-- packs the glyphs a line came to, which are glyphs of a font rather than characters of a string.
---@type wonderland.font.Provider
win32.provider = {
	open = function(path, index)
		return win32.face(path, index)
	end,
	shape = function(face, text, pixelHeight, opts)
		return win32.shape(face, text, pixelHeight, opts)
	end,
	ink = function(face, glyph, pixelHeight)
		return win32.ink(face, glyph, pixelHeight)
	end,
}

return win32
