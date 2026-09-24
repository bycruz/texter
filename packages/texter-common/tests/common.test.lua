-- Reading a string as characters, and a font file as the name it calls itself.
--
-- The first half is hermetic -- what a string is as characters is a question about the string -- and
-- the second half needs a font on the machine, which it skips where there is none.
local test = require("lde-test")

local common = require("texter-common")
local utf8, sfnt = common.utf8, common.sfnt

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

test.it("reads one character of a string, and where the next one starts", function()
	local codepoint, after = utf8.decode("a", 1)

	test.equal(codepoint, 0x61)
	test.equal(after, 2)

	codepoint, after = utf8.decode("ö", 1)
	test.equal(codepoint, 0xF6, "two bytes are one character")
	test.equal(after, 3)

	codepoint, after = utf8.decode("日", 1)
	test.equal(codepoint, 0x65E5, "and three are one")

	codepoint, after = utf8.decode("😀", 1)
	test.equal(codepoint, 0x1F600, "and four are one")
	test.equal(after, 5)
end)

test.it("reads a byte that starts nothing as the character that says so", function()
	local codepoint, after = utf8.decode("\128a", 1)

	test.equal(codepoint, 0xFFFD, "a stray continuation byte is not text")
	test.equal(after, 2, "and takes one byte with it, so the next character is not lost")

	test.equal(utf8.decode("\228\184", 1), 0xFFFD, "and a sequence the string ends in the middle of")
end)

test.it("says where in the string each character is", function()
	local characters = utf8.characters("a日b")

	test.equal(characters.count, 3)
	test.equal(characters.offsets[1], 1, "the first is the first byte")
	test.equal(characters.offsets[2], 2, "and the one after a three byte character is the fourth")
	test.equal(characters.offsets[3], 5)
	test.equal(characters.codepoints[2], 0x65E5)
end)

test.it("reads nothing out of a string that is not there", function()
	local characters = utf8.characters("")

	test.equal(characters.count, 0)
	test.equal(#characters.offsets, 0)
end)

test.skipIf(fontPath == nil)("reads the family a font file says it is", function()
	local file = assert(io.open(assert(fontPath), "rb"))
	local content = file:read("*all")

	file:close()

	local family = sfnt.family(content)

	test.truthy(family ~= nil, "a font says what it is called")
	test.truthy(#assert(family) > 0, "and it is a name: " .. tostring(family))
end)

test.it("reads no family out of what is not a font", function()
	test.equal(sfnt.family(""), nil)
	test.equal(sfnt.family("this is not a font at all, it is a sentence"), nil)
	test.equal(sfnt.family(string.rep("\0", 64)), nil)
end)
