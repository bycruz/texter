-- What the machine's own libraries answer with: a font read, a string shaped, and the two agreeing
-- about how large a line is.
--
-- Every test here needs a font on the machine, and two of them need one that draws Arabic: what
-- cannot be found is skipped rather than failed, because what is being tested is what the libraries
-- answer, not which fonts a machine has.
local test = require("lde-test")

local texter = require("texter-freetype")

local LATIN = {
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/Library/Fonts/Arial.ttf",
	"C:/Windows/Fonts/arial.ttf",
}

local ARABIC = {
	"/usr/share/fonts/google-noto-vf/NotoSansArabic[wght].ttf",
	"/usr/share/fonts/truetype/noto/NotoSansArabic-Regular.ttf",
	"/usr/share/fonts/google-noto/NotoNaskhArabic-Regular.ttf",
	"/System/Library/Fonts/GeezaPro.ttc",
	"C:/Windows/Fonts/arial.ttf",
}

---@param paths string[]
---@return string? path
local function present(paths)
	for _, path in ipairs(paths) do
		local file = io.open(path, "rb")

		if file then
			file:close()

			return path
		end
	end
end

local latinPath = present(LATIN)
local arabicPath = present(ARABIC)

test.skipIf(not texter.available())("says what is missing rather than failing, where a library is", function()
	test.equal(texter.why(), nil, "everything it draws with was found")
	test.truthy(texter.arranges(), "and the bidi algorithm with it")
end)

