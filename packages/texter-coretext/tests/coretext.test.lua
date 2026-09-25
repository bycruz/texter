-- What macOS' own CoreText answers with.
--
-- These run on a mac and nowhere else: the module loads the platform's own frameworks, so a machine
-- without them skips rather than fails.
local test = require("lde-test")

local ok, coretext = pcall(require, "texter-coretext")

local FONTS = {
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/System/Library/Fonts/Helvetica.ttc",
	"/System/Library/Fonts/Geneva.ttf",
	"/System/Library/Fonts/SFNS.ttf",
	"/Library/Fonts/Arial.ttf",
}

---@return string? path
local function aFont()
	for _, path in ipairs(FONTS) do
		local file = io.open(path, "rb")

		if file then
			file:close()

			return path
		end
	end
end

local fontPath = aFont()

--- A font of this machine that draws Arabic, which not every font of it does.
---@return texter.coretext.Face? face
local function anArabicFace()
	if not ok then
		return nil
	end

	for _, path in ipairs(FONTS) do
		local made, face = pcall(coretext.face, path, 0)

		if made and face and face:hasGlyph(0x645) and face:hasGlyph(0x62D) then
			return face
		end
	end
end

local arabicFace = anArabicFace()

test.skipIf(not ok)("loads the platform's own frameworks", function()
	test.truthy(coretext.available(), "macOS has CoreText wherever it has text")
	test.equal(coretext.why(), nil)
end)

test.skipIf(not ok or fontPath == nil)("reads a font file, and says what it draws", function()
	local face = assert(coretext.face(assert(fontPath), 0))

	test.truthy(face:hasGlyph(0x41), "it draws the letters it draws")

	local ascent, descent = face:metrics(24)

	test.truthy(math.abs(ascent - descent - 24) < 1.5,
		string.format("a line of it is twenty-four pixels, and it says %.2f", ascent - descent))
end)

--- How much ink one row of a glyph has, which is what says which way up it came out.
---@param ink texter.Ink
---@param row number
---@return number
local function rowInk(ink, row)
	local sum = 0

	for column = 0, ink.width - 1 do
		sum = sum + assert(ink.pixels)[row * ink.width + column]
	end

	return sum
end

test.skipIf(not ok or fontPath == nil)("gives the ink of a glyph, and none for a space", function()
	local face = assert(coretext.face(assert(fontPath), 0))
	local ink = face:ink(0x41, 24)

	test.greater(ink.width, 0, "a letter has ink")
	test.greater(ink.height, 0)
	test.truthy(ink.top <= 0, "which sits on the baseline")

	local space = face:ink(0x20, 24)

	test.equal(space.width, 0, "and a space has none")
end)

