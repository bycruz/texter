-- The Unicode bidi algorithm, from the ICU Android gives every app.
--
-- Android ships its own copy of ICU and lets an app link the C API of it through libicu.so, which
-- is one of the libraries an app may load (API 31). That is the bidi algorithm here: a line is
-- cut into runs of one direction each, in the order a screen draws them, and each run is shaped on
-- its own. What comes back is what `texter-freetype.bidi` answers with: runs in visual order, each
-- with the bytes of the line it covers and the direction it is set in.
local ffi = require("ffi")

ffi.cdef [[
	typedef struct UBiDi UBiDi;
	typedef uint8_t UBiDiLevel;
	typedef int32_t UErrorCode;

	UBiDi *ubidi_openSized(int32_t maxLength, int32_t maxRunCount, UErrorCode *errorCode);
	void ubidi_close(UBiDi *bidi);
	void ubidi_setPara(UBiDi *bidi, const uint16_t *text, int32_t length, UBiDiLevel paraLevel,
		UBiDiLevel *embeddingLevels, UErrorCode *errorCode);
	UBiDiLevel ubidi_getParaLevel(const UBiDi *bidi);
	UBiDiLevel ubidi_getLevelAt(const UBiDi *bidi, int32_t charIndex);
	int32_t ubidi_countRuns(UBiDi *bidi, UErrorCode *errorCode);
	int32_t ubidi_getVisualRun(UBiDi *bidi, int32_t runIndex, int32_t *logicalStart, int32_t *length);
]]

-- UBIDI_DEFAULT_LTR: the paragraph takes the direction of its first strong character, left to
-- right where it has none.
local DEFAULT_LTR = 0xFE
local UBIDI_RTL = 1

local Int = ffi.typeof("int32_t[1]")
local Error = ffi.typeof("UErrorCode[1]")

local loaded, icu = pcall(ffi.load, "icu")

---@class texter.android.bidi
local bidi = {}

---@type ffi.cdata*?
local handle = nil
local errorCode = Error()
local runStart = Int()
local runLength = Int()

--- Whether ICU is here, which on Android 12 and later it always is.
---@return boolean
function bidi.available()
	return loaded
end

---@return string?
function bidi.why()
	if loaded then return nil end
	return "No libicu.so: Android 12 (API 31) is the first that lets an app use ICU's C API"
end

--- Cuts a line into runs, in the order a screen draws them.
---
--- `units` is the line as UTF-16 with the byte each unit starts at, which is what ICU counts in
--- and what a run's bytes are found from.
---@param text string
---@param units texter.Units
---@param opts { direction: "ltr" | "rtl" | "auto"? }?
---@return texter.Run[] runs
---@return boolean rtl # Whether the paragraph as a whole is set right to left
function bidi.paragraph(text, units, opts)
	local count = units.count

	if count == 0 then
		return {}, false
	end

	if handle == nil then
		errorCode[0] = 0
		handle = icu.ubidi_openSized(0, 0, errorCode)
		assert(errorCode[0] <= 0 and handle ~= nil, "ubidi_openSized failed")
		ffi.gc(handle, icu.ubidi_close)
	end

	local direction = opts and opts.direction
	local level = direction == "rtl" and 1 or (direction == "ltr" and 0 or DEFAULT_LTR)

	-- ICU keeps a pointer to the text until the next setPara, and `units` is texter-common's own
	-- buffer, which the next string read writes over: everything is read out of ICU before this
	-- returns.
	errorCode[0] = 0
	icu.ubidi_setPara(handle, units.units, count, level, nil, errorCode)
	assert(errorCode[0] <= 0, "ubidi_setPara failed: " .. tostring(errorCode[0]))

	local runCount = icu.ubidi_countRuns(handle, errorCode)
	assert(errorCode[0] <= 0, "ubidi_countRuns failed: " .. tostring(errorCode[0]))

	local runs = {}

	for index = 0, runCount - 1 do
		local runDirection = icu.ubidi_getVisualRun(handle, index, runStart, runLength)
		local first = runStart[0]
		local afterLast = first + runLength[0]
		local lastByte = afterLast < count and units.offsets[afterLast] - 1 or #text

		runs[index + 1] = {
			first = units.offsets[first],
			last = lastByte,
			rtl = runDirection == UBIDI_RTL,
			level = icu.ubidi_getLevelAt(handle, first),
		}
	end

	return runs, icu.ubidi_getParaLevel(handle) % 2 == 1
end

return bidi
