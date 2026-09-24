-- What a font file says about itself: the family name, which is what a platform's own text API
-- usually wants a font named by rather than a path.
--
-- A font is megabytes of outlines behind a two-kilobyte header, and the header is where its names
-- are: the `name` table holds them in every language and encoding the font was made for window, and
-- what a caller wants is the family, for the platform to find the font by. Reading it here rather
-- than through the platform is what keeps this working where the platform has no way to ask -- GDI
-- is given a font by family, and nothing about a file it has just been handed says what it is.
--
-- The tables are found through the offsets in the file's own directory, and everything a file that
-- is not a font would make nonsense of is checked rather than trusted.
local sfnt = {}

--- The four bytes at an offset, as the tag they spell.
---@param content string
---@param at number # From one
---@return string
local function tagAt(content, at)
	return content:sub(at, at + 3)
end

--- A whole number of two bytes, big endian.
---@param content string
---@param at number
---@return number
local function u16(content, at)
	local high, low = content:byte(at, at + 1)

	return (high or 0) * 256 + (low or 0)
end

--- A whole number of four bytes, big endian.
---@param content string
---@param at number
---@return number
local function u32(content, at)
	local a, b, c, d = content:byte(at, at + 3)

	return ((a or 0) * 256 + (b or 0)) * 65536 + (c or 0) * 256 + (d or 0)
end

--- The offset of a table, or nought where the font has none of that name.
---@param content string
---@param wanted string
---@return number? at
local function tableAt(content, wanted)
	if #content < 12 then
		return nil
	end

	-- A collection holds the fonts in it rather than a table directory of its own, and the first of
	-- them is where its directory starts.
	local start = 1

	if tagAt(content, 1) == "ttcf" then
		if #content < 16 then
			return nil
		end

		start = u32(content, 13) + 1
	end

	local count = u16(content, start + 4)

	for index = 0, math.min(count, 512) - 1 do
		local record = start + 12 + index * 16

		if tagAt(content, record) == wanted then
			return u32(content, record + 8) + 1
		end
	end

	return nil
end

--- A string of UTF-16 big endian as UTF-8, which is what a Windows name record holds.
---@param content string
---@return string
local function utf16ToUtf8(content)
	local out = {}

	for index = 1, #content - 1, 2 do
		local code = content:byte(index) * 256 + content:byte(index + 1)

		if code < 0x80 then
			out[#out + 1] = string.char(code)
		elseif code < 0x800 then
			out[#out + 1] = string.char(0xC0 + math.floor(code / 64), 0x80 + code % 64)
		else
			out[#out + 1] = string.char(0xE0 + math.floor(code / 4096), 0x80 + math.floor(code / 64) % 64,
				0x80 + code % 64)
		end
	end

	return table.concat(out)
end

--- The family a font file says it is: the typographic family where it has one, because a family
--- with weights and widths in it states its own name there, and the plain family otherwise.
---@param content string
---@return string? family
function sfnt.family(content)
	local names = tableAt(content, "name")

	if names == nil then
		return nil
	end

	-- A name table of a format this does not know is not one to guess the records of.
	if u16(content, names) ~= 0 and u16(content, names) ~= 1 then
		return nil
	end

	local count = u16(content, names + 2)

	-- Where the strings a record points into start, which is an offset the table states rather than
	-- where its records happen to end.
	local strings = names + u16(content, names + 4)
	local family, subfamily = nil, nil

	for index = 0, math.min(count, 512) - 1 do
		local record = names + 6 + index * 12
		local platform = u16(content, record)
		local identifier = u16(content, record + 6)
		local length = u16(content, record + 8)

		-- Both of these are two bytes: a name is a few hundred bytes at most, and reading four
		-- bytes for the offset would read the next record's platform as part of it.
		local offset = u16(content, record + 10)
		local at = strings + offset

		if at + length - 1 <= #content then
			if platform == 3 and identifier == 16 then
				family = utf16ToUtf8(content:sub(at, at + length - 1))
			elseif platform == 3 and identifier == 1 and family == nil then
				family = utf16ToUtf8(content:sub(at, at + length - 1))
			elseif platform == 3 and identifier == 17 and subfamily == nil then
				subfamily = utf16ToUtf8(content:sub(at, at + length - 1))
			end
		end
	end

	_ = subfamily

	return family
end

return sfnt
