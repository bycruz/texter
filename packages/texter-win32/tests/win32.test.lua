-- What windows' own Uniscribe and GDI answer with.
--
-- These run on windows and nowhere else: the module loads the platform's own libraries, so a
-- machine without them skips rather than fails.
local test = require("lde-test")

local ok, win32 = pcall(require, "texter-win32")

local FONTS = {
	"C:/Windows/Fonts/arial.ttf",
	"C:/Windows/Fonts/segoeui.ttf",
	"C:/Windows/Fonts/tahoma.ttf",
	"C:/Windows/Fonts/calibri.ttf",
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
---@return texter.win32.Face? face
local function anArabicFace()
	if not ok then
		return nil
	end

	for _, path in ipairs(FONTS) do
		local made, face = pcall(win32.face, path, 0)

		if made and face and face:hasGlyph(0x645) and face:hasGlyph(0x62D) then
			return face
		end
	end
end

local arabicFace = anArabicFace()

test.skipIf(not ok)("loads the platform's own libraries", function()
	test.truthy(win32.available(), "windows has Uniscribe and GDI wherever it has text")
	test.equal(win32.why(), nil)
end)

test.skipIf(not ok or fontPath == nil)("reads a font file, and says what it is called", function()
	local face = assert(win32.face(assert(fontPath), 0))

	test.truthy(face.family ~= nil, "the family is read out of the file: " .. tostring(face.family))
	test.truthy(face:hasGlyph(0x41), "and it draws the letters it draws")

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
	local face = assert(win32.face(assert(fontPath), 0))
	local ink = face:ink(0x41, 24)

	test.greater(ink.width, 0, "a letter has ink")
	test.greater(ink.height, 0)
	test.truthy(ink.top <= 0, "which sits on the baseline")

	local space = face:ink(0x20, 24)

	test.equal(space.width, 0, "and a space has none")
end)

test.skipIf(not ok or fontPath == nil)("shapes a line into the glyphs it is drawn from", function()
	local face = assert(win32.face(assert(fontPath), 0))
	local line = win32.shape(face, "Hello, world", 24)

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
	local face = assert(win32.face(assert(fontPath), 0))
	local line = win32.shape(face, "Hello", 24)

	test.equal(win32.penOf(line, 0), 0, "the caret before the first byte is at the start")
	test.equal(win32.penOf(line, #line.text + 1), line.width, "and one past the last is at the end")
	test.equal(win32.byteAt(line, 0), 0, "a point at the start is the first byte")
end)

test.skipIf(not ok or fontPath == nil)("answers what wonderland asks a reader of fonts", function()
	local face = assert(win32.provider.open(assert(fontPath), 0))

	test.truthy(face:hasGlyph(0x41), "whether a face draws a character")
	test.truthy(select(1, face:metrics(18)) > 0, "how tall its lines are")
	test.greater(face:advance(0x41, 18), 0, "how far the pen moves")
	test.greater(face:ink(0x41, 18).width, 0, "and what its ink is")
	face:freeInk(face:ink(0x41, 18))
end)

test.skipIf(not ok or fontPath == nil)("counts a cluster in bytes of the line, not in characters", function()
	local face = assert(win32.face(assert(fontPath), 0))
	local line = win32.shape(face, "café!", 24)

	test.equal(#line.glyphs, 5, "one glyph a character, where nothing joined")
	test.equal(line.glyphs[5].cluster, 5, "and the last of them came from the sixth byte of the line")

	local money = win32.shape(face, "a€b", 24)

	test.equal(#money.glyphs, 3, "a character of three bytes is still one glyph")
	test.equal(money.glyphs[3].cluster, 4, "and the letter after it came from the fifth byte")
end)

test.skipIf(arabicFace == nil)("shapes Arabic in the order it is drawn in", function()
	local line = win32.shape(assert(arabicFace), "مرحبا", 32)

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

	test.truthy(math.abs(line.width - pen) < 1.5, "and the line is as wide as its glyphs put together")
end)

test.skipIf(arabicFace == nil)("arranges a line of two directions, which is what the bidi algorithm is for",
	function()
		local line = win32.shape(assert(arabicFace), "abc مرحبا def", 32)

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

test.skipIf(not win32 or fontPath == nil)("draws a glyph the right way up", function()
	local face = assert(win32.face(assert(fontPath), 0))

	-- An L is a stem with a bar along the bottom: a bitmap that came out upside down has its weight
	-- at the other end of it, which is what this is written against.
	local ink = face:ink(0x4C, 24)

	test.greater(ink.height, 4, "it has rows to look at")
	test.greater(rowInk(ink, ink.height - 1), rowInk(ink, 0),
		"and the bottom of an L has more ink in it than the top")
end)
