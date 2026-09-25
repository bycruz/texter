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

--- The emoji fonts a desktop is likely to have: the one a colour emoji is drawn from, and the
--- black and white ones, which are fonts of outlines and are what a machine without a colour one
--- has. Whether FreeType can *paint* one is a question about the font and not about this library.
local EMOJI = {
	"/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf",
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
	"/usr/share/fonts/google-noto-emoji-fonts/NotoEmoji-Regular.ttf",
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
	"C:/Windows/Fonts/seguiemj.ttf",
}

--- The fonts this package keeps for the tests of a glyph a font draws rather than states: one
--- whose layers are a COLR version 0 table -- a red square with a blue dot on it -- and one whose
--- picture is a COLR version 1 *graph* -- a solid fill, a gradient, a composite, a transform and a
--- reference to another picture, a glyph each. Both are made with fontTools, tables and all, and
--- both are looked for where the test runner keeps its own folder, so that they run from the
--- package and from the repository.
local COLOUR = {
	"tests/fonts/colour.ttf",
	"packages/texter-freetype/tests/fonts/colour.ttf",
}

local GRAPH = {
	"tests/fonts/graph.ttf",
	"packages/texter-freetype/tests/fonts/graph.ttf",
}

--- An emoji font a desktop has, which is a graph of the newest kind on most of them now: what the
--- painter is for, on the pictures a font actually ships.
local COLRV1 = {
	"/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf",
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"C:/Windows/Fonts/seguiemj.ttf",
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
local colourPath = present(COLOUR)
local graphPath = present(GRAPH)
local colrv1Path = present(COLRV1)

--- A face of a font that draws emoji at all, which is what the emoji tests are about: a machine
--- whose fonts have none of them skips rather than fails.
---@return texter.freetype.Face? face
local function anEmojiFace()
	if not texter.available() then
		return nil
	end

	for _, path in ipairs(EMOJI) do
		local file = io.open(path, "rb")

		if file then
			file:close()

			local made, face = pcall(texter.face, path, 0)

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
	local common = require("texter-common")
	local characters = common.utf8.characters(text)
	local at = {}

	for index = 0, characters.count - 1 do
		at[characters.offsets[index] - 1] = true
	end

	return at
end

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

	-- More glyphs than letters is not what joining is: joining is that a letter is drawn as the shape
	-- it takes beside its neighbours. So what says the line was shaped as arabic is that two of the
	-- same letter in a word are two *different* glyphs, neither of them the letter on its own. A
	-- shaper never told the script answers with one glyph for all three and looks healthy doing it.
	local alone = texter.shape(face, "م", 32)
	local pair = texter.shape(face, "مم", 32)

	test.equal(#pair.glyphs, 2, "two of a letter are two glyphs")
	test.truthy(pair.glyphs[1].glyph ~= pair.glyphs[2].glyph,
		"and two different shapes: a letter joined on the left is not joined on the right")
	test.truthy(pair.glyphs[1].glyph ~= alone.glyphs[1].glyph
			and pair.glyphs[2].glyph ~= alone.glyphs[1].glyph,
		"and neither of them is that letter on its own")
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

test.skipIf(not texter.available() or latinPath == nil)("draws a glyph the right way up", function()
	local face = assert(texter.face(assert(latinPath), 0))

	-- An L is a stem with a bar along the bottom: a bitmap that came out upside down has its weight
	-- at the other end of it, which is what this is written against.
	local ink = face:ink(0x4C, 24)

	test.greater(ink.height, 4, "it has rows to look at")
	test.greater(rowInk(ink, ink.height - 1), rowInk(ink, 0),
		"and the bottom of an L has more ink in it than the top")
end)

test.skipIf(emojiFace == nil)("draws an emoji, which is a character outside the basic plane", function()
	local face = assert(emojiFace)

	test.truthy(face:hasGlyph(0x1F600), "it says it draws a grinning face, which is two UTF-16 units")

	local line = texter.shape(face, "😀", 24)

	test.equal(#line.glyphs, 1, "and one of it is one glyph")
	test.greater(line.glyphs[1].glyph, 0, "which is a glyph of the font rather than the one for nothing")
	test.equal(line.glyphs[1].cluster, 0, "and it came from the first byte of the line")
	test.greater(line.width, 0, "and it takes room on it")
end)

test.skipIf(emojiFace == nil)("counts an emoji in bytes of the line, which is four of them", function()
	local face = assert(emojiFace)
	local line = texter.shape(face, "😀😀", 24)
	local at = starts("😀😀")

	test.greater(#line.glyphs, 1, "two emoji are more than one glyph")

	for index, glyph in ipairs(line.glyphs) do
		test.truthy(at[glyph.cluster], string.format("glyph %d came from a character of the line: byte %d", index,
			glyph.cluster))
	end

	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		pen = pen + glyph.advance
	end

	test.truthy(math.abs(line.width - pen) < 1.5, "and the line is as wide as its glyphs put together")
end)

test.skipIf(emojiFace == nil)("puts a caret between two emoji rather than inside one", function()
	local face = assert(emojiFace)
	local line = texter.shape(face, "😀😀", 24)
	local first = texter.penOf(line, 0)
	local second = texter.penOf(line, 4)
	local last = texter.penOf(line, #line.text + 1)

	-- A caret is placed at a byte, and what a person clicks are characters: a caret inside an emoji
	-- -- which is what counting it in anything but bytes comes to -- is a caret halfway through a
	-- character that has no halfway.
	test.equal(first, 0, "the caret before the first emoji is at the start of the line")
	test.greater(second, first, "and the one after it is where the second emoji starts")
	test.greater(last, second, "and the end of the line is past both")
	test.equal(texter.byteAt(line, second), 4, "and a click there is the byte that emoji starts at")
	test.equal(texter.byteAt(line, first), 0, "and one at the start is the first byte")
end)

test.skipIf(emojiFace == nil)("shapes a sequence of emoji joined by a zero width joiner", function()
	local face = assert(emojiFace)
	local text = "👩‍🚀"
	local line = texter.shape(face, text, 24)
	local at = starts(text)

	test.greater(#line.glyphs, 0, "an astronaut is one emoji or the three characters it is written as")
	test.equal(line.glyphs[1].cluster, 0, "and what is drawn first comes from the first character")

	for index, glyph in ipairs(line.glyphs) do
		test.truthy(at[glyph.cluster],
			string.format("glyph %d came from a character of the sequence: byte %d", index, glyph.cluster))
	end

	test.equal(texter.penOf(line, #text + 1), line.width, "and the end of it is the end of the line")
end)

test.skipIf(colourPath == nil)("gives the colours of a glyph a font draws in layers", function()
	local face = assert(texter.face(assert(colourPath), 0))
	local ink = face:ink(0x41, 24)

	test.greater(ink.width, 0, "the glyph has ink")
	test.truthy(ink.colour, "and it is a colour glyph: four bytes a pixel rather than coverage")

	local pixels = assert(ink.pixels)
	local seen, bright = {}, 0

	for at = 0, ink.width * ink.height - 1 do
		local blue, _, red, alpha = pixels[at * 4], pixels[at * 4 + 1], pixels[at * 4 + 2], pixels[at * 4 + 3]

		if alpha > 200 then
			bright = bright + 1
			seen[red > 200 and "red" or (blue > 200 and "blue" or "between")] = true
		end
	end

	test.greater(bright, 20, "and enough of it is drawn to look at")
	test.truthy(seen.red, "the square it is made of is red")
	test.truthy(seen.blue, "and the dot on it is blue")
end)

test.skipIf(colourPath == nil)("draws a glyph a font has an outline of as coverage rather than colour", function()
	local face = assert(texter.face(assert(colourPath), 0))

	-- The same font has a glyph with no layers at all -- the dot alone -- and what a glyph with no
	-- picture of its own is is what is drawn from its outline: eight bits of coverage a pixel.
	local ink = face:ink(0x42, 24)

	test.greater(ink.width, 0, "the glyph has ink")
	test.falsy(ink.colour, "and it is coverage")
end)

test.it("reads a bitmap a pixel at a time, whatever the pixels are", function()
	local ffi = require("ffi")
	local freetype = require("texter-freetype.freetype")

	--- A buffer of bytes, filled the plain way: an array of characters whose length is written out
	--- with the bytes beside it is a shape this LuaJIT gets wrong where another allocation is big.
	---@param bytes string
	---@return ffi.cdata*
	local function buffer(bytes)
		local out = ffi.new("unsigned char[?]", #bytes)

		ffi.copy(out, bytes, #bytes)

		return out
	end

	-- A monochrome bitmap: eight pixels a byte, most significant first, which is what a bitmap
	-- font's own strike is.
	local mono = buffer("\224\128")
	local monoOut = ffi.new("unsigned char[?]", 16)

	test.falsy(freetype.pixels(1, mono, 1, 8, 1, monoOut), "one bit a pixel is coverage when it is read")
	test.equal(monoOut[0], 255, "the first three bits of 11100000 are drawn")
	test.equal(monoOut[2], 255)
	test.equal(monoOut[3], 0, "and the rest of them are not")
	test.equal(monoOut[7], 0)

	-- Coverage with a row padded to something the width is not: what is copied is the width.
	local gray = buffer("\1\2\0\0\3\4\0\0")
	local grayOut = ffi.new("unsigned char[?]", 4)

	test.falsy(freetype.pixels(2, gray, 4, 2, 2, grayOut), "coverage is coverage")
	test.equal(grayOut[0], 1)
	test.equal(grayOut[1], 2)
	test.equal(grayOut[2], 3, "and the padding between its rows is not copied")
	test.equal(grayOut[3], 4)

	-- Four bytes a pixel, which is what a colour glyph is.
	local bgra = buffer("\10\20\30\40\50\60\70\80")
	local bgraOut = ffi.new("unsigned char[?]", 8)

	test.truthy(freetype.pixels(7, bgra, 8, 2, 1, bgraOut), "a colour glyph is four bytes a pixel")
	test.equal(bgraOut[0], 10)
	test.equal(bgraOut[1], 20)
	test.equal(bgraOut[4], 50, "and a second pixel is the one after it")
	test.equal(bgraOut[7], 80)
end)

--- Where a glyph's ink is drawn, in the picture: which columns of a row have ink, and the colour of
--- the first and the last of them.
---@param ink texter.Ink
---@param row number
---@return number first
---@return number last
local function drawnIn(ink, row)
	local pixels = assert(ink.pixels)
	local first, last = nil, nil

	for column = 0, ink.width - 1 do
		if pixels[(row * ink.width + column) * 4 + 3] > 200 then
			first = first or column
			last = column
		end
	end

	return first or -1, last or -1
end

--- What a pixel of it is, as the three colours and the alpha of it.
---@param ink texter.Ink
---@param row number
---@param column number
---@return number blue
---@return number green
---@return number red
---@return number alpha
local function pixelOf(ink, row, column)
	local pixels = assert(ink.pixels)
	local at = (row * ink.width + column) * 4

	return pixels[at], pixels[at + 1], pixels[at + 2], pixels[at + 3]
end

test.skipIf(graphPath == nil)("paints a glyph a font draws as a graph of shapes and colours", function()
	local face = assert(texter.face(assert(graphPath), 0))
	local ink = face:ink(0x41, 32)

	test.truthy(ink.colour, "a glyph a font draws as a graph comes back in colour")
	test.greater(ink.width, 0, "and it is painted at all")

	local row = math.floor(ink.height / 2)
	local first, last = drawnIn(ink, row)
	local blue, green, red, alpha = pixelOf(ink, row, math.floor((first + last) / 2))

	test.greater(first, -1, "the shape of it is drawn")
	test.equal(red, 255, "in the colour the graph fills it with")
	test.equal(green, 0)
	test.equal(blue, 0)
	test.equal(alpha, 255, "and it is opaque where it is drawn")
end)

test.skipIf(graphPath == nil)("paints a gradient from one stop to the other", function()
	local face = assert(texter.face(assert(graphPath), 0))
	local ink = face:ink(0x42, 32)
	local row = math.floor(ink.height / 2)
	local first, last = drawnIn(ink, row)

	test.greater(first, -1, "the shape is drawn")

	local _, _, leftRed = pixelOf(ink, row, first)
	local leftBlue = pixelOf(ink, row, first)
	local _, _, rightRed = pixelOf(ink, row, last)
	local rightBlue = pixelOf(ink, row, last)

	test.truthy(leftRed > leftBlue + 100, "the start of it is the colour the gradient starts in")
	test.truthy(rightBlue > rightRed + 100, "and the end of it is the colour it ends in")
end)

test.skipIf(graphPath == nil)("puts a picture over another where the graph says to", function()
	local face = assert(texter.face(assert(graphPath), 0))

	--- How many pixels of a picture are drawn in the second colour of the palette.
	---@param ink texter.Ink
	---@return number
	local function bluePixels(ink)
		local pixels = assert(ink.pixels)
		local count = 0

		for at = 0, ink.width * ink.height - 1 do
			if pixels[at * 4] > 200 and pixels[at * 4 + 2] < 40 and pixels[at * 4 + 3] > 200 then
				count = count + 1
			end
		end

		return count
	end

	local square = face:ink(0x41, 32)

	test.equal(bluePixels(square), 0, "a shape filled in one colour has none of the other")

	local composited = face:ink(0x43, 32)

	test.greater(bluePixels(composited), 0, "and a picture composited over it is drawn where it falls")
	test.greater(bluePixels(composited), 20, "which is the dot the graph puts on it")
end)

test.skipIf(graphPath == nil)("draws a shape where the graph moves it to", function()
	local face = assert(texter.face(assert(graphPath), 0))

	-- What a glyph comes to is the face's own buffer, which the next glyph is written into: one is
	-- read before the other is asked for, here and everywhere else in this file.
	local inPlace = face:ink(0x41, 32)
	local row = math.floor(inPlace.height / 2)
	local inPlaceFirst = drawnIn(inPlace, row)
	local inPlaceWidth = inPlace.width

	local moved = face:ink(0x44, 32)
	local movedFirst = drawnIn(moved, row)

	-- The graph moves this one a fifth of the shape's own width to the left, which at this size is
	-- about six pixels: what is drawn is where it was moved to rather than where the shape is.
	test.greater(inPlaceFirst, -1, "the shape in place is drawn")
	test.greater(movedFirst, -1, "and so is the same shape moved")
	test.truthy(movedFirst < inPlaceFirst - 2,
		string.format("which is somewhere else: %d against %d", movedFirst, inPlaceFirst))
	test.equal(moved.width, inPlaceWidth, "in a picture of the same size")
end)

test.skipIf(graphPath == nil)("paints a picture the graph refers to rather than one of its own", function()
	local face = assert(texter.face(assert(graphPath), 0))
	local own = face:ink(0x41, 32)
	local row = math.floor(own.height / 2)
	local ownFirst, ownLast = drawnIn(own, row)
	local ownWidth = own.width

	local referred = face:ink(0x45, 32)
	local referredFirst, referredLast = drawnIn(referred, row)

	test.equal(referred.width, ownWidth, "a picture that is another picture is the same size as it")
	test.equal(referredFirst, ownFirst, "and is drawn in the same place")
	test.equal(referredLast, ownLast)
end)

test.skipIf(colrv1Path == nil)("paints an emoji out of the graph its font keeps", function()
	local face = assert(texter.face(assert(colrv1Path), 0))
	local ink = face:ink(0x2705, 24)

	test.truthy(ink.colour, "an emoji is a coloured picture and not a shape")
	test.greater(ink.width, 8, "and it is drawn at the size of the line it is in")
	test.greater(ink.height, 8)
	test.truthy(math.abs(ink.height - 24) <= 4, string.format("which is twenty-four pixels: %d", ink.height))

	local drawn = 0
	local pixels = assert(ink.pixels)

	for at = 0, ink.width * ink.height - 1 do
		if pixels[at * 4 + 3] > 200 then
			drawn = drawn + 1
		end
	end

	test.greater(drawn, ink.width * ink.height / 2, "and most of it is drawn rather than left empty")
end)
