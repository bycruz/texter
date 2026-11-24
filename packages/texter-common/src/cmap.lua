-- The glyph a character is in a font, from the font's own `cmap` table.
--
-- A platform's text API answers this through its shaper, which is a round trip through a whole
-- line for one character. A font states it directly: the `cmap` table maps codepoints to glyph ids
-- in one of a few formats, and a backend that cannot ask the platform cheaply -- Android, whose
-- shaper is behind JNI -- reads the table itself.
--
-- Formats 4 (the Basic Multilingual Plane, in segments) and 12 (every plane, in groups) are what
-- fonts carry for Unicode; a font that has a format 12 subtable is read through it, since it
-- covers what format 4 does and the planes above it, which is where emoji are.
--
-- The bytes are read as they are given: a string is read where it lies, and so is the view a
-- backend maps a font file into, which is what keeps a font of megabytes out of a Lua string -- see
-- `texter.common.Bytes`. A view answers the same questions with the same offsets, from nought.
---@class texter.common.cmap
local cmap = {}

---@param content string | texter.common.Bytes
---@param at number # From nought
local function u16(content, at)
	if type(content) == "string" then
		local high, low = content:byte(at + 1, at + 2)

		return ((high or 0) << 8) | (low or 0)
	end

	---@cast content texter.common.Bytes

	return content:u16(at)
end

---@param content string | texter.common.Bytes
---@param at number # From nought
local function u32(content, at)
	if type(content) == "string" then
		local a, b, c, d = content:byte(at + 1, at + 4)

		return ((a or 0) * 256 + (b or 0)) * 65536 + (c or 0) * 256 + (d or 0)
	end

	---@cast content texter.common.Bytes

	return content:u32(at)
end

---@param content string | texter.common.Bytes
---@param at number # From nought
local function s16(content, at)
	local value = u16(content, at)

	return value >= 0x8000 and value - 0x10000 or value
end

--- The four bytes at an offset, as the tag they spell.
---@param content string | texter.common.Bytes
---@param at number # From nought
---@return string
local function tagAt(content, at)
	if type(content) == "string" then
		return content:sub(at + 1, at + 4)
	end

	---@cast content texter.common.Bytes

	return content:tag(at)
end

--- How many bytes there are.
---@param content string | texter.common.Bytes
---@return number
local function lengthOf(content)
	if type(content) == "string" then
		return #content
	end

	---@cast content texter.common.Bytes

	return content.length
end

--- Where a table starts in the font at `start` (the offset of its table directory), from nought.
---@param content string | texter.common.Bytes
---@param start number
---@param wanted string
local function tableAt(content, start, wanted)
	local count = u16(content, start + 4)

	for index = 0, math.min(count, 512) - 1 do
		local record = start + 12 + index * 16

		if tagAt(content, record) == wanted then
			return u32(content, record + 8)
		end
	end

	return nil
end

--- A lookup from codepoint to glyph id.
---@class texter.common.Cmap
---@field private content string | texter.common.Bytes
---@field private format number
---@field private at number # Where the subtable starts, from nought
---@field private cache table<number, number>
local Cmap = {}
Cmap.__index = Cmap

--- The Unicode mapping of a font, or nil where it has none. `index` is the font of a collection.
---@param content string | texter.common.Bytes
---@param index number?
---@return texter.common.Cmap?
function cmap.of(content, index)
	if lengthOf(content) < 12 then
		return nil
	end

	local start = 0

	if tagAt(content, 0) == "ttcf" then
		local count = u32(content, 8)
		local which = index or 0

		if which >= count then
			return nil
		end

		start = u32(content, 12 + which * 4)
	end

	local table = tableAt(content, start, "cmap")

	if table == nil then
		return nil
	end

	-- The best subtable: a full-repertoire Unicode one (format 12) over a BMP one (format 4).
	local best, bestFormat = nil, nil
	local count = u16(content, table + 2)

	for record = 0, math.min(count, 64) - 1 do
		local entry = table + 4 + record * 8
		local platform = u16(content, entry)
		local encoding = u16(content, entry + 2)
		local at = table + u32(content, entry + 4)
		local format = u16(content, at)
		local isUnicode = platform == 0 or (platform == 3 and (encoding == 1 or encoding == 10))

		if isUnicode and format == 12 then
			best, bestFormat = at, 12
		elseif isUnicode and format == 4 and bestFormat == nil then
			best, bestFormat = at, 4
		end
	end

	if best == nil then
		return nil
	end

	return setmetatable({ content = content, format = bestFormat, at = best, cache = {} }, Cmap)
end

---@param self texter.common.Cmap
---@param codepoint number
local function format4(self, codepoint)
	if codepoint > 0xFFFF then
		return 0
	end

	local content, at = self.content, self.at
	local segments = u16(content, at + 6) / 2
	local ends = at + 14
	local starts = ends + segments * 2 + 2
	local deltas = starts + segments * 2
	local ranges = deltas + segments * 2

	-- The segments are sorted by their end code: the first whose end is at or past the codepoint is
	-- the one it could be in.
	local low, high = 0, segments - 1

	while low < high do
		local middle = math.floor((low + high) / 2)

		if u16(content, ends + middle * 2) < codepoint then
			low = middle + 1
		else
			high = middle
		end
	end

	local first = u16(content, starts + low * 2)

	if codepoint < first or codepoint > u16(content, ends + low * 2) then
		return 0
	end

	local delta = s16(content, deltas + low * 2)
	local rangeAt = ranges + low * 2
	local range = u16(content, rangeAt)

	if range == 0 then
		return (codepoint + delta) % 0x10000
	end

	local glyph = u16(content, rangeAt + range + (codepoint - first) * 2)

	return glyph == 0 and 0 or (glyph + delta) % 0x10000
end

---@param self texter.common.Cmap
---@param codepoint number
local function format12(self, codepoint)
	local content, at = self.content, self.at
	local groups = u32(content, at + 12)
	local low, high = 0, groups - 1

	while low <= high do
		local middle = math.floor((low + high) / 2)
		local group = at + 16 + middle * 12
		local first = u32(content, group)

		if codepoint < first then
			high = middle - 1
		elseif codepoint > u32(content, group + 4) then
			low = middle + 1
		else
			return u32(content, group + 8) + (codepoint - first)
		end
	end

	return 0
end

--- The glyph id of a codepoint, or nought where the font does not draw it.
---@param codepoint number
---@return number
function Cmap:glyph(codepoint)
	local known = self.cache[codepoint]

	if known ~= nil then
		return known
	end

	local glyph = self.format == 12 and format12(self, codepoint) or format4(self, codepoint)

	self.cache[codepoint] = glyph

	return glyph
end

return cmap
