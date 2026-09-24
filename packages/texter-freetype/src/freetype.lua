-- FreeType, as much of it as drawing a glyph needs.
--
-- The library is the machine's own and is asked for by name rather than shipped: a linux or
-- android desktop has one -- every browser and toolkit on it draws with it -- and a program that
-- brings its own is a program that pays a megabyte for what it already had. What a machine without
-- one is left with is `why()`, which says so.
--
-- Only a face and its ink are here: what a string *is* -- which glyphs, in which order, how far
-- apart -- is HarfBuzz's, in the module beside this one.
local ffi = require("ffi")

ffi.cdef [[
	typedef struct FT_LibraryRec_* FT_Library;
	typedef struct FT_FaceRec_* FT_Face;
	typedef struct FT_GlyphSlotRec_* FT_GlyphSlot;

	typedef struct { long x, y; } FT_Vector;

	typedef struct {
		long width, height;
		long horiBearingX, horiBearingY, horiAdvance;
		long vertBearingX, vertBearingY, vertAdvance;
	} FT_Glyph_Metrics;

	typedef struct {
		void *data;
		void (*finalizer)(void *data);
	} FT_Generic;

	typedef struct { long xMin, yMin, xMax, yMax; } FT_BBox;

	typedef struct {
		unsigned int rows;
		unsigned int width;
		int pitch;
		unsigned char *buffer;
		short num_grays;
		unsigned char pixel_mode;
		unsigned char palette_mode;
		void *palette;
	} FT_Bitmap;

	typedef struct FT_FaceRec_ {
		long num_faces;
		long face_index;
		long face_flags;
		long style_flags;
		long num_glyphs;
		char *family_name;
		char *style_name;
		int num_fixed_sizes;
		void *available_sizes;
		int num_charmaps;
		void *charmaps;
		FT_Generic generic;
		FT_BBox bbox;
		unsigned short units_per_EM;
		short ascender;
		short descender;
		short height;
		short max_advance_width;
		short max_advance_height;
		short underline_position;
		short underline_thickness;
		FT_GlyphSlot glyph;
		void *size;
	} FT_FaceRec;

	typedef struct FT_GlyphSlotRec_ {
		void *library;
		void *face;
		FT_GlyphSlot next;
		unsigned int glyph_index;
		FT_Generic generic;
		FT_Glyph_Metrics metrics;
		long linearHoriAdvance;
		long linearVertAdvance;
		FT_Vector advance;
		unsigned int format;
		FT_Bitmap bitmap;
		int bitmap_left;
		int bitmap_top;
	} FT_GlyphSlotRec;

	int FT_Init_FreeType(FT_Library *library);
	int FT_Done_FreeType(FT_Library library);
	int FT_New_Face(FT_Library library, const char *path, long index, FT_Face *face);
	int FT_Done_Face(FT_Face face);
	int FT_Select_Charmap(FT_Face face, unsigned int encoding);
	unsigned int FT_Get_Char_Index(FT_Face face, unsigned long codepoint);
	int FT_Set_Char_Size(FT_Face face, long width, long height, unsigned int hres, unsigned int vres);
	int FT_Load_Glyph(FT_Face face, unsigned int index, int32_t flags);
	int FT_Load_Sfnt_Table(FT_Face face, unsigned long tag, long offset, unsigned char *buffer, unsigned long *length);
	int FT_Render_Glyph(FT_GlyphSlot slot, unsigned int mode);
]]

--- A face as FreeType holds it, which the language server cannot see.
---@class texter.freetype.ffi.Face: ffi.cdata*
---@field num_glyphs number
---@field units_per_EM number
---@field ascender number
---@field descender number
---@field height number
---@field glyph texter.freetype.ffi.Slot

---@class texter.freetype.ffi.Slot: ffi.cdata*
---@field advance texter.freetype.ffi.Vector
---@field bitmap texter.freetype.ffi.Bitmap
---@field bitmap_left number
---@field bitmap_top number

---@class texter.freetype.ffi.Vector: ffi.cdata*
---@field x number
---@field y number

---@class texter.freetype.ffi.Bitmap: ffi.cdata*
---@field rows number
---@field width number
---@field pitch number
---@field buffer ffi.cdata*
---@field pixel_mode number

-- What the libraries are called, in the order they are tried: a machine with the development
-- package has the first name, and one with only the runtime -- which is what a desktop installs --
-- has the versioned one.
local NAMES = { "freetype", "libfreetype.so.6", "libfreetype.6.dylib", "freetype.dll",

	"freetype-6.dll", "libfreetype-6.dll" }

-- FT_ENC_TAG('u','n','i','c'): the character map a codepoint is looked up in.
local UNICODE = 0x756E6963

