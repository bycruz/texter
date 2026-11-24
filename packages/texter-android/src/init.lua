-- texter-android: the text an Android app already has.
--
--   local texter = require("texter-android")
--   local face = assert(texter.face("/system/fonts/Roboto-Regular.ttf"))
--   local line = texter.shape(face, "مرحبا بالعالم", 24)
--
-- Android does not let an app load its FreeType and HarfBuzz -- they are private libraries -- but
-- it hands an app the text stack they are part of through its framework, and that is what this
-- uses: `android.graphics.fonts.Font` reads a font, `TextRunShaper` shapes a run of it with
-- Minikin and HarfBuzz, `Canvas.drawGlyphs` draws a glyph with Skia, and ICU's bidi -- the one
-- part of it with a C API an app may load -- cuts a line into runs. Nothing is shipped: what an
-- app brings is these files. It needs Android 12 (API 31), the first with all of them.
--
-- What comes out of `shape` is what every texter backend answers with: the glyphs of a line in the
-- order they are drawn in, where each of them is, and which byte of the string it came from.
local ffi = require("ffi")
local android = require("androidapi")
local utf8 = require("texter-common").utf8

local bidi = require("texter-android.bidi")
local font = require("texter-android.font")

local jni = android.jni

local table_new = require("table.new")

local Units = ffi.typeof("uint16_t[?]")

local texter = {}

--- Whether this machine has what a line is drawn with.
---@return boolean
function texter.available()
	return font.available() and bidi.available()
end

--- What is missing, where something is.
---@return string?
function texter.why()
	return font.why() or bidi.why()
end

texter.face = font.open
texter.faceBytes = font.openBytes

-- What a shaped glyph is in a line: the fields of `texter.Glyph` in a struct rather than in a table.
-- A screen that lays out strings it has not drawn before makes a line for each of them, and a
-- glyph's struct is a fifth of the table it used to be, which is most of what such a line cost the
-- collector. Every backend writes the same struct, so what reads a line reads fields either way.
if not pcall(ffi.typeof, "texter_glyph") then
	ffi.cdef [[
		typedef struct {
			uint32_t glyph;
			uint32_t cluster;
			double x;
			double y;
			double advance;
		} texter_glyph;
	]]
end

local Glyph = ffi.typeof("texter_glyph")

-- A copy of a run's UTF-16 for Java: the units texter-common hands out are its own buffer, and
-- the char[] Java is given is made from this module's.
local runUnits = Units(0)
local runRoom = 0

-- The advances of a run's characters, and where the clusters they make start in the order the
-- glyphs are drawn: buffers grown to the longest run shaped and reused, because a line of new text
-- should not be a buffer a run.
local Advances = ffi.typeof("float[?]")
local Units32 = ffi.typeof("uint32_t[?]")
local advanceRoom = 0
local charAdvances = Advances(0)
local clusterStartAt = Advances(0)
local clusterUnitAt = Units32(0)

--- The first unit of the line that starts at or after `byte`, or the count where none does.
---@param units texter.Units
---@param byte number
---@return number
local function unitAtOrAfter(units, byte)
	local low, high = 0, units.count

	while low < high do
		local middle = math.floor((low + high) / 2)

		if units.offsets[middle] < byte then
			low = middle + 1
		else
			high = middle
		end
	end

	return low
end

--- Where each cluster of a run starts, in the order its glyphs are drawn, and which unit of the run
--- each starts with.
---
--- Android's shaper does not hand out clusters. What it does answer is, for each character of a
--- run, how far the pen moves for it (`Paint.getTextRunAdvances`): a character that is part of a
--- cluster but not its first is nought, and the first of a cluster carries the whole cluster's
--- advance. Laid end to end those are where each cluster starts, and a glyph belongs to the cluster
--- whose start is the last one at or before where the glyph is.
---
--- A run set right to left draws its first character rightmost, so its clusters are read in the
--- order they are drawn: backwards over the characters, adding up the advances from the left.
---@param paint ffi.cdata*
---@param chars ffi.cdata*
---@param length number
---@param rtl boolean
---@return number
local function clusterStarts(paint, chars, length, rtl)
	if length > advanceRoom then
		-- One place a character, since every character can begin a cluster, and one more because
		-- the clusters are counted from one.
		advanceRoom = length
		charAdvances = Advances(advanceRoom)
		clusterStartAt = Advances(advanceRoom + 1)
		clusterUnitAt = Units32(advanceRoom + 1)
	end

	local javaAdvances = jni.floats(charAdvances, length)

	jni.call(paint, "android/graphics/Paint", "getTextRunAdvances", "([CIIIIZ[FI)F", "float",
		chars, 0, length, 0, length, rtl, javaAdvances, 0)
	jni.getFloats(javaAdvances, length, charAdvances)

	local count = 0

	if rtl then
		local pen = 0.0

		for index = length - 1, 0, -1 do
			local advance = charAdvances[index]

			if advance ~= 0 or index == 0 then
				count = count + 1
				clusterStartAt[count] = pen
				clusterUnitAt[count] = index
			end

			pen = pen + advance
		end
	else
		local pen = 0.0

		for index = 0, length - 1 do
			local advance = charAdvances[index]

			if advance ~= 0 or index == 0 then
				count = count + 1
				clusterStartAt[count] = pen
				clusterUnitAt[count] = index
			end

			pen = pen + advance
		end
	end

	return count
end