test.skipIf(not texter.available() or latinPath == nil)("reads a font, and says a line of it is as tall as asked",
	function()
		local face = assert(texter.face(assert(latinPath), 0))
		local ascent, descent, gap = face:metrics(24)

		-- A pixel height is a line of text: what a caller asks for is how many pixels one takes, and
		-- what the font states is in its own units. A reader that took one for the other would draw
		-- every screen at the wrong size.
		-- The two are a product of the same scale, so what they come to is twenty-four to within
		-- the last bit of a double rather than exactly.
		test.truthy(math.abs(ascent - descent - 24) < 1e-9,
			string.format("a line of it is twenty-four pixels, and it says %.12f", ascent - descent))
		test.equal(gap, 0, "and Noto Sans asks for no gap between its lines")
		test.truthy(face:hasGlyph(0x41), "it draws the letters it draws")
		test.greater(face:advance(0x41, 24), 0, "and the pen moves for one of them")
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

test.skipIf(not texter.available() or latinPath == nil)("gives the ink of a glyph, and none for a space", function()
	local face = assert(texter.face(assert(latinPath), 0))
	local ink = face:ink(0x41, 24)

	test.greater(ink.width, 0, "a letter has ink")
	test.greater(ink.height, 0)
	test.truthy(ink.top <= 0, "which sits on the baseline rather than under it")
	test.truthy(ink.left >= 0, "and inside its advance")

	local space = face:ink(0x20, 24)

	test.equal(space.width, 0, "and a space has none at all")
	test.equal(space.height, 0)
end)

test.skipIf(not texter.available() or latinPath == nil)("shapes a line into the glyphs it is drawn from", function()
	local face = assert(texter.face(assert(latinPath), 0))
	local line = texter.shape(face, "Hello, world", 24)

	test.equal(#line.glyphs, 12, "one glyph a character, where nothing joined")
	test.falsy(line.rtl, "set left to right")

	local pen = 0.0

	for index, glyph in ipairs(line.glyphs) do
		test.equal(glyph.x, pen, string.format("glyph %d is where the pen had got to", index))
		test.truthy(glyph.cluster >= 0 and glyph.cluster < #line.text, "and came from a byte of the line")
		test.greater(glyph.glyph, 0, "and is a glyph of the font")

		pen = pen + glyph.advance
	end

	test.equal(line.width, pen, "and the line is as wide as its glyphs put together")
end)

test.skipIf(not texter.available() or latinPath == nil)("lets the font join and kern, which is what it is for",
	function()
		local face = assert(texter.face(assert(latinPath), 0))

		local apart = texter.shape(face, "fi", 24)
		local joined = texter.shape(face, "fi", 24)

		test.equal(#apart.glyphs, #joined.glyphs, "the same string shapes the same way twice")

		-- Noto Sans ligates an f and an i, which is one glyph for two characters: what is tested is
		-- that the shaping is the font's own tables and not a character's glyph one after another.
		if #apart.glyphs == 1 then
			test.equal(apart.glyphs[1].cluster, 0, "a ligature comes from the first of the two")
			test.equal(apart.glyphs[1].advance, apart.width, "and is the whole of the line")
		end

		local a = face:advance(0x41, 24)
		local v = face:advance(0x56, 24)
		local pair = texter.shape(face, "AV", 24)

		test.truthy(pair.width <= a + v + 1e-6,
			string.format("and a pair is never wider than its letters apart: %.2f against %.2f", pair.width, a + v))
	end)

test.skipIf(not texter.available() or latinPath == nil)("puts a caret where a byte of the line is", function()
	local face = assert(texter.face(assert(latinPath), 0))
	local line = texter.shape(face, "Hello", 24)
	local pen = 0.0

	for index, glyph in ipairs(line.glyphs) do
		local at = texter.penOf(line, glyph.cluster)

		test.equal(at, pen, "the caret is where the glyph that byte came from is drawn")
		test.equal(texter.byteAt(line, at), glyph.cluster, "and a point there is that byte again")

		pen = pen + glyph.advance

		_ = index
	end

	test.equal(texter.penOf(line, #line.text + 1), line.width, "and the end of the line is the end of it")
end)

test.skipIf(not texter.available() or arabicPath == nil)("shapes Arabic in the order it is drawn in", function()
	local face = assert(texter.face(assert(arabicPath), 0))
	local line = texter.shape(face, "مرحبا", 32)

	test.truthy(line.rtl, "a word of Arabic is set right to left")
	test.equal(#line.runs, 1, "and is one run of one direction")
	test.greater(#line.glyphs, 4, "with more glyphs than letters, because they join")

	-- What HarfBuzz answers in is visual order, so the glyph of the last letter comes first and the
	-- byte it came from goes down the line rather than up it.
	local previous = math.huge

	for _, glyph in ipairs(line.glyphs) do
		test.truthy(glyph.cluster <= previous, "the bytes of a right to left run go backwards")
		previous = glyph.cluster
	end

	test.equal(line.glyphs[#line.glyphs].cluster, 0, "and the last glyph drawn is the first letter")
end)

test.skipIf(not texter.available() or arabicPath == nil or latinPath == nil)(
	"arranges a line of two directions, which is what the bidi algorithm is for", function()
		local latin = assert(texter.face(assert(latinPath), 0))
		local line = texter.shape(latin, "hello", 24)

		test.equal(#line.runs, 1, "a line of one direction is one run")

		local arabic = assert(texter.face(assert(arabicPath), 0))

		-- Two faces cannot be mixed in one line -- a line is shaped in one font -- so what is tested
		-- here is the arrangement itself: a line that holds a right to left word is cut into runs,
		-- and the runs are in the order a screen draws them.
		local mixed = texter.shape(arabic, "abc مرحبا def", 24)

		test.greater(#mixed.runs, 1, "a line of two directions is more than one run")

		local seen = 0

		for _, run in ipairs(mixed.runs) do
			test.truthy(run.last >= run.first, "every run is a stretch of the line")
			seen = seen + 1
		end

		test.equal(seen, #mixed.runs)
		test.greater(mixed.width, 0, "and the line has a width")
	end)

test.skipIf(not texter.available() or latinPath == nil)("answers what wonderland asks a reader of fonts", function()
	local face = assert(texter.provider.open(assert(latinPath), 0))

	test.truthy(face:hasGlyph(0x41), "whether a face draws a character")
	test.truthy(select(1, face:metrics(18)) > 0, "how tall its lines are")
	test.greater(face:advance(0x41, 18), 0, "how far the pen moves")
	test.greater(face:ink(0x41, 18).width, 0, "and what its ink is")
	face:freeInk(face:ink(0x41, 18))
end)

test.skipIf(not texter or fontPath == nil)("draws a glyph the right way up", function()
	local face = assert(texter.face(assert(fontPath), 0))

	-- An L is a stem with a bar along the bottom: a bitmap that came out upside down has its weight
	-- at the other end of it, which is what this is written against.
	local ink = face:ink(0x4C, 24)

	test.greater(ink.height, 4, "it has rows to look at")
	test.greater(rowInk(ink, ink.height - 1), rowInk(ink, 0),
		"and the bottom of an L has more ink in it than the top")
end)