-- FT_LOAD_DEFAULT, FT_RENDER_MODE_NORMAL and FT_PIXEL_MODE_GRAY: hinted, drawn as eight bits of
-- coverage a pixel, which is what an atlas packs.
local LOAD_DEFAULT = 0
local RENDER_NORMAL = 0
local PIXEL_MODE_GRAY = 2

-- FT_LOAD_NO_BITMAP: an emoji font's picture is a table of colour bitmaps rather than an outline,
-- and what is asked for here is the outline of a glyph, so a font is not asked for its strikes.
local LOAD_NO_BITMAP = 8

-- How much of one glyph's ink is copied at a time, kept rather than made again: a glyph is a few
-- hundred bytes and the caller copies what it is handed before asking for the next.
local STACK = 1 << 16

local freetype = {}

---@class texter.freetype.Face
---@field path string
---@field index number
---@field handle texter.freetype.ffi.Face
---@field family string? # What the font calls itself, where it says
---@field style string?
---@field private stack ffi.cdata*
local Face = {}
Face.__index = Face

local library, reason = nil, nil

for _, name in ipairs(NAMES) do
	local ok, loaded = pcall(ffi.load, name)

	if ok then
		library, freetype.library = loaded, name
		break
	end
end

--- Whether this machine has the FreeType a face is opened with.
---@return boolean
function freetype.available()
	return library ~= nil
end

--- What is missing, where nothing is.
---@return string?
function freetype.why()
	if library ~= nil then
		return nil
	end

	return reason or "No FreeType on this machine: it is what reads font files and draws their glyphs"
end

--- FreeType itself, made when the first face is opened and kept: it is the machine's own state, and
--- a program that draws text draws it until it ends.
---@return ffi.cdata* library
local function instance()
	if freetype.handle == nil then
		assert(library, freetype.why())

		local made = ffi.new("FT_Library[1]")
		local failure = library.FT_Init_FreeType(made)

		if failure ~= 0 then
			reason = "FreeType could not be started (error " .. failure .. ")"
			error(reason)
		end

		freetype.handle = made[0]
	end

	return freetype.handle
end

--- How much of a pixel height is one unit of the font.
---
--- A pixel height in a screen is how many pixels a *line* of text takes, and what FreeType is given
--- is the size of the em: they are two numbers the font itself relates, and a reader that took one
--- for the other would draw a screen of text a third larger than it was asked for.
---@param handle texter.freetype.ffi.Face
---@param pixelHeight number
---@return number
local function scaleFor(handle, pixelHeight)
	local line = handle.ascender - handle.descender

	return line > 0 and pixelHeight / line or pixelHeight / (handle.units_per_EM ~= 0 and handle.units_per_EM or 1000)
end

--- The em a pixel height comes to, in sixty-fourths of a pixel.
---@param handle texter.freetype.ffi.Face
---@param pixelHeight number
---@return number
function freetype.em(handle, pixelHeight)
	return scaleFor(handle, pixelHeight) * handle.units_per_EM
end

---@param path string
---@param index number?
---@return texter.freetype.Face? face
---@return string? err
function freetype.open(path, index)
	if library == nil then
		return nil, freetype.why()
	end

	local handle = ffi.new("FT_Face[1]")
	local failure = library.FT_New_Face(instance(), path, index or 0, handle)

	if failure ~= 0 or handle[0] == nil then
		return nil, string.format("%s is not a font FreeType can read (error %d)", path, failure)
	end

	local face = setmetatable({
		path = path,
		index = index or 0,
		handle = handle[0],
		stack = ffi.new("unsigned char[?]", STACK),
	}, Face)

	local names = face.handle

	if names.family_name ~= nil then
		face.family = ffi.string(names.family_name)
	end

	if names.style_name ~= nil then
		face.style = ffi.string(names.style_name)
	end

	-- A font states its glyphs in more than one character map, and which of them is asked for
	-- decides whether a codepoint is the glyph it looks like: the Unicode one is what it means.
	library.FT_Select_Charmap(face.handle, UNICODE)

	return face
end

--- Puts the face at the em a pixel height comes to, in sixty-fourths of a pixel: a size rounded to
--- whole pixels is a line of text a pixel shorter than the one that was asked for.
---@param self texter.freetype.Face
---@param pixelHeight number
function Face:size(pixelHeight)
	local em = freetype.em(self.handle, pixelHeight)

	library.FT_Set_Char_Size(self.handle, 0, math.floor(em * 64 + 0.5), 72, 72)

	return em
end

