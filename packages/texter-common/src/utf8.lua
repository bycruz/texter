-- Reading a string as characters, and where each of them starts.
--
-- A string in Lua is bytes, and the bidi algorithm and HarfBuzz both work in characters: what one
-- needs is a codepoint, and what the other needs back is the byte a glyph came from -- because what
-- a caret and a click are about is where in the *string* something is, and a string is bytes.
--
-- A byte that starts nothing -- a stray continuation byte, or a sequence the string ends in the
-- middle of -- is read as the character that says so and takes one byte with it, so a string that
-- is not text costs one character a byte and never loses where the next one begins.
local utf8 = {}

--- One character of a string, and where the one after it starts.
---@param text string
---@param at number # Which byte to read from, from one
---@return number codepoint
---@return number after
function utf8.decode(text, at)
	local first = text:byte(at)

	if first == nil then
		return 0xFFFD, at + 1
	end

	if first < 0x80 then
		return first, at + 1
	end

	local count, codepoint

	if first >= 0xF0 then
		count, codepoint = 3, first % 0x08
	elseif first >= 0xE0 then
		count, codepoint = 2, first % 0x10
	elseif first >= 0xC0 then
		count, codepoint = 1, first % 0x20
	else
		return 0xFFFD, at + 1
	end

	for step = 1, count do
		local byte = text:byte(at + step)

		if byte == nil or byte < 0x80 or byte >= 0xC0 then
			return 0xFFFD, at + 1
		end

		codepoint = codepoint * 0x40 + byte % 0x40
	end

	return codepoint, at + count + 1
end

--- The characters of a string, and the byte each of them starts at: two arrays, so that a glyph
--- HarfBuzz reports as the fourth character of a run can be said to be at the seventh byte of the
--- line, which is what a caret is placed from.
---@class texter.Characters
---@field codepoints number[]
---@field offsets number[] # The byte each character starts at, from one
---@field count number

---@param text string
---@return texter.Characters
function utf8.characters(text)
	local codepoints, offsets = {}, {}
	local at, count = 1, 0

	while at <= #text do
		local codepoint, after = utf8.decode(text, at)

		count = count + 1
		codepoints[count] = codepoint
		offsets[count] = at
		at = after
	end

	return { codepoints = codepoints, offsets = offsets, count = count }
end

return utf8
