-- HarfBuzz: what a string comes to in a font.
--
-- A string is not a glyph a character, and it is not the same glyphs left to right: an Arabic word
-- is letters that join, an Indic syllable is letters that reorder and merge, and even English is
-- ligatures and kerning out of the font's own tables. HarfBuzz is what reads those tables --
-- a machine with a desktop has one, every browser and toolkit on it shapes with it -- and what it
-- answers with is the glyphs a line is drawn from: which glyph, where it came from in the string,
-- and how far the pen moves for it.
--
-- What comes back here is in whole pixels, ready to place: HarfBuzz counts in sixty-fourths of one,
-- and the caller wants what a screen draws.
local ffi = require("ffi")

ffi.cdef [[
	typedef struct hb_blob_t hb_blob_t;
	typedef struct hb_face_t hb_face_t;
	typedef struct hb_font_t hb_font_t;
	typedef struct hb_buffer_t hb_buffer_t;
	typedef struct hb_unicode_funcs_t hb_unicode_funcs_t;
	typedef struct hb_language_impl_t hb_language_impl_t;

	typedef unsigned int hb_codepoint_t;
	typedef unsigned int hb_mask_t;
	typedef int hb_position_t;
	typedef unsigned int hb_script_t;
	typedef int hb_direction_t;
	typedef const hb_language_impl_t *hb_language_t;

	typedef union {
		uint32_t u32;
		int32_t i32;
		uint16_t u16[2];
		int16_t i16[2];
	} hb_var_int_t;

	typedef struct {
		hb_codepoint_t codepoint;
		hb_mask_t mask;
		uint32_t cluster;
		hb_var_int_t var1;
		hb_var_int_t var2;
	} hb_glyph_info_t;

	typedef struct {
		hb_position_t x_advance;
		hb_position_t y_advance;
		hb_position_t x_offset;
		hb_position_t y_offset;
		hb_var_int_t var;
	} hb_glyph_position_t;

	typedef struct {
		hb_codepoint_t tag;
		uint32_t value;
		unsigned int start;
		unsigned int end;
	} hb_feature_t;

	hb_blob_t *hb_blob_create(const char *data, unsigned int length, int mode, void *user_data, void *destroy);
	void hb_blob_destroy(hb_blob_t *blob);
	hb_face_t *hb_face_create(hb_blob_t *blob, unsigned int index);
	void hb_face_destroy(hb_face_t *face);
	hb_font_t *hb_font_create(hb_face_t *face);
	void hb_font_destroy(hb_font_t *font);
	void hb_ot_font_set_funcs(hb_font_t *font);
	void hb_font_set_scale(hb_font_t *font, int x_scale, int y_scale);
	void hb_font_set_ppem(hb_font_t *font, unsigned int x_ppem, unsigned int y_ppem);
	hb_buffer_t *hb_buffer_create(void);
	void hb_buffer_destroy(hb_buffer_t *buffer);
	void hb_buffer_clear_contents(hb_buffer_t *buffer);
	void hb_buffer_add_utf8(hb_buffer_t *buffer, const char *text, int length, unsigned int offset, int item_length);
	void hb_buffer_set_direction(hb_buffer_t *buffer, hb_direction_t direction);
	void hb_buffer_set_script(hb_buffer_t *buffer, hb_script_t script);
	void hb_buffer_set_language(hb_buffer_t *buffer, hb_language_t language);
	void hb_buffer_guess_segment_properties(hb_buffer_t *buffer);
	void hb_shape(hb_font_t *font, hb_buffer_t *buffer, const hb_feature_t *features, unsigned int count);
	hb_glyph_info_t *hb_buffer_get_glyph_infos(hb_buffer_t *buffer, unsigned int *length);
	hb_glyph_position_t *hb_buffer_get_glyph_positions(hb_buffer_t *buffer, unsigned int *length);
	hb_language_t hb_language_from_string(const char *language, int length);
	hb_script_t hb_unicode_script(hb_unicode_funcs_t *funcs, hb_codepoint_t codepoint);
	hb_unicode_funcs_t *hb_unicode_funcs_get_default(void);
]]

