-- What a machine's text libraries answer with.
--
--   lde run
--   lde run -- "مرحبا" "日本語" 24     -- another line, at another size
--
-- This is both the example and the thing to run on a machine whose backend has never been run
-- there: it prints which backend was picked, what the font it found says about its lines, and the
-- glyphs of each line it was given -- where they are and which byte of the string each came from.
local texter = require("texter")

-- What a machine to be tested on is likely to have, in the order it is looked for: a font of the
-- system's own, which every one of them has.
local FONTS = {
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"/System/Library/Fonts/Helvetica.ttc",
	"/Library/Fonts/Arial.ttf",
	"C:/Windows/Fonts/arial.ttf",
	"C:/Windows/Fonts/segoeui.ttf",
}

-- Lines that ask different things of a shaper: letters that join within a word, letters that kern
-- and ligate, a line of two directions, a line of characters outside latin, and one that is empty.
local SAMPLES = { "hello", "AV fi", "مرحبا", "abc مرحبا abc", "日本語", "" }

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

print(string.format("texter: %s  backend: %s", tostring(texter.available()), tostring(texter.name)))

if not texter.available() then
	print("  why: " .. tostring(texter.why()))
	os.exit(1)
end

local path = aFont()

if path == nil then
	print("no font found to shape with")
	os.exit(1)
end

local face = assert(texter.face(path))

print(string.format("font: %s", path))
print("")

for _, sample in ipairs(SAMPLES) do
	local line = texter.shape(face, sample, 24)
	local ascent, descent, gap = texter.metrics(face, 24)

	print(string.format("%-18s %d glyphs  width %.2f  rtl %s  line %.2f (%.2f/%.2f+%.2f)  runs %d",
		string.format("[%s]", sample), #line.glyphs, line.width, tostring(line.rtl), ascent - descent, ascent,
		descent, gap, #line.runs))

	for index, glyph in ipairs(line.glyphs) do
		local ink = texter.ink(face, glyph.glyph, 24)

		print(string.format("  %2d. glyph %6d  cluster %3d  x %7.2f  advance %6.2f  ink %dx%d at %d,%d",
			index, glyph.glyph, glyph.cluster, glyph.x, glyph.advance, ink.width, ink.height, ink.left, ink.top))
	end
end
