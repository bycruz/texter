-- The Unicode bidi algorithm, from the fribidi the machine has.
--
-- Shaping a string is HarfBuzz's, but *which* way each part of a line is set is not: a line of
-- Hebrew in a paragraph of English is set right to left *and* placed where the bidi algorithm says
-- it goes, and a number inside Arabic is set left to right inside it. That is a question about the
-- paragraph, answered by the algorithm before anything is shaped: a paragraph is cut into runs, one
-- direction each, and the runs are shaped one at a time and placed in the order this answers with.
--
-- What comes back is in *visual* order -- left to right as a screen draws it -- with each run
-- carrying the direction it is shaped in and the bytes of the string it is made of.
local ffi = require("ffi")

ffi.cdef [[
	typedef uint32_t FriBidiChar;
	typedef int32_t FriBidiStrIndex;
	typedef uint32_t FriBidiParType;
	typedef uint32_t FriBidiCharType;
	typedef int8_t FriBidiLevel;

	void fribidi_get_bidi_types(const FriBidiChar *text, FriBidiStrIndex length, FriBidiCharType *types);
	FriBidiLevel fribidi_get_par_embedding_levels(const FriBidiCharType *types, FriBidiStrIndex length,
		FriBidiParType *base, FriBidiLevel *levels);
]]

-- FRIBIDI_PAR_LTR, FRIBIDI_PAR_RTL and FRIBIDI_PAR_ON, as the header's own arithmetic makes them:
-- the values are flags about the *type* of the base direction rather than an enumeration of it.
local PAR_LTR = 272
local PAR_RTL = 273
local PAR_ON = 64

local NAMES = { "fribidi", "libfribidi.so.0", "libfribidi.0.dylib", "fribidi-0.dll", "libfribidi-0.dll" }

local bidi = {}

local library, reason = nil, nil

for _, name in ipairs(NAMES) do
	local ok, loaded = pcall(ffi.load, name)

	if ok then
		library, bidi.library = loaded, name
		break
	end
end

--- One piece of a line set in one direction: the bytes of the line it is made of, and which way it
--- is drawn. Runs come back in the order a screen draws them, from the left.
---@class texter.Run
---@field first number # The byte of the line it starts at, from one
---@field last number # And the last byte of it
---@field rtl boolean
---@field level number # Its embedding level, which is what its place in the line came from

--- Whether this machine has the fribidi a paragraph is arranged with.
---@return boolean
function bidi.available()
	return library ~= nil
end

--- What is missing, where nothing is.
---@return string?
function bidi.why()
	if library ~= nil then
		return nil
	end

	return reason
		or "No fribidi on this machine: a line of mixed directions is set in one direction without it"
end

--- The ranges a script that is written right to left lives in, which is what a paragraph is guessed
--- to be when there is no fribidi to ask: Hebrew, Arabic, Syriac, Thaana, NKo and the presentation
--- forms.
local RTL_RANGES = {
	{ 0x0590, 0x05FF },
	{ 0x0600, 0x07BF },
	{ 0x0860, 0x08FF },
	{ 0xFB1D, 0xFB4F },
	{ 0xFB50, 0xFDFF },
	{ 0xFE70, 0xFEFF },
	{ 0x10800, 0x10FFF },
	{ 0x1E800, 0x1EFFF },
}

---@param codepoint number
---@return boolean
local function isRtlCodepoint(codepoint)
	for _, range in ipairs(RTL_RANGES) do
		if codepoint >= range[1] and codepoint <= range[2] then
			return true
		end
	end

	return false
end