-- HB_MEMORY_MODE_DUPLICATE: what HarfBuzz reads is copied into its own memory, so the bytes a face
-- was opened from need not be kept alive for as long as the shaped font is.
local DUPLICATE = 0

-- HB_DIRECTION_*: which way a run of text is set.
local DIRECTION = { ltr = 4, rtl = 5, ttb = 6, btt = 7 }

-- HB_SCRIPT_INVALID and the shape of a script tag: a script HarfBuzz has not been told is one it
-- works out for itself, which is what the common case wants.
local SCRIPT_INVALID = 0

-- What is read out of one glyph of a shaped run.
---@class texter.harfbuzz.ffi.GlyphInfo: ffi.cdata*
---@field codepoint number
---@field cluster number

---@class texter.harfbuzz.ffi.GlyphPosition: ffi.cdata*
---@field x_advance number
---@field y_advance number
---@field x_offset number
---@field y_offset number

--- One glyph of a shaped run, in whole pixels.
---@class texter.Glyph
---@field glyph number # Which glyph of the font it is
---@field cluster number # Where in the string it came from, by byte
---@field x number # Where it is drawn, from the start of the run
---@field y number
---@field advance number # How far the pen moves for it

local NAMES = { "harfbuzz", "libharfbuzz.so.0", "libharfbuzz.0.dylib", "harfbuzz.dll",
	"libharfbuzz-0.dll" }

local harfbuzz = {}

local library, reason = nil, nil

for _, name in ipairs(NAMES) do
	local ok, loaded = pcall(ffi.load, name)

	if ok then
		library, harfbuzz.library = loaded, name
		break
	end
end

-- One buffer for the process, emptied before each run: a buffer is a few tables of glyphs, and one
-- made and thrown away for every line of every frame is churn the collector pays for. What is emptied
-- is what it holds rather than the buffer itself, which is the difference between a line costing a
-- buffer and costing nothing.
local buffer = nil

-- What HarfBuzz answers the count of a buffer in, kept for the same reason.
local counted = ffi.new("unsigned int[1]")

--- Whether this machine has the HarfBuzz a string is shaped with.
---@return boolean
function harfbuzz.available()
	return library ~= nil
end

--- What is missing, where nothing is.
---@return string?
function harfbuzz.why()
	if library ~= nil then
		return nil
	end

	return reason or "No HarfBuzz on this machine: it is what shapes a string into glyphs"
end

