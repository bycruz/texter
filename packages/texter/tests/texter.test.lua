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
