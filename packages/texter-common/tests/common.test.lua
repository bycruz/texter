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
	test.equal(characters.codepoints[0], 0x61, "the first character is the first")
	test.equal(characters.offsets[0], 1, "and starts at the first byte")
	test.equal(characters.codepoints[1], 0x65E5)
	test.equal(characters.offsets[1], 2, "the one after it starts at the second byte")
	test.equal(characters.codepoints[2], 0x62)
	test.equal(characters.offsets[2], 5, "and a three byte character takes three")
end)

test.it("reads an emoji as one character of four bytes", function()
	local characters = utf8.characters("😀!")

	test.equal(characters.count, 2, "a character outside the basic plane is one character")
	test.equal(characters.codepoints[0], 0x1F600)
	test.equal(characters.offsets[0], 1)
	test.equal(characters.codepoints[1], 0x21)
	test.equal(characters.offsets[1], 5, "and the byte after it is the fifth")
end)

test.it("reads nothing out of a string that is not there", function()
	local characters = utf8.characters("")

	test.equal(characters.count, 0)
end)

test.it("reads a string as the UTF-16 a platform counts a line in", function()
	local units = utf8.units("a😀b")

	test.equal(units.count, 4, "an emoji is two units")
	test.equal(units.units[0], 0x61)
	test.equal(units.offsets[0], 1)
	test.equal(units.units[1], 0xD83D, "the high half of the pair")
	test.equal(units.units[2], 0xDE00, "and the low half of it")
	test.equal(units.offsets[1], 2, "both of which are the byte the character starts at")
	test.equal(units.offsets[2], 2)
	test.equal(units.units[3], 0x62)
	test.equal(units.offsets[3], 6, "and the byte after an emoji is the sixth")
end)

test.it("writes a codepoint back out as the bytes it is", function()
	test.equal(utf8.encode(0x61), "a")
	test.equal(utf8.encode(0xF6), "ö")
	test.equal(utf8.encode(0x65E5), "日")
	test.equal(utf8.encode(0x1F600), "😀")

	local characters = utf8.characters("aö日😀")

	for index = 0, characters.count - 1 do
		test.equal(utf8.encode(characters.codepoints[index]), string.sub("aö日😀", characters.offsets[index],
			characters.offsets[index] + #utf8.encode(characters.codepoints[index]) - 1),
			string.format("character %d is the bytes it came from", index))
	end
end)

test.it("hands the same buffer back rather than a table a call", function()
	local first = utf8.characters("abc")
	local second = utf8.characters("de")

	test.equal(first, second, "what comes back is the buffer this module keeps")
	test.equal(second.count, 2, "and it says what the last call read")
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