--- Shapes one run of a line and writes its glyphs into `into` from `at`.
---
--- What the run is, is a stretch of bytes of the line, and the units of the line are in byte order:
--- so the units of the run are found by bisection rather than by walking the line a second time.
---@param paint ffi.cdata*
---@param units texter.Units # The whole line
---@param run texter.Run
---@param x number # Where the run starts, from the start of the line
---@param into texter.Glyph[]
---@param at number
---@return number count, number width
local function shapeRun(paint, units, run, x, into, at)
	local first = unitAtOrAfter(units, run.first)
	local last = unitAtOrAfter(units, run.last + 1) - 1

	if first > last then
		return 0, 0
	end

	local length = last - first + 1
	if length > runRoom then
		runRoom = length
		runUnits = Units(runRoom)
	end
	ffi.copy(runUnits, units.units + first, length * 2)

	local count, width = 0, 0

	assert(jni.frame(function()
		local chars = jni.chars(runUnits, length)
		-- The whole run is the context: what is shaped is the run alone, and what is beside it in
		-- the line is another run in another direction.
		local glyphs = jni.callStatic("android/graphics/text/TextRunShaper", "shapeTextRun",
			"([CIIIIFFZLandroid/graphics/Paint;)Landroid/graphics/text/PositionedGlyphs;",
			chars, 0, length, 0, length, 0.0, 0.0, run.rtl, paint)

		count = jni.call(glyphs, "android/graphics/text/PositionedGlyphs", "glyphCount", "()I", "int")
		width = jni.call(glyphs, "android/graphics/text/PositionedGlyphs", "getAdvance", "()F", "float")

		if count == 0 then
			return true
		end

		local clusters = clusterStarts(paint, chars, length, run.rtl)
		local cluster, startX, entry = 1, 0.0, nil

		for index = 0, count - 1 do
			local glyphX = jni.call(glyphs, "android/graphics/text/PositionedGlyphs", "getGlyphX",
				"(I)F", "float", index)
			local glyphY = jni.call(glyphs, "android/graphics/text/PositionedGlyphs", "getGlyphY",
				"(I)F", "float", index)
			local glyph = jni.call(glyphs, "android/graphics/text/PositionedGlyphs", "getGlyphId",
				"(I)I", "int", index)

			-- The cluster whose box the glyph's origin is in: the last one that starts at or before
			-- it. Both are in draw order, so this is one walk over the two together.
			while cluster < clusters and clusterStartAt[cluster + 1] <= glyphX + 0.5 do
				cluster = cluster + 1
			end

			-- A glyph's advance is how far the next one is from its origin, which is the next
			-- glyph's place rather than a second ask of the shaper for it.
			if entry ~= nil then
				entry.advance = glyphX - startX
			end

			entry = Glyph(glyph, units.offsets[first + clusterUnitAt[cluster]] - 1, x + glyphX,
				glyphY, 0.0)
			into[at + index + 1] = entry
			startX = glyphX
		end

		if entry ~= nil then
			entry.advance = width - startX
		end

		return true
	end, 64 + 8))

	return count, width
end

--- Shapes a line: the glyphs it is drawn from, where each of them goes, and which byte of the line
--- each came from. The line is cut into runs of one direction by ICU, and each run is shaped on its
--- own and placed where the runs before it ended.
---@param face texter.android.Face
---@param text string
---@param pixelHeight number
---@param opts texter.ShapeOpts?
---@return texter.Line
function texter.shape(face, text, pixelHeight, opts)
	-- Read out of texter-common's buffer here and not later: bidi.paragraph reads the same buffer,
	-- and nothing else does in between.
	local units = utf8.units(text)
	local runs, rtl = bidi.paragraph(text, units, opts)
	local paint = face:paint(pixelHeight)

	local glyphs, count, x = table_new(#text, 0), 0, 0.0

	for _, run in ipairs(runs) do
		local shaped, width = shapeRun(paint, units, run, x, glyphs, count)
		count = count + shaped
		x = x + width
	end

	return {
		glyphs = glyphs,
		width = x,
		rtl = rtl,
		runs = runs,
		text = text,
	}
end

--- The ink of one glyph of a font, at a size: what is packed into an atlas.
---@param face texter.android.Face
---@param glyph number
---@param pixelHeight number
---@param opts texter.InkOpts?
---@return texter.Ink
function texter.ink(face, glyph, pixelHeight, opts)
	return face:inkOf(glyph, pixelHeight, opts and opts.offset)
end

--- How tall a line of a font is at a size.
---@param face texter.android.Face
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function texter.metrics(face, pixelHeight)
	return face:metrics(pixelHeight)
end

--- Where in a line a byte is, as the place a caret goes.
---@param line texter.Line
---@param byte number # From one
---@return number
function texter.penOf(line, byte)
	local pen = 0.0
	for _, glyph in ipairs(line.glyphs) do
		if glyph.cluster >= byte then
			return pen
		end
		pen += glyph.advance
	end
	return line.width
end

--- The byte of a line a point is over.
---@param line texter.Line
---@param x number
---@return number
function texter.byteAt(line, x)
	local pen = 0.0
	for _, glyph in ipairs(line.glyphs) do
		if x < pen + glyph.advance / 2 then
			return glyph.cluster
		end
		pen += glyph.advance
	end
	return #line.text + 1
end

--- Skia draws a glyph at a fraction of a pixel, so an atlas may keep a copy per phase.
texter.subpixel = true

---@type texter.Provider
texter.provider = {
	open = font.open,
	openBytes = font.openBytes,
	shape = texter.shape,
	ink = texter.ink,
	metrics = texter.metrics,
	subpixel = true,
}

--- Where wonderland is there, makes this what it draws text with.
---@return boolean installed
function texter.install()
	local ok, fontManager = pcall(require, "wonderland.util.font_manager")
	if not ok then
		return false
	end
	---@cast fontManager texter.FontManager
	fontManager.setProvider(texter.provider)
	return true
end

return texter
