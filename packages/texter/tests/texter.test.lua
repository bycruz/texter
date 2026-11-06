-- The one API over whatever the machine has: which backend it picked, and that a caller can shape
-- and measure without knowing which one that is.
local test = require("lde-test")

local texter = require("texter")

local FONTS = {
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/Library/Fonts/Arial.ttf",
	"C:/Windows/Fonts/arial.ttf",
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

--- A font of this machine that draws emoji, which not every font of it does.
local EMOJI = {
	"/usr/share/fonts/google-noto-color-emoji-fonts/Noto-COLRv1.ttf",
	"/usr/share/fonts/truetype/noto/NotoColorEmoji.ttf",
	"/System/Library/Fonts/Apple Color Emoji.ttc",
	"C:/Windows/Fonts/seguiemj.ttf",
}

---@return texter.Face? face
local function anEmojiFace()
	for _, path in ipairs(EMOJI) do
		local file = io.open(path, "rb")

		if file then
			file:close()

			local made, face = pcall(texter.face, path, 0)

			if made and face and face:hasGlyph(0x1F600) then
				return face
			end
		end
	end
end

local emojiFace = anEmojiFace()

test.it("picks the backend its platform is", function()
	test.truthy(texter.name ~= nil, "there is a backend for this platform: " .. tostring(texter.name))

	if texter.name ~= nil then
		test.truthy(texter.backend ~= nil, "and it was installed: " .. tostring(texter.why()))
	end
end)

test.skipIf(not texter.available() or fontPath == nil)("shapes and measures through the one API", function()
	local face = assert(texter.face(assert(fontPath), 0))
	local ascent, descent = texter.metrics(face, 24)

	-- A pixel height is a line height and the metrics are the platform's own, so a size a rasteriser
	-- of whole pixels has no cell for -- which GDI is -- is a pixel out rather than an error.
	test.truthy(math.abs(ascent - descent - 24) <= 1,
		string.format("a line of it is twenty-four pixels tall, and it says %.2f", ascent - descent))

	local line = texter.shape(face, "hello", 24)

	test.equal(#line.glyphs, 5, "five characters are five glyphs where nothing joins")
	test.greater(line.width, 0, "and the line has a width")

	local ink = texter.ink(face, line.glyphs[1].glyph, 24)

	test.greater(ink.width, 0, "and its first glyph has ink")
	test.equal(texter.penOf(line, 0), 0, "the caret before it is at the start of the line")
end)

test.skipIf(not texter.available() or fontPath == nil)("asks for a glyph at a fraction of a pixel", function()
	-- A caller that places a line with the font's own advances asks for each glyph at the fraction of
	-- a pixel the pen is at. A backend that can draw one there says so with `subpixel`; one that
	-- cannot draws it at the whole pixel, and either way what comes back is the glyph's ink.
	local face = assert(texter.face(assert(fontPath), 0))
	local glyph = assert(texter.shape(face, "H", 24).glyphs[1]).glyph
	local ink = texter.ink(face, glyph, 24, { offset = 0.5 })

	test.greater(ink.width, 0, "the glyph has ink at half a pixel")

	if texter.backend.subpixel then
		test.equal(texter.provider.subpixel, true, "and the provider says it draws at a fraction of one")
	end
end)

test.skipIf(not texter.available() or fontPath == nil)("reads and shapes a face from its bytes", function()
	local file = assert(io.open(assert(fontPath), "rb"))
	local content = file:read("*a")

	file:close()

	local face = assert(texter.faceBytes(content, 0))
	local line = texter.shape(face, "hello", 24)

	test.equal(#line.glyphs, 5, "five characters are five glyphs from the same bytes")
	test.greater(line.width, 0, "and the line has a width")
end)

test.skipIf(emojiFace == nil)("shapes an emoji through the one API, whatever backend it went to", function()
	local face = assert(emojiFace)
	local line = texter.shape(face, "😀😀", 24)

	test.equal(#line.glyphs, 2, "two emoji are two glyphs")
	test.equal(line.glyphs[1].cluster, 0, "the first came from the first byte of the line")
	test.equal(line.glyphs[2].cluster, 4, "and the second from the fifth, four bytes later")
	test.greater(texter.penOf(line, 4), 0, "and there is room between them for a caret")
	test.equal(texter.byteAt(line, texter.penOf(line, 4)), 4, "which is placed where the byte is")
end)

test.it("hands out the reader a UI library asks for, where this machine can read a font at all", function()
	if texter.available() then
		test.truthy(texter.provider ~= nil, "a machine with text has something that reads a font")
		test.truthy(type(texter.provider.open) == "function", "which is opened by a path")
		test.truthy(type(texter.provider.openBytes) == "function", "or by the bytes of a font")
	else
		test.equal(texter.provider, nil, "and a machine without it has nothing to hand over")
	end
end)
