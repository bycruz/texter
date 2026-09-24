-- texter-freetype: the text a linux or android machine already has.
--
--   local texter = require("texter-freetype")
--   local face = assert(texter.face("/usr/share/fonts/.../NotoSans-Regular.ttf"))
--   local line = texter.shape(face, "مرحبا بالعالم", 24)
--
-- Three libraries, all of them the machine's own: FreeType reads a font file and draws a glyph,
-- HarfBuzz turns a string into the glyphs it is drawn from, and fribidi arranges a line that is set
-- in more than one direction. Nothing here is built or shipped -- what a desktop has is what this
-- uses, and what a machine without them has is `why()`.
--
-- What comes out of `shape` is what a renderer draws: the glyphs of a line, in the order they are
-- drawn in, where each of them is, and which byte of the string it came from -- which is what a
-- caret is placed from and what a click is answered with.
local bidi = require("texter-freetype.bidi")
local freetype = require("texter-freetype.freetype")
local harfbuzz = require("texter-freetype.harfbuzz")
local utf8 = require("texter-common").utf8

local texter = {}

-- The bytes of each face, and the shaped fonts made from them: what a shaper is handed is the
-- whole of a font file, and what HarfBuzz reads a font's tables into is a font of its own, made
-- once for each size a face is shaped at. Both are kept beside the face rather than on it, because
-- a face is the reader's and this is the shaper's. The keys are weak, so what is kept of a face
-- goes when the face does.
---@type table<texter.freetype.Face, string>
local contents = setmetatable({}, { __mode = "k" })

---@type table<texter.freetype.Face, table<number, ffi.cdata*>>
local shapedFonts = setmetatable({}, { __mode = "k" })

--- One line, shaped and placed: what a renderer draws.
---@class texter.Line
---@field glyphs texter.Glyph[] # In the order they are drawn in, from the left
---@field width number
---@field rtl boolean # Whether the line as a whole reads right to left
---@field runs texter.Run[]
---@field text string

--- Whether this machine has what a line is drawn with: a reader of fonts and a shaper of strings.
---@return boolean
function texter.available()
	return freetype.available() and harfbuzz.available()
end

--- What is missing, where something is.
---@return string?
function texter.why()
	return freetype.why() or harfbuzz.why()
end

--- Whether a line of mixed directions can be arranged, which is what fribidi is for. Without it a
--- line is set in one direction: see `bidi.paragraph`.
---@return boolean
function texter.arranges()
	return bidi.available()
end

--- One font file, read: what the reader and the shaper both need of it.
---@param path string
---@param index number?
---@return texter-freetype.Face? face
---@return string? err
function texter.face(path, index)
	local face, err = freetype.open(path, index)

	if face == nil then
		return nil, err
	end

	local file = io.open(path, "rb")

	if file == nil then
		return nil, "Could not read " .. path
	end

	contents[face] = file:read("*all")
	shapedFonts[face] = {}

	file:close()

	return face
end

--- Shapes a line: the glyphs it is drawn from, where each of them goes, and which byte of the line
--- each came from.
---
--- The line is cut into runs first -- one direction each, by the bidi algorithm -- and each run is
--- shaped in its own direction and script by HarfBuzz. What comes back is the runs in the order a
--- screen draws them, with the glyphs of each placed one after another.
---@param face texter-freetype.Face
---@param text string
---@param pixelHeight number
---@param opts { direction: "ltr" | "rtl" | "auto"?, language: string? }?
---@return texter.Line
function texter.shape(face, text, pixelHeight, opts)
	assert(contents[face], "This face was not opened by this module: it has no bytes to shape from")

	local characters = utf8.characters(text)
	local runs, rtl = bidi.paragraph(text, characters, opts)
	local font = texter.fontOf(face, pixelHeight)

	local glyphs, pen, x = {}, 0.0, 0.0

	for _, run in ipairs(runs) do
		local shaped, width = harfbuzz.shape(font, text:sub(run.first, run.last), {
			direction = run.rtl and "rtl" or "ltr",
			language = opts and opts.language,
		})

		-- Where a glyph is and which byte it came from are both about the whole line: HarfBuzz
		-- answers about the run it was given, which starts where the run does.
		for _, glyph in ipairs(shaped) do
			glyph.x = glyph.x + x
			glyph.cluster = glyph.cluster + run.first - 1
			glyphs[#glyphs + 1] = glyph
		end

		x = x + width
	end

	return {
		glyphs = glyphs,
		width = x,
		rtl = rtl,
		runs = runs,
		text = text,
	}
end

--- The font a line is shaped with at a size, made once and kept: a shaped font is what HarfBuzz
--- reads a font's own tables into, and making one for every line of every frame is the machine
--- reading the same thousand tables again.
---@param face texter-freetype.Face
---@param pixelHeight number
---@return ffi.cdata* font
function texter.fontOf(face, pixelHeight)
	local kept = shapedFonts[face]
	local content = contents[face]

	assert(content ~= nil, "This face was not opened by this module: it has no bytes to shape from")

	kept = kept or {}
	shapedFonts[face] = kept

	local known = kept[pixelHeight]

	if known ~= nil then
		return known
	end

	-- The em the reader draws at, in sixty-fourths of a pixel, which is what the shaper is given so
	-- that the two of them are measuring the same font at the same size.
	local em = freetype.em(face.handle, pixelHeight)
	local font = harfbuzz.font(content, face.index, em)

	kept[pixelHeight] = font

	return font
end

--- The ink of one glyph of a font, at a size: what is packed into an atlas.
---@param face texter.freetype.Face
---@param glyph number
---@param pixelHeight number
---@return texter.Ink
function texter.ink(face, glyph, pixelHeight)
	return face:inkOf(glyph, pixelHeight)
end

--- How tall a line of a font is at a size, which is what a caller places lines by.
---@param face texter.freetype.Face
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function texter.metrics(face, pixelHeight)
	return face:metrics(pixelHeight)
end

--- Where in a line a byte is, as the place a caret goes: the pen position of the glyph that byte
--- came from, or the end of the line where it came from nothing.
---@param line texter.Line
---@param byte number # From one
---@return number
function texter.penOf(line, byte)
	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		if glyph.cluster >= byte then
			return pen
		end

		pen = pen + glyph.advance
	end

	return line.width
end

--- The bytes of a line a point is over, which is what a click on it comes to: the byte of the glyph
--- the point fell in, which is the one a caret before the next glyph sits at.
---@param line texter.Line
---@param x number
---@return number
function texter.byteAt(line, x)
	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		local middle = pen + glyph.advance / 2

		if x < middle then
			return glyph.cluster
		end

		pen = pen + glyph.advance
	end

	return #line.text + 1
end

-- What a screen packs a glyph from: the faces this module opens, in the shape `wonderland` asks a
-- reader of fonts for -- see `wonderland.font.Provider`. Only the faces are here, because that is
-- what an atlas needs; a screen that shapes its lines asks this module for them.
---@type wonderland.font.Provider
texter.provider = {
	open = function(path, index)
		return freetype.open(path, index)
	end,
}

--- Where wonderland is there, makes these the fonts it draws with: what it reads and what it
--- shapes with, which is this machine's own libraries rather than anything shipped.
---@return boolean installed
function texter.install()
	local ok, fontManager = pcall(require, "wonderland.util.font_manager")

	if not ok then
		return false
	end

	fontManager.setProvider(texter.provider)

	return true
end

return texter
