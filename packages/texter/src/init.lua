-- texter: text from what the machine already has.
--
--   local texter = require("texter")
--
--   local face = assert(texter.face("/usr/share/fonts/google-noto/NotoSans-Regular.ttf"))
--   local line = texter.shape(face, "مرحبا بالعالم", 24)
--
--   for _, glyph in ipairs(line.glyphs) do
--       -- draw glyph.glyph at glyph.x, and pack it from texter.ink(face, glyph.glyph, 24)
--   end
--
-- What a program needs to draw text is four things: a font file read, a string turned into the
-- glyphs it is drawn from -- joined, reordered, kerned, and arranged by direction -- the ink of a
-- glyph, and how tall a line of a font is. Every one of those is something the operating system
-- already does: FreeType and HarfBuzz on linux and android, Uniscribe and GDI on windows, CoreText
-- on macOS. What this package is, is the one API over whatever the machine has, and what it costs a
-- bundle is nothing at all.
--
--   linux, android  texter-freetype    FreeType, HarfBuzz, fribidi
--   windows         texter-win32       Uniscribe and GDI
--   macOS           texter-coretext    CoreText and CoreGraphics
--
-- The backend is picked by the platform and pulled in by the feature that platform turns on: a
-- program on linux installs texter-freetype and never the other two, and the code that could not
-- run where it is running is not in the bundle at all. A machine with no text library is a machine
-- this says so on: `available()` and `why()`.
--
-- What a backend has to answer is in `texter.Backend`: a face, a shaped line, and the ink of a
-- glyph. Everything above that -- the caret, the arrangement of a mixed line, what a click came
-- to -- is the same on every platform, which is what makes this a library rather than three
-- bindings.
local ffi = require("ffi")

--- The package each platform's text lives in, named after the platform feature lde turns on by
--- itself: depending on this is enough to get one, and a platform's code that could not run is not
--- installed at all.
---@type table<string, string>
local BACKENDS = {
	Linux = "texter-freetype",
	Windows = "texter-win32",
	OSX = "texter-coretext",
}

--- What every backend answers, so that a caller writes one program and not three.
---
--- A `Face` is a font file read: what it draws, how tall its lines are, how far the pen moves for a
--- character, and the ink of a glyph. A `Line` is a string shaped: the glyphs in the order they are
--- drawn in -- left to right, whatever way the text reads -- each with the byte of the string it
--- came from, which is what a caret and a click are about.
---@class texter.Backend
---@field available fun(): boolean
---@field why fun(): string?
---@field face fun(path: string, index: number?): texter.Face?, string?
---@field shape fun(face: texter.Face, text: string, pixelHeight: number, opts: texter.ShapeOpts?): texter.Line
---@field ink fun(face: texter.Face, glyph: number, pixelHeight: number): texter.Ink
---@field penOf fun(line: texter.Line, byte: number): number
---@field byteAt fun(line: texter.Line, x: number): number

--- A font file read.
---@class texter.Face
---@field path string
---@field index number

--- The ink of a glyph: its size, where it sits against the pen and the baseline, and its pixels.
---
--- What a glyph is drawn from is eight bits of coverage a pixel, one row after another with no
--- padding between them, and that is what `pixels` holds. A glyph a font draws in colours of its own
--- -- an emoji, which is a picture rather than a shape -- is four bytes a pixel instead, and what
--- says which is `colour`. What the four bytes are in is the platform's own order (FreeType hands
--- over blue, green, red and alpha, each multiplied by the alpha), so a caller that packs them reads
--- the channels it knows rather than assuming red first.
---
--- The pixels are the reader's own buffer, which the next glyph it is asked for is written into: what
--- a caller keeps, it copies first. `pixels` is nought where a glyph has no ink at all.
---@class texter.Ink
---@field width number
---@field height number
---@field left number
---@field top number
---@field pixels ffi.cdata*?
---@field colour boolean? # Four bytes a pixel rather than one of coverage

--- What a string comes to when it is shaped.
---@class texter.ShapeOpts
---@field direction "ltr" | "rtl" | "auto"?
---@field language string?

--- One glyph of a shaped line, in whole pixels.
---@class texter.Glyph
---@field glyph number # Which glyph of the font it is
---@field cluster number # The byte of the line it came from
---@field x number # Where it is drawn, from the start of the line
---@field y number
---@field advance number

--- A stretch of a line that is set in one direction: a line of two directions is several of these,
--- in the order a screen draws them.
---@class texter.Run
---@field first number # The byte of the line it starts at, from one
---@field last number
---@field rtl boolean
---@field level number

