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
-- made and thrown away for every line of every frame is churn the collector pays for.
local buffer = nil

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

	local bytes = ffi.cast("const char *", ffi.new("char[?]", #content, content))
	local blob = library.hb_blob_create(bytes, #content, DUPLICATE, nil, nil)
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

--- Shapes one run of text: the glyphs it is drawn from, in the order they are drawn in, each with
--- where it came from in the string.
---
--- A run is one direction of one script -- what the bidi algorithm and the script of the text
--- decide -- and what is handed in is that run alone: `direction` is "ltr" or "rtl", and the script
--- is worked out from the characters where it is not named.
---@param font ffi.cdata*
---@param text string
---@param opts { direction: "ltr" | "rtl"?, script: string?, language: string? }
---@return texter.Glyph[] glyphs
---@return number width
function harfbuzz.shape(font, text, opts)
	assert(library, harfbuzz.why())
	assert(#text > 0, "A run of nothing is not a run")

	if buffer == nil then
		buffer = library.hb_buffer_create()
	else
		-- The buffer keeps what was shaped in it until it is emptied, and what a run is shaped from
		-- is this run alone.
		library.hb_buffer_destroy(buffer)
		buffer = library.hb_buffer_create()
	end

	library.hb_buffer_add_utf8(buffer, text, #text, 0, #text)

	if opts.direction ~= nil then
		library.hb_buffer_set_direction(buffer, DIRECTION[opts.direction])
	else
		library.hb_buffer_guess_segment_properties(buffer)
	end

	if opts.language ~= nil then
		library.hb_buffer_set_language(buffer, library.hb_language_from_string(opts.language, #opts.language))
	end

	library.hb_shape(font, buffer, nil, 0)

	local count = ffi.new("unsigned int[1]")
	local infos = library.hb_buffer_get_glyph_infos(buffer, count)
	local positions = library.hb_buffer_get_glyph_positions(buffer, count)
	local glyphs, pen = {}, 0.0

	---@cast infos texter.harfbuzz.ffi.GlyphInfo
	---@cast positions texter.harfbuzz.ffi.GlyphPosition

	for index = 0, tonumber(count[0]) - 1 do
		local info = infos[index]
		local position = positions[index]
		local advance = tonumber(position.x_advance) / 64

		glyphs[#glyphs + 1] = {
			glyph = info.codepoint,
			cluster = info.cluster,
			x = pen + tonumber(position.x_offset) / 64,
			y = -tonumber(position.y_offset) / 64,
			advance = advance,
		}

		pen = pen + advance
	end

	return glyphs, pen
end

return harfbuzz