--- The glyph a codepoint is in this font, or nought where it is not one of its own.
---@param codepoint number
---@param pixelHeight number?
---@return number
function Face:glyphFor(codepoint, pixelHeight)
	if pixelHeight ~= nil then
		self:size(pixelHeight)
	end

	return library.FT_Get_Char_Index(self.handle, codepoint)
end

--- Whether the font draws this character at all.
---@param codepoint number
---@return boolean
function Face:hasGlyph(codepoint)
	return library.FT_Get_Char_Index(self.handle, codepoint) ~= 0
end

--- How tall a line of this font is at a size, in pixels: what it reaches above the baseline, what
--- it goes below it, and the gap it asks for between two lines of itself.
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function Face:metrics(pixelHeight)
	local handle = self.handle
	local scale = scaleFor(handle, pixelHeight)
	local ascent = handle.ascender * scale
	local descent = handle.descender * scale
	local gap = handle.height * scale - (ascent - descent)

	return ascent, descent, gap > 0 and gap or 0
end

--- How far the pen moves for a character, in pixels at this size.
---@param codepoint number
---@param pixelHeight number
---@return number
function Face:advance(codepoint, pixelHeight)
	local glyph = self:glyphFor(codepoint, pixelHeight)

	library.FT_Load_Glyph(self.handle, glyph, LOAD_DEFAULT)

	return tonumber(self.handle.glyph.advance.x) / 64
end

--- The ink of a glyph, copied into the buffer this face keeps: eight bits of coverage a pixel, one
--- row after another with no padding, which is what an atlas packs.
---
--- What comes back is the shape a caller draws or packs -- `width`, `height`, and where it sits
--- against the pen and the baseline -- and a glyph with no ink, which is a space or a mark a shaper
--- places with an offset, answers with nothing rather than with an error.
---@param glyph number
---@param pixelHeight number
---@return texter.Ink
function Face:inkOf(glyph, pixelHeight)
	self:size(pixelHeight)

	library.FT_Load_Glyph(self.handle, glyph, LOAD_DEFAULT + LOAD_NO_BITMAP)

	local slot = self.handle.glyph

	if library.FT_Render_Glyph(slot, RENDER_NORMAL) ~= 0 then
		return { width = 0, height = 0, left = 0, top = 0 }
	end

	local bitmap = slot.bitmap

	if bitmap.pixel_mode ~= PIXEL_MODE_GRAY or bitmap.width == 0 or bitmap.rows == 0 then
		return { width = 0, height = 0, left = 0, top = 0 }
	end

	local width, height = tonumber(bitmap.width), tonumber(bitmap.rows)

	assert(width * height <= STACK, "A glyph is larger than the buffer it is copied into")

	-- A bitmap's rows are padded to a pitch of their own, and what an atlas packs has none.
	for row = 0, height - 1 do
		ffi.copy(self.stack + row * width, bitmap.buffer + row * tonumber(bitmap.pitch), width)
	end

	-- Where the ink sits: FreeType says how far the top of the bitmap is above the baseline, and
	-- what a caller wants is how far down the screen it is.
	return {
		width = width,
		height = height,
		left = tonumber(slot.bitmap_left),
		top = -tonumber(slot.bitmap_top),
		pixels = self.stack,
	}
end

--- The ink of a character, which is the glyph it comes to.
---@param codepoint number
---@param pixelHeight number
---@return texter.Ink
function Face:ink(codepoint, pixelHeight)
	return self:inkOf(self:glyphFor(codepoint, pixelHeight), pixelHeight)
end

--- What was handed out is this face's own buffer, which the next glyph is written into: a caller
--- that keeps ink keeps it by copying it, and one that draws it does so before asking for more.
---@param _ink texter.Ink
function Face:freeInk(_ink)
end

--- What a table of bytes is worth, read out of the font itself: a kern table, a name record,
--- whatever a caller knows the tag of. FreeType answers with the bytes and how many of them there
--- are, which is `FT_Load_Sfnt_Table`.
---@param tag string
---@return string? content
function Face:table(tag)
	assert(#tag == 4, "A sfnt tag is four bytes")

	local length = ffi.new("unsigned long[1]")

	if library.FT_Load_Sfnt_Table(self.handle, tonumber(ffi.cast("uint32_t", ffi.new("char[4]", tag:reverse()))), 0, nil, length) ~= 0 then
		return nil
	end

	local buffer = ffi.new("unsigned char[?]", tonumber(length[0]))

	if library.FT_Load_Sfnt_Table(self.handle, tonumber(ffi.cast("uint32_t", ffi.new("char[4]", tag:reverse()))), 0, buffer,
			length) ~= 0 then
		return nil
	end

	return ffi.string(buffer, tonumber(length[0]))
end

return freetype