test.skipIf(not ok or fontPath == nil)("shapes a line into the glyphs it is drawn from", function()
	local face = assert(coretext.face(assert(fontPath), 0))
	local line = coretext.shape(face, "Hello, world", 24)

	test.equal(#line.glyphs, 12, "one glyph a character, where nothing joined")
	test.falsy(line.rtl, "set left to right")

	local pen = 0.0

	for index, glyph in ipairs(line.glyphs) do
		test.truthy(glyph.cluster >= 0 and glyph.cluster < #line.text,
			string.format("glyph %d came from a byte of the line: %d", index, glyph.cluster))

		pen = pen + glyph.advance

		_ = index
	end

	test.truthy(math.abs(line.width - pen) < 1.5, "and the line is as wide as its glyphs put together")
end)

test.skipIf(not ok or fontPath == nil)("puts a caret where a byte of the line is", function()
	local face = assert(coretext.face(assert(fontPath), 0))
	local line = coretext.shape(face, "Hello", 24)

	test.equal(coretext.penOf(line, 0), 0, "the caret before the first byte is at the start")
	test.equal(coretext.penOf(line, #line.text + 1), line.width, "and one past the last is at the end")
	test.equal(coretext.byteAt(line, 0), 0, "a point at the start is the first byte")
end)

test.skipIf(not ok or fontPath == nil)("answers what wonderland asks a reader of fonts", function()
	local face = assert(coretext.provider.open(assert(fontPath), 0))

	test.truthy(face:hasGlyph(0x41), "whether a face draws a character")
	test.truthy(select(1, face:metrics(18)) > 0, "how tall its lines are")
	test.greater(face:advance(0x41, 18), 0, "how far the pen moves")
	test.greater(face:ink(0x41, 18).width, 0, "and what its ink is")
	face:freeInk(face:ink(0x41, 18))
end)

--- The emoji fonts a machine of this platform is likely to have: what the tests of an emoji are
--- about, and nothing this library brings. A machine without one skips rather than fails.
local EMOJI = {
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"/Library/Fonts/Arial Unicode.ttf",
}

---@return texter.coretext.Face? face
local function anEmojiFace()
	if not ok then
		return nil
	end

	for _, path in ipairs(EMOJI) do
		local file = io.open(path, "rb")

		if file then
			file:close()

			local made, face = pcall(coretext.face, path, 0)

			if made and face and face:hasGlyph(0x1F600) and face:hasGlyph(0x1F680) then
				return face
			end
		end
	end
end

local emojiFace = anEmojiFace()

--- Where each character of a string starts, which is what a cluster of a glyph is checked against.
---@param text string
---@return table<number, boolean>
local function starts(text)
	local characters = require("texter-common").utf8.characters(text)
	local at = {}

	for index = 0, characters.count - 1 do
		at[characters.offsets[index] - 1] = true
	end

	return at
end

test.skipIf(not ok or fontPath == nil)("counts a cluster in bytes of the line, not in characters", function()
	local face = assert(coretext.face(assert(fontPath), 0))
	local line = coretext.shape(face, "café!", 24)

	test.equal(#line.glyphs, 5, "one glyph a character, where nothing joined")
	test.equal(line.glyphs[5].cluster, 5, "and the last of them came from the sixth byte of the line")

	local money = coretext.shape(face, "a€b", 24)

	test.equal(#money.glyphs, 3, "a character of three bytes is still one glyph")
	test.equal(money.glyphs[3].cluster, 4, "and the letter after it came from the fifth byte")
end)

test.skipIf(arabicFace == nil)("shapes Arabic in the order it is drawn in", function()
	local line = coretext.shape(assert(arabicFace), "مرحبا", 32)

	test.truthy(line.rtl, "a word of Arabic is set right to left")
	test.equal(#line.runs, 1, "and is one run of one direction")
	test.greater(#line.glyphs, 4, "with a glyph for each of its letters")

	-- What comes out of a shaper is the glyphs in the order a screen draws them, from the left, so
	-- the glyph of the last letter is the first one drawn and the bytes go down the line rather
	-- than up it.
	local previous = math.huge

	for index, glyph in ipairs(line.glyphs) do
		test.truthy(glyph.cluster <= previous,
			string.format("glyph %d came from byte %d, after byte %d", index, glyph.cluster, previous))
		previous = glyph.cluster
	end

	test.equal(line.glyphs[#line.glyphs].cluster, 0, "and the last glyph drawn is the first letter")

	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		pen = pen + glyph.advance
	end

	test.truthy(math.abs(line.width - pen) < 1.5,
		string.format("and the line is as wide as its glyphs put together: %.2f against %.2f", line.width, pen))
end)

test.skipIf(arabicFace == nil)("arranges a line of two directions, which is what the bidi algorithm is for",
	function()
		local line = coretext.shape(assert(arabicFace), "abc مرحبا def", 32)

		test.greater(#line.runs, 1, "a line of two directions is more than one run")

		local backwards = 0

		for _, run in ipairs(line.runs) do
			test.truthy(run.last >= run.first, "every run is a stretch of the line")

			if run.rtl then
				backwards = backwards + 1
			end
		end

		test.greater(backwards, 0, "and one of them is set the other way")
		test.greater(#line.glyphs, 4, "and the line has glyphs to draw")
		test.greater(line.width, 0, "and a width")
	end)

test.skipIf(emojiFace == nil)("draws an emoji, which is a character outside the basic plane", function()
	local face = assert(emojiFace)

	test.truthy(face:hasGlyph(0x1F600),
		"it says it draws a grinning face, which is a character of two UTF-16 units")

	local line = coretext.shape(face, "😀", 24)

	test.equal(#line.glyphs, 1, "and one of it is one glyph")
	test.greater(line.glyphs[1].glyph, 0, "which is a glyph of the font rather than the one for nothing")
	test.equal(line.glyphs[1].cluster, 0, "and it came from the first byte of the line")
	test.greater(line.width, 0, "and it takes room on it")
end)

test.skipIf(emojiFace == nil)("counts an emoji in bytes of the line, which is four of them", function()
	local face = assert(emojiFace)
	local line = coretext.shape(face, "😀😀", 24)
	local at = starts("😀😀")

	test.greater(#line.glyphs, 1, "two emoji are more than one glyph")

	for index, glyph in ipairs(line.glyphs) do
		test.truthy(at[glyph.cluster],
			string.format("glyph %d came from a character of the line: byte %d", index, glyph.cluster))
	end

	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		pen = pen + glyph.advance
	end

	test.truthy(math.abs(line.width - pen) < 1.5, "and the line is as wide as its glyphs put together")
end)

test.skipIf(emojiFace == nil)("puts a caret between two emoji rather than inside one", function()
	local face = assert(emojiFace)
	local line = coretext.shape(face, "😀😀", 24)
	local first = coretext.penOf(line, 0)
	local second = coretext.penOf(line, 4)
	local last = coretext.penOf(line, #line.text + 1)

	-- A caret is placed at a byte, and what a person clicks are characters: a caret inside an emoji
	-- -- which is what counting one in anything but bytes comes to -- is a caret halfway through a
	-- character that has no halfway.
	test.equal(first, 0, "the caret before the first emoji is at the start of the line")
	test.greater(second, first, "and the one after it is where the second emoji starts")
	test.greater(last, second, "and the end of the line is past both")
	test.equal(coretext.byteAt(line, second), 4, "and a click there is the byte that emoji starts at")
	test.equal(coretext.byteAt(line, first), 0, "and one at the start is the first byte")
end)

test.skipIf(emojiFace == nil)("shapes a sequence of emoji joined by a zero width joiner", function()
	local face = assert(emojiFace)
	local text = "👩‍🚀"
	local line = coretext.shape(face, text, 24)
	local at = starts(text)

	test.greater(#line.glyphs, 0, "an astronaut is one emoji or the three characters it is written as")
	test.equal(line.glyphs[1].cluster, 0, "and what is drawn first comes from the first character")

	for index, glyph in ipairs(line.glyphs) do
		test.truthy(at[glyph.cluster],
			string.format("glyph %d came from a character of the sequence: byte %d", index, glyph.cluster))
	end

	test.equal(coretext.penOf(line, #text + 1), line.width, "and the end of it is the end of the line")
end)

test.skipIf(not coretext or fontPath == nil)("draws a glyph the right way up", function()
	local face = assert(coretext.face(assert(fontPath), 0))

	-- An L is a stem with a bar along the bottom: a bitmap that came out upside down has its weight
	-- at the other end of it, which is what this is written against.
	local ink = face:ink(0x4C, 24)

	test.greater(ink.height, 4, "it has rows to look at")
	test.greater(rowInk(ink, ink.height - 1), rowInk(ink, 0),
		"and the bottom of an L has more ink in it than the top")
end)