--- The line as one run of one direction, which is the answer where there is no bidi algorithm to
--- ask: a line whose first strong character is Arabic is set right to left and the rest of it with
--- it, which is what a line of one language wants and what a line of two gets wrong.
---@param text string
---@param characters texter.Characters
---@return texter.Run[]
---@return boolean
local function oneRun(text, characters)
	local rtl = false

	for index = 0, characters.count - 1 do
		local codepoint = characters.codepoints[index]

		-- Letters only: a digit or a space says nothing about the direction of a line.
		if codepoint >= 0x41 then
			rtl = isRtlCodepoint(codepoint)
			break
		end
	end

	return { { first = 1, last = #text, rtl = rtl, level = rtl and 1 or 0 } }, rtl
end

-- What the algorithm is handed and what it answers with, kept and grown rather than made again: a
-- level a character, a type a character, and the base direction of the paragraph. A line is cut into
-- runs once a frame in a screen that rebuilds its view, and three buffers a call are three buffers
-- the collector then has to pay for. None of them leaves this module, so what they hold is read
-- before the next call rather than kept.
local room = 0

---@type ffi.cdata*
local types, levels, base = nil, nil, nil

---@param count number
local function grow(count)
	if room >= count then
		return
	end

	room = count
	types = ffi.new("FriBidiCharType[?]", room)
	levels = ffi.new("FriBidiLevel[?]", room)
	base = base or ffi.new("FriBidiParType[1]")
end

--- A line cut into runs, in the order a screen draws them.
---
--- What a run is is a stretch of the line that is set one way: the algorithm gives every character
--- an embedding level, an odd one is right to left, and a stretch of one parity is one run. The
--- runs come out in visual order, which is the level they are at and the order that leaves them in.
---@param text string
---@param characters texter.Characters
---@param opts { direction: "ltr" | "rtl" | "auto"? }?
---@return texter.Run[] runs
---@return boolean rtl # Whether the line as a whole is set right to left
function bidi.paragraph(text, characters, opts)
	if characters.count == 0 then
		return {}, false
	end

	if library == nil then
		return oneRun(text, characters)
	end

	local count = characters.count

	grow(count)

	-- What a character is -- a letter, a number, a space -- is what the algorithm works on, and what
	-- the characters of the line are is already a buffer of its own: a codepoint of a string read as
	-- UTF-8 is the same number of the same width the algorithm wants.
	library.fribidi_get_bidi_types(characters.codepoints, count, types)

	base[0] = (opts and opts.direction) == "rtl" and PAR_RTL
		or ((opts and opts.direction) == "ltr" and PAR_LTR or PAR_ON)

	library.fribidi_get_par_embedding_levels(types, count, base, levels)

	-- The runs, in the order the line reads in -- which is not the order it is drawn in where any
	-- of it is right to left. What a run covers is the bytes of it: from the byte its first
	-- character starts at to the byte before its next one, or the end of the line.
	local runs, current = {}, nil

	for index = 0, count - 1 do
		local level = levels[index]
		local rtl = level % 2 == 1
		local last = index + 1 < count and characters.offsets[index + 1] - 1 or #text

		if current ~= nil and current.rtl == rtl then
			current.last = last
		else
			current = { first = characters.offsets[index], last = last, rtl = rtl, level = level }
			runs[#runs + 1] = current
		end
	end

	-- L2 of the algorithm, over runs rather than characters: from the deepest level up to the
	-- shallowest odd one, every stretch of runs at that level or deeper is turned around. A run is
	-- one level throughout, so what a stretch of characters is there is a stretch of runs here --
	-- and the runs of a line are one after another in it, so what is turned around is turned around
	-- where they are rather than in a table of their own.
	local deepest = 0
	local shallowestOdd = nil

	for _, run in ipairs(runs) do
		if run.level > deepest then
			deepest = run.level
		end

		if run.rtl and (shallowestOdd == nil or run.level < shallowestOdd) then
			shallowestOdd = run.level
		end
	end

	if shallowestOdd ~= nil then
		for level = deepest, shallowestOdd, -1 do
			local index = 1

			while index <= #runs do
				if runs[index].level >= level then
					local last = index

					while last < #runs and runs[last + 1].level >= level do
						last = last + 1
					end

					local left, right = index, last

					while left < right do
						runs[left], runs[right] = runs[right], runs[left]
						left, right = left + 1, right - 1
					end

					index = last + 1
				else
					index = index + 1
				end
			end
		end
	end

	return runs, base[0] == PAR_RTL
end

return bidi
