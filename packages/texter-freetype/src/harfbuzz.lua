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

-- What a shaped glyph is in a line: the fields of `texter.Glyph` in a struct rather than in a table.
-- A frame that lays out strings it has not drawn before makes a line for each of them, and a glyph's
-- struct is a fifth of the table it used to be, which is most of what such a line cost the collector.
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

	typedef struct {
		uint32_t glyph;
		uint32_t cluster;
		double x;
		double y;
		double advance;
	} texter_glyph;

	hb_blob_t *hb_blob_create(const char *data, unsigned int length, int mode, void *user_data, void *destroy);
	hb_blob_t *hb_blob_create_from_file(const char *file_name);
	unsigned int hb_blob_get_length(hb_blob_t *blob);
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

-- HB_MEMORY_MODE_READONLY: what HarfBuzz reads is memory the caller keeps, and it neither copies it
-- nor gives it back. A font is tens of megabytes of tables and a line reads a few of them, so what
-- a face is opened from is what HarfBuzz should read rather than a copy of it for each size.
local READONLY = 1

-- HB_DIRECTION_*: which way a run of text is set.
local DIRECTION = { ltr = 4, rtl = 5, ttb = 6, btt = 7 }

--- One glyph of a shaped run, in whole pixels.
---@class texter.Glyph
---@field glyph number # Which glyph of the font it is
---@field cluster number # Where in the string it came from, by byte
---@field x number # Where it is drawn, from the start of the run
---@field y number
---@field advance number # How far the pen moves for it

local NAMES = { "harfbuzz", "libharfbuzz.so.0", "libharfbuzz_ng.so", "libharfbuzz.0.dylib", "harfbuzz.dll", "libharfbuzz-0.dll" }

local harfbuzz = {}

-- The faces HarfBuzz reads, by the file and index they are: a font file is one set of tables
-- however many weights and sizes of it a screen draws text in, and one mapping of it is what every
-- one of them reads. Held weakly, so a file nothing draws from any more is given back.
---@type table<string, ffi.ptr<hb_face_t>>
local faces = setmetatable({}, { __mode = "v" })

---@type ffi.namespace*?
local library = nil
local reason = nil

for _, name in ipairs(NAMES) do
	local ok, loaded = pcall(ffi.load, name)

	if ok then
		---@cast loaded ffi.namespace*
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

-- What gives a face and a font back, as plain functions: a finalizer written where the face is
-- made is a closure, and a function the module already holds is not one per size of a face.
---@param ptr ffi.ptr<hb_face_t>
local function destroyFace(ptr)
	assert(library).hb_face_destroy(ptr)
end

---@param ptr ffi.ptr<hb_font_t>
local function destroyFont(ptr)
	assert(library).hb_font_destroy(ptr)
end

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

-- The bytes of a font file, for what HarfBuzz reads it out of: the file's own mapping where the
-- HarfBuzz there can make one, and one copy of the file where it cannot. A copy is kept for as long
-- as the process, by the file it is, because a font on disk does not change under an app that is
-- drawing text and the face made from it is kept the same way.
---@type table<string, string>
local copied = {}