--- A line, shaped: what a renderer draws.
---@class texter.Line
---@field glyphs texter.Glyph[] # In the order they are drawn in, from the left
---@field width number
---@field rtl boolean # Whether the line as a whole reads right to left
---@field runs texter.Run[]
---@field text string

local texter = {}

local name = BACKENDS[ffi.os]
local reason = nil
local backend = nil

if name == nil then
	reason = "No text backend for " .. ffi.os .. ": there is one for linux, windows and macOS"
else
	local ok, loaded = pcall(require, name)

	if ok then
		backend = loaded
	else
		reason = "texter was installed without its " .. ffi.os .. " backend (" .. name .. "): "
			.. tostring(loaded)
	end
end

--- The backend this platform's text comes from, which is what a caller reaches past this for when
--- it wants something of its own platform.
texter.backend = backend

--- What reads a font file, in the shape a UI library asks a reader of fonts for: `open(path, index)`,
--- which answers with a face whose `hasGlyph`, `metrics`, `advance`, `ink` and `freeInk` is what
--- packs a glyph into an atlas, and `shape(face, text, size)` and `ink(face, glyph, size)`, which are
--- how a screen draws a line of text: the glyphs a string is made of, and the ink of one of them. It
--- is the backend's own provider, so it is the platform that reads and draws the glyph, and a program
--- that hands it to its UI library draws text with what the machine already has -- see `wonderland`'s
--- `wonderland.font.Provider` and `FontManager.setProvider`.
---
--- It is nought on a machine whose text this cannot be, which is what `available()` says.
---@type table?
texter.provider = backend ~= nil and backend.provider or nil

---@type string?
texter.name = name

--- Whether this machine has what text is drawn with.
---@return boolean
function texter.available()
	return backend ~= nil and backend.available()
end

--- What is missing, where something is: the platform has no backend, its libraries are not there,
--- or the machine is one this has nothing for.
---@return string?
function texter.why()
	if backend == nil then
		return reason
	end

	return backend.why()
end

--- Reads a font file. What it is read as is the platform's own reader: a font collection, a font
--- whose outlines are CFF, and a font whose weights are axes all read the same way here.
---@param path string
---@param index number?
---@return texter.Face? face
---@return string? err
function texter.face(path, index)
	assert(backend, texter.why())

	return backend.face(path, index)
end

--- Shapes a line: the glyphs it is drawn from, in the order a screen draws them, each with where it
--- goes and which byte of the line it came from.
---
--- A line of two directions -- a word of Arabic inside a line of English -- comes back as one line
--- with the runs of it already in the order they are drawn in, so a caller draws the glyphs in the
--- order they came and nothing else.
---@param face texter.Face
---@param text string
---@param pixelHeight number
---@param opts texter.ShapeOpts?
---@return texter.Line
function texter.shape(face, text, pixelHeight, opts)
	assert(backend, texter.why())

	return backend.shape(face, text, pixelHeight, opts)
end

--- The ink of one glyph of a font at a size.
---@param face texter.Face
---@param glyph number
---@param pixelHeight number
---@return texter.Ink
function texter.ink(face, glyph, pixelHeight)
	assert(backend, texter.why())

	return backend.ink(face, glyph, pixelHeight)
end

--- How tall a line of a font is at a size, in pixels: what it reaches above the baseline, what it
--- goes below it, and the gap it asks for between two lines of itself.
---@param face texter.Face
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function texter.metrics(face, pixelHeight)
	assert(backend, texter.why())

	return backend.metrics(face, pixelHeight)
end

--- Where in a line a byte is, as the pen position a caret goes to.
---@param line texter.Line
---@param byte number
---@return number
function texter.penOf(line, byte)
	assert(backend, texter.why())

	return backend.penOf(line, byte)
end

--- The byte of a line a point is over, which is what a click on it comes to.
---@param line texter.Line
---@param x number
---@return number
function texter.byteAt(line, x)
	assert(backend, texter.why())

	return backend.byteAt(line, x)
end

--- Where wonderland is there, makes this what it draws text with: the same faces, read and
--- rasterised by the platform instead of by anything wonderland ships.
---@return boolean installed
function texter.install()
	if backend == nil then
		return false
	end

	local ok, fontManager = pcall(require, "wonderland.util.font_manager")

	if not ok then
		return false
	end

	fontManager.setProvider(backend.provider)

	return true
end

return texter