--- A shaped font, from the bytes of a font file: what HarfBuzz reads the tables of a font out of.
--- It is asked of the same file the reader opens, so that what a glyph is drawn from and what it was
--- shaped from are one font.
---
--- The size it is given is the em in sixty-fourths of a pixel -- the same number the reader is given
--- for the same line height -- because that is what makes the two agree: what HarfBuzz measures and
--- what FreeType draws are then the same pixels.
---@param content string
---@param index number?
---@param em number # How large the em is, in pixels
---@return ffi.cdata* font
---@return ffi.cdata* blob # Kept by the caller: the font reads it, and the font is freed after it
---@return ffi.cdata* face
function harfbuzz.font(content, index, em)
	assert(library, harfbuzz.why())

	-- The bytes of the file are copied into a buffer of this call's own rather than handed to
	-- `ffi.new` as an initialiser: an array of characters whose length is written out with the bytes
	-- beside it is a shape this LuaJIT gets wrong, and what it does instead is corrupt the heap
	-- where the writing is not seen until something else is swept -- see the note in this
	-- repository's AGENTS.md.
	local bytes = ffi.new("char[?]", #content)

	ffi.copy(bytes, content, #content)

	local blob = library.hb_blob_create(ffi.cast("const char *", bytes), #content, DUPLICATE, nil, nil)
	local face = library.hb_face_create(blob, index or 0)
	local font = library.hb_font_create(face)

	-- What HarfBuzz counts in is sixty-fourths of a pixel, and what is handed in is the em in whole
	-- ones: a scale of eighteen is an em of eighteen sixty-fourths, which is a line a hundredth of
	-- the size it was asked for.
	local scaled = math.floor(em * 64 + 0.5)
	local ppem = math.floor(em + 0.5)

	library.hb_ot_font_set_funcs(font)
	library.hb_font_set_scale(font, scaled, scaled)
	library.hb_font_set_ppem(font, ppem, ppem)

	return font, blob, face
end

---@param font ffi.cdata*
---@param blob ffi.cdata*
---@param face ffi.cdata*
function harfbuzz.free(font, blob, face)
	if library == nil then
		return
	end

	library.hb_font_destroy(font)
	library.hb_face_destroy(face)
	library.hb_blob_destroy(blob)
end

--- Shapes one run of text into the glyphs it is drawn from, in the order they are drawn in, each
--- with where it came from in the string.
---
--- A run is one direction of one script -- what the bidi algorithm and the script of the text
--- decide -- and what is handed in is that run alone: `direction` is "ltr" or "rtl", and the script
--- is worked out from the characters where it is not named. The run is a stretch of `text` and not a
--- string of its own, because a line of three runs is three substrings the collector would pay for.
---
--- What comes out is written where a caller keeps its line: `into` from `at`, one glyph after
--- another, because what a line is *is* its glyphs one after another and a run of it is not a thing
--- to be held in between.
---@param font ffi.cdata*
---@param text string
---@param opts { direction: "ltr" | "rtl"?, script: string?, language: string?, from: number?, to: number?, x: number? }
---@param into texter.Glyph[]
---@param at number # How many glyphs are already in it
---@return number count # How many were written
---@return number width # How wide the run is
function harfbuzz.shape(font, text, opts, into, at)
	assert(library, harfbuzz.why())

	local from = (opts.from or 1) - 1
	local to = opts.to or #text
	local length = to - from

	assert(length > 0, "A run of nothing is not a run")

	if buffer == nil then
		buffer = library.hb_buffer_create()
	else
		-- What the buffer holds is emptied rather than the buffer given back: it is the same room
		-- for the next run, and a run of a line of a frame is a line of a frame.
		library.hb_buffer_clear_contents(buffer)
	end

	-- The stretch of the line this run is: what HarfBuzz is handed is where it starts in the line
	-- and how far it goes, so that the clusters it answers with are bytes of the *line*.
	library.hb_buffer_add_utf8(buffer, text, #text, from, length)

	-- What the run is set in is what the bidi algorithm worked out and nothing else: everything
	-- else about it -- which script it is written in, and so which shaper reads it -- is guessed from
	-- the text.
	--
	-- Which is not a detail. A shaper is chosen by script, and the one for arabic is the one that
	-- joins letters to what is beside them: a line of arabic handed over as an unknown script comes
	-- back as the letters it is spelled with, each drawn as it is drawn alone, and nothing about the
	-- line says anything is wrong -- the same glyphs, the same advances, the same width. Guessing
	-- only where the direction was not named is guessing for a line nobody named a direction of,
	-- which is not a line this is ever handed.
	if opts.direction ~= nil then
		library.hb_buffer_set_direction(buffer, DIRECTION[opts.direction])
	end

	library.hb_buffer_guess_segment_properties(buffer)

	if opts.language ~= nil then
		library.hb_buffer_set_language(buffer, library.hb_language_from_string(opts.language, #opts.language))
	end

	library.hb_shape(font, buffer, nil, 0)

	local infos = library.hb_buffer_get_glyph_infos(buffer, counted)
	local positions = library.hb_buffer_get_glyph_positions(buffer, counted)
	local count = tonumber(counted[0])
	local x, pen = opts.x or 0.0, 0.0

	---@cast infos texter.harfbuzz.ffi.GlyphInfo
	---@cast positions texter.harfbuzz.ffi.GlyphPosition

	for index = 0, count - 1 do
		local info = infos[index]
		local position = positions[index]
		local advance = tonumber(position.x_advance) / 64

		into[at + index + 1] = {
			glyph = info.codepoint,
			-- What HarfBuzz answers a cluster as is the byte of the line this run is a stretch of,
			-- which is what a caret is placed by.
			cluster = tonumber(info.cluster),
			x = x + pen + tonumber(position.x_offset) / 64,
			y = -tonumber(position.y_offset) / 64,
			advance = advance,
		}

		pen = pen + advance
	end

	return count, pen
end

return harfbuzz
