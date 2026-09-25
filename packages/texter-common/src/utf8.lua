-- Reading a string as characters, and where each of them starts.
--
-- A string in Lua is bytes, and the bidi algorithm and HarfBuzz both work in characters: what one
-- needs is a codepoint, and what the other needs back is the byte a glyph came from -- because what
-- a caret, a click and a selection are about is where in the *string* something is, and a string is
-- bytes. Every platform's text API counts in characters of its own as well: UTF-16 units on windows,
-- UTF-16 units on macOS, codepoints in HarfBuzz. Reading a string as characters, and knowing where
-- each of them starts, is what every backend does and none of them should do differently: a caret
-- that lands a byte out is a caret that lands a byte out on every platform together.
--
-- A byte that starts nothing -- a stray continuation byte, or a sequence the string ends in the
-- middle of -- is read as the character that says so and takes one byte with it, so a string that
-- is not text costs one character a byte and never loses where the next one begins.
--
-- Three things are read out of a string here, and each of them is a buffer as long as the string in
-- *bytes* and no longer:
--
--   characters  the codepoints of it, and the byte each starts at
--   units       the UTF-16 units of it, and the byte each starts at
--   decode      one character at a time, for a caller walking a string itself
--
-- The first two are buffers this module keeps and hands out, grown to the longest string it has been
-- asked about: reading a line is then a walk over its bytes and nothing else, which is what a screen
-- that reshapes its text every frame needs. What that costs a caller is one rule: what comes back is
-- this module's own, so it is read before the next call rather than kept. `decode` is the one for a
-- caller that wants to keep what it read.
local ffi = require("ffi")

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

--- The characters of a string, and the byte each of them starts at.
---@class texter.Characters
---@field codepoints ffi.cdata* # uint32_t[]: the characters, from nought
---@field offsets ffi.cdata* # uint32_t[]: the byte each starts at, from one
---@field count number

--- The UTF-16 units of a string, and the byte each of them starts at.
---@class texter.Units
---@field units ffi.cdata* # uint16_t[]: the units, from nought
---@field offsets ffi.cdata* # uint32_t[]: the byte each starts at, from one
---@field count number

--- The longest string these buffers have been grown for, which is as many characters or units as a
--- string of that many bytes can have.
local room = 0

---@type ffi.cdata*
local codepoints, characterOffsets, units, unitOffsets = nil, nil, nil, nil

---@type texter.Characters
local characters = { codepoints = nil, offsets = nil, count = 0 }

---@type texter.Units
local wide = { units = nil, offsets = nil, count = 0 }

--- Grows what is kept to hold a string of this many bytes.
---@param bytes number
local function grow(bytes)
	if room >= bytes then
		return
	end

	room = bytes
	codepoints = ffi.new("uint32_t[?]", room)
	characterOffsets = ffi.new("uint32_t[?]", room)
	units = ffi.new("uint16_t[?]", room)
	unitOffsets = ffi.new("uint32_t[?]", room)
end

--- The characters of a string, and the byte each of them starts at: two arrays, so that a glyph
--- HarfBuzz reports as the fourth character of a run can be said to be at the seventh byte of the
--- line, which is what a caret is placed from.
---
--- What comes back is a buffer this module keeps: it is read before the next call.
---@param text string
---@return texter.Characters
function utf8.characters(text)
	local bytes = #text

	grow(bytes)

	local at, count = 1, 0

	while at <= bytes do
		local codepoint, after = utf8.decode(text, at)

		codepoints[count] = codepoint
		characterOffsets[count] = at
		count = count + 1
		at = after
	end

	characters.codepoints, characters.offsets, characters.count = codepoints, characterOffsets, count

	return characters
end

--- The UTF-16 a string is, and the byte each of its units starts at: what windows and macOS count a
--- line in is units of their own, and what a caret, a click and a selection are about is the byte of
--- a Lua string. A character outside the basic plane -- which every emoji is -- is two units, and
--- both of them are the byte the character starts at.
---
--- What comes back is a buffer this module keeps: it is read before the next call.
---@param text string
---@return texter.Units
function utf8.units(text)
	local bytes = #text

	grow(bytes)

	local at, count = 1, 0

	while at <= bytes do
		local codepoint, after = utf8.decode(text, at)

		if codepoint < 0x10000 then
			units[count] = codepoint
			unitOffsets[count] = at
			count = count + 1
		else
			local point = codepoint - 0x10000

			units[count] = 0xD800 + math.floor(point / 0x400)
			unitOffsets[count] = at
			count = count + 1
			units[count] = 0xDC00 + point % 0x400
			unitOffsets[count] = at
			count = count + 1
		end

		at = after
	end

	wide.units, wide.offsets, wide.count = units, unitOffsets, count

	return wide
end

--- The UTF-8 a codepoint is, which is what a platform given a character as a string is handed: a
--- codepoint rather than a string, because what is being asked about is one character of a line.
---@param codepoint number
---@return string
function utf8.encode(codepoint)
	if codepoint < 0x80 then
		return string.char(codepoint)
	elseif codepoint < 0x800 then
		return string.char(0xC0 + math.floor(codepoint / 0x40), 0x80 + codepoint % 0x40)
	elseif codepoint < 0x10000 then
		return string.char(0xE0 + math.floor(codepoint / 0x1000), 0x80 + math.floor(codepoint / 0x40) % 0x40,
			0x80 + codepoint % 0x40)
	end

	return string.char(0xF0 + math.floor(codepoint / 0x40000), 0x80 + math.floor(codepoint / 0x1000) % 0x40,
		0x80 + math.floor(codepoint / 0x40) % 0x40, 0x80 + codepoint % 0x40)
end

return utf8
