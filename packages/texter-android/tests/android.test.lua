-- What Android's own text stack answers with, through texter-android.
--
-- These run inside an Android app and nowhere else: the backend draws through the app's Java
-- framework, so a machine without one skips rather than fails. `examples/android-tests` is the app
-- that runs them on a phone.
local test = require("lde-test")

local ok, texter = pcall(require, "texter-android")

---@cast texter table

local isHere = ok and texter.available()

local FONTS = {
	"/system/fonts/Roboto-Regular.ttf",
	"/system/fonts/RobotoStatic-Regular.ttf",
	"/system/fonts/NotoSans-Regular.ttf",
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

local fontPath = isHere and aFont() or nil
local arabicPath = "/system/fonts/NotoNaskhArabic-Regular.ttf"
local emojiPath = "/system/fonts/NotoColorEmoji.ttf"

---@param path string
local function exists(path)
	local file = io.open(path, "rb")
	if file then file:close() end
	return file ~= nil
end

local face = fontPath and assert(texter.face(fontPath, 0)) or nil
local arabic = isHere and exists(arabicPath) and assert(texter.face(arabicPath, 0)) or nil
local emoji = isHere and exists(emojiPath) and assert(texter.face(emojiPath, 0)) or nil

test.skipIf(not ok or not isHere)("loads the framework it draws with", function()
	test.truthy(texter.available(), tostring(texter.why()))
	test.equal(texter.why(), nil)
end)

test.skipIf(face == nil)("reads a font, and says a line of it is as tall as asked", function()
	---@cast face -nil
	local ascent, descent = texter.metrics(face, 32)
	test.truthy(ascent > 0, "ascent " .. ascent)
	test.truthy(descent < 0, "descent " .. descent)
	test.truthy(math.abs((ascent - descent) - 32) < 0.5, "line height " .. (ascent - descent))
	test.truthy(face:hasGlyph(0x41), "Roboto draws A")
	test.falsy(face:hasGlyph(0x10FFFF), "nor does it draw a noncharacter")
end)

test.skipIf(face == nil)("gives the ink of a glyph, and none for a space", function()
	---@cast face -nil
	local ink = face:ink(0x41, 32)
	test.truthy(ink.width > 4 and ink.height > 10, ink.width .. "x" .. ink.height)
	test.truthy(ink.top < 0, "an A sits above the baseline: top " .. ink.top)

	local covered = 0
	for index = 0, ink.width * ink.height - 1 do
		if ink.pixels[index] > 128 then covered = covered + 1 end
	end
	test.truthy(covered > 20, "an A has ink in it: " .. covered .. " pixels")

	local space = face:ink(0x20, 32)
	test.equal(space.width, 0)
end)

test.skipIf(face == nil)("draws a glyph the right way up", function()
	---@cast face -nil
	-- A T is a bar at the top and a stem below it: its top row is wider than its bottom row.
	local ink = face:ink(0x54, 48)
	local function rowInk(row)
		local count = 0
		for column = 0, ink.width - 1 do
			if ink.pixels[row * ink.width + column] > 128 then count = count + 1 end
		end
		return count
	end
	local top, bottom = 0, 0
	for row = 0, 3 do top = math.max(top, rowInk(row + 1)) end
	for row = ink.height - 5, ink.height - 2 do bottom = math.max(bottom, rowInk(row)) end
	test.truthy(top > bottom * 2, "top row " .. top .. ", bottom row " .. bottom)
end)

test.skipIf(face == nil)("shapes a line into the glyphs it is drawn from", function()
	---@cast face -nil
	local line = texter.shape(face, "Hello", 24)
	test.equal(#line.glyphs, 5)
	test.equal(line.glyphs[1].glyph, face:glyphFor(0x48), "the first glyph is H")
	test.equal(line.glyphs[1].cluster, 0)
	test.equal(line.glyphs[5].cluster, 4)
	test.truthy(line.width > 40, "width " .. line.width)
	for index = 2, 5 do
		test.truthy(line.glyphs[index].x > line.glyphs[index - 1].x, "glyphs go left to right")
	end
	test.falsy(line.rtl)
end)

test.skipIf(face == nil)("lets the font kern, which is what it is for", function()
	---@cast face -nil
	-- Roboto kerns AV: the pair is narrower than its glyphs' advances laid end to end.
	local pair = texter.shape(face, "AV", 48).width
	local apart = face:advance(0x41, 48) + face:advance(0x56, 48)
	test.truthy(pair < apart - 0.5, "AV " .. pair .. " against " .. apart)
end)

test.skipIf(face == nil)("counts a cluster in bytes of the line, not in characters", function()
	---@cast face -nil
	local line = texter.shape(face, "aéb", 24)
	test.equal(#line.glyphs, 3)
	test.equal(line.glyphs[1].cluster, 0)
	test.equal(line.glyphs[2].cluster, 1)
	test.equal(line.glyphs[3].cluster, 3, "é is two bytes")
end)

test.skipIf(face == nil)("puts a caret where a byte of the line is", function()
	---@cast face -nil
	local line = texter.shape(face, "abc", 24)
	test.equal(texter.penOf(line, 0), 0)
	test.truthy(math.abs(texter.penOf(line, 1) - line.glyphs[1].advance) < 0.01)
	test.equal(texter.penOf(line, 3), line.width)
	test.equal(texter.byteAt(line, 0.5), 0)
	test.equal(texter.byteAt(line, line.width + 10), 4)
end)

test.skipIf(face == nil)("reads the same face from its bytes", function()
	---@cast face -nil
	local file = assert(io.open(assert(fontPath), "rb"))
	local content = file:read("*a")
	file:close()
	local fromBytes = assert(texter.faceBytes(content, 0))
	local a = texter.shape(face, "Hello", 24)
	local b = texter.shape(fromBytes, "Hello", 24)
	test.equal(a.width, b.width)
	test.equal(fromBytes:ink(0x41, 24).width, face:ink(0x41, 24).width)
end)

test.skipIf(arabic == nil)("shapes Arabic in the order it is drawn in", function()
	---@cast arabic -nil
	-- مرحبا: five letters, joined, set right to left. The first byte of the word is drawn last.
	local text = "مرحبا"
	local line = texter.shape(arabic, text, 32)
	test.truthy(line.rtl, "the line reads right to left")
	test.truthy(#line.glyphs >= 4, #line.glyphs .. " glyphs")
	test.equal(line.glyphs[#line.glyphs].cluster, 0, "the rightmost glyph is the first letter")
	test.equal(line.glyphs[1].cluster > 0, true, "the leftmost one is a later letter")

	-- Joined: the initial form of م is not the glyph of م on its own.
	local alone = texter.shape(arabic, "م", 32).glyphs[1].glyph
	test.notEqual(line.glyphs[#line.glyphs].glyph, alone, "the first letter takes its joined form")
end)

test.skipIf(arabic == nil or face == nil)("arranges a line of two directions, which is what the bidi algorithm is for", function()
	---@cast arabic -nil
	local text = "abc مرحبا def"
	local line = texter.shape(arabic, text, 24)
	test.falsy(line.rtl, "a line that starts in English reads left to right")
	test.equal(#line.runs, 3)
	test.falsy(line.runs[1].rtl)
	test.truthy(line.runs[2].rtl)
	test.falsy(line.runs[3].rtl)
	test.equal(line.glyphs[1].cluster, 0, "abc is drawn first")
	test.equal(line.glyphs[#line.glyphs].cluster, #text - 1, "def is drawn last")
end)

test.skipIf(emoji == nil)("draws an emoji in its own colours", function()
	---@cast emoji -nil
	local ink = emoji:ink(0x1F600, 48)
	test.truthy(ink.colour, "a colour glyph comes back as colour")
	test.truthy(ink.width > 20 and ink.height > 20, ink.width .. "x" .. ink.height)

	-- 😀 is yellow: somewhere in it, red and green are high and blue is low (BGRA order).
	local yellow = 0
	for index = 0, ink.width * ink.height - 1 do
		local b, g, r, a = ink.pixels[index * 4], ink.pixels[index * 4 + 1], ink.pixels[index * 4 + 2],
			ink.pixels[index * 4 + 3]
		if a > 200 and r > 180 and g > 140 and b < 100 then yellow = yellow + 1 end
	end
	test.truthy(yellow > 50, yellow .. " yellow pixels")
end)

test.skipIf(emoji == nil)("counts an emoji in bytes of the line, which is four of them", function()
	---@cast emoji -nil
	local line = texter.shape(emoji, "😀😀", 32)
	test.equal(#line.glyphs, 2)
	test.equal(line.glyphs[1].cluster, 0)
	test.equal(line.glyphs[2].cluster, 4)
end)

test.skipIf(emoji == nil)("shapes a sequence of emoji joined by a zero width joiner", function()
	---@cast emoji -nil
	-- 👩‍💻: woman, ZWJ, laptop -- one glyph.
	local line = texter.shape(emoji, "👩‍💻", 32)
	test.equal(#line.glyphs, 1, #line.glyphs .. " glyphs")
	test.equal(line.glyphs[1].cluster, 0)
end)