---@param api ffi.namespace*
---@param path string
---@return ffi.ptr<hb_blob_t>? blob
local function blobOfFile(api, path)
	-- What a HarfBuzz too old to have a file mapping says when it is asked for one is an error rather
	-- than nothing, so what it has is asked for and the answer is what says whether it has it.
	local hasFile = pcall(function() return api.hb_blob_create_from_file end)

	if not hasFile then
		local bytes = copied[path]

		if bytes == nil then
			local file = io.open(path, "rb")

			if file == nil then
				return nil
			end

			bytes = file:read("*a")

			file:close()

			if type(bytes) ~= "string" then
				return nil
			end

			copied[path] = bytes
		end

		return api.hb_blob_create(ffi.cast("const char *", bytes), #bytes, READONLY, nil, nil)
	end

	local blob = api.hb_blob_create_from_file(path)

	if blob == nil then
		return nil
	end

	if api.hb_blob_get_length(blob) == 0 then
		api.hb_blob_destroy(blob)

		return nil
	end

	return blob
end

--- One face of a font file, which is what the shaped fonts of it read their tables out of. What it
--- reads is the file's own mapping rather than a string of it in Lua: a font is tens of megabytes of
--- tables a line reads a few of, and a copy of the whole file for each size a face is shaped at is
--- what a screen of text used to cost.
---
--- A face is made once for each file and index, so that every size shaped from it -- and every
--- screen drawing text in it -- reads the one mapping. What holds it is the caller, and what frees
--- it, and the shaped fonts below that read it, is when the last of them is collected.
---@param path string
---@param index number?
---@return ffi.ptr<hb_face_t>? face
---@return string? err
function harfbuzz.face(path, index)
	local api = assert(library, harfbuzz.why())

	-- One face a file and an index, however many weights and sizes draw text from it: what the
	-- face is, is that file's tables, and a second mapping of a font of tens of megabytes is a
	-- second copy of the pages a shape reads. What is kept is weak, so a file no font reads any
	-- more is unmapped when the collector next runs.
	local key = path .. "\0" .. (index or 0)
	local known = faces[key]

	if known ~= nil then
		return known
	end

	local blob = blobOfFile(api, path)

	if blob == nil then
		return nil, path .. " could not be read as a font"
	end

	local face = ffi.gc(api.hb_face_create(blob, index or 0), destroyFace)

	-- The face holds the blob it was made from, so this call's own reference is given back here:
	-- waiting for the collector would keep the file mapped for as long as an unreachable pointer
	-- lived rather than for as long as the face is used.
	api.hb_blob_destroy(blob)

	faces[key] = face

	return face
end

--- One face of a font a caller already holds the bytes of -- an embedded font, or one downloaded --
--- which is read where it lies rather than copied: the bytes stay the caller's, and so does keeping
--- them alive for as long as the face is used.
---@param bytes ffi.ptr<ffi.uint8_t> # The first byte of the font
---@param length number
---@param index number?
---@return ffi.ptr<hb_face_t>? face
---@return string? err
function harfbuzz.faceBytes(bytes, length, index)
	local api = assert(library, harfbuzz.why())

	local blob = api.hb_blob_create(ffi.cast("const char *", bytes), length, READONLY, nil, nil)

	if blob == nil then
		return nil, "the bytes of this font could not be read"
	end

	local face = ffi.gc(api.hb_face_create(blob, index or 0), destroyFace)

	api.hb_blob_destroy(blob)

	return face
end

--- A font of a face at a size: what a line is shaped with.
---
--- The size it is given is the em in sixty-fourths of a pixel -- the same number the reader is given
--- for the same line height -- because that is what makes the two agree: what HarfBuzz measures and
--- what FreeType draws are then the same pixels. Nothing of the file is read here: a font is a size
--- of a face, and the face it shares with every other size of the same file holds the tables.
---@param face ffi.ptr<hb_face_t>
---@param em number # How large the em is, in pixels
---@return ffi.ptr<hb_font_t> font
function harfbuzz.font(face, em)
	local api = assert(library, harfbuzz.why())

	local font = ffi.gc(api.hb_font_create(face), destroyFont)

	-- What HarfBuzz counts in is sixty-fourths of a pixel, and what is handed in is the em in whole
	-- ones: a scale of eighteen is an em of eighteen sixty-fourths, which is a line a hundredth of
	-- the size it was asked for.
	local scaled = math.floor(em * 64 + 0.5)
	local ppem = math.floor(em + 0.5)

	api.hb_ot_font_set_funcs(font)
	api.hb_font_set_scale(font, scaled, scaled)
	api.hb_font_set_ppem(font, ppem, ppem)

	return font
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
---@param font ffi.ptr<hb_font_t>
---@param text string
---@param opts { direction: "ltr" | "rtl"?, script: string?, language: string?, from: number?, to: number?, x: number? }
---@param into texter.Glyph[]
---@param at number # How many glyphs are already in it
---@return number count # How many were written
---@return number width # How wide the run is
function harfbuzz.shape(font, text, opts, into, at)
	local api = assert(library, harfbuzz.why())

	local from = (opts.from or 1) - 1
	local to = opts.to or #text
	local length = to - from

	assert(length > 0, "A run of nothing is not a run")

	if buffer == nil then
		buffer = api.hb_buffer_create()
	else
		-- What the buffer holds is emptied rather than the buffer given back: it is the same room
		-- for the next run, and a run of a line of a frame is a line of a frame.
		api.hb_buffer_clear_contents(buffer)
	end

	local held = assert(buffer)

	-- The stretch of the line this run is: what HarfBuzz is handed is where it starts in the line
	-- and how far it goes, so that the clusters it answers with are bytes of the *line*.
	api.hb_buffer_add_utf8(held, text, #text, from, length)

	-- The direction is what the bidi algorithm worked out; the script is guessed from the text.
	--
	-- HarfBuzz picks its shaper by script, and the one for arabic is the one that joins a letter to
	-- what is beside it: a line of arabic handed over as an unknown script comes back as the letters
	-- it is spelled with, drawn as they are drawn alone -- the same glyphs, the same advances, the
	-- same width, and nothing about it saying anything is wrong.
	if opts.direction ~= nil then
		api.hb_buffer_set_direction(held, assert(DIRECTION[opts.direction]))
	end

	api.hb_buffer_guess_segment_properties(held)

	if opts.language ~= nil then
		api.hb_buffer_set_language(held, api.hb_language_from_string(opts.language, #opts.language))
	end

	api.hb_shape(font, held, nil, 0)

	local infos = api.hb_buffer_get_glyph_infos(held, counted)
	local positions = api.hb_buffer_get_glyph_positions(held, counted)
	local count = tonumber(counted[0])
	local x = opts.x or 0.0
	local pen = 0.0

	for index = 0, count - 1 do
		local info = infos[index]
		local position = positions[index]
		local advance = tonumber(position.x_advance) / 64

		-- A glyph of the line is written where the line holds it: a struct rather than a table,
		-- because what a line of new text costs is a table for each of its glyphs.
		into[at + index + 1] = ffi.new("texter_glyph", info.codepoint,
			-- What HarfBuzz answers a cluster as is the byte of the line this run is a stretch of,
			-- which is what a caret is placed by.
			tonumber(info.cluster), x + pen + tonumber(position.x_offset) / 64,
			-tonumber(position.y_offset) / 64, advance)

		pen += advance
	end

	return count, pen
end

return harfbuzz
