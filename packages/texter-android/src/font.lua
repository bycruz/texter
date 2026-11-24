-- A font file read by Android's own text stack, and the ink of its glyphs.
--
-- What reads a font here is `android.graphics.fonts.Font` (API 29), built from the file or from
-- the font's bytes, and what draws a glyph is `Canvas.drawGlyphs` (API 31) -- Skia, with the same
-- FreeType and the same colour-glyph support the system draws its own text with. A glyph is drawn
-- into a bitmap this face keeps and read back with `AndroidBitmap_lockPixels`: coverage into one
-- byte a pixel, and a colour glyph -- an emoji -- into four.
--
-- None of this is in the NDK: every call goes through JNI, which costs a few microseconds a call.
-- What is asked of a face often -- whether it has a glyph, which glyph a codepoint is -- is read
-- from the font's own cmap table instead (`texter-common.cmap`), and nothing per glyph goes
-- through Java more than once per size: the atlas a caller packs into keeps what it was handed.
local ffi = require("ffi")
local android = require("androidapi")
local common = require("texter-common")

local jni = android.jni
local cmap = common.cmap

ffi.cdef [[
	typedef struct {
		uint32_t width;
		uint32_t height;
		uint32_t stride;
		int32_t format;
		uint32_t flags;
	} texter_android_bitmap_info;

	int AndroidBitmap_getInfo(void *env, void *bitmap, texter_android_bitmap_info *info);
	int AndroidBitmap_lockPixels(void *env, void *bitmap, void **pixels);
	int AndroidBitmap_unlockPixels(void *env, void *bitmap);
]]

local graphicsLoaded, graphics = pcall(ffi.load, "jnigraphics")

local ByteArray = ffi.typeof("uint8_t[?]")
local BitmapInfo = ffi.typeof("texter_android_bitmap_info")
local PixelsOut = ffi.typeof("void*[1]")
local GlyphIds = ffi.typeof("int32_t[1]")
local Positions = ffi.typeof("float[2]")

-- What maps a font file into the app: POSIX's mmap, which Android has and which is the difference
-- between a face reading a font and a face holding a copy of one. The names are this module's own
-- rather than the C library's, so a second module declaring the same call in the same process does
-- not have to agree with this one about it.
local isPosix = ffi.os ~= "Windows"

if isPosix then
	ffi.cdef [[
		int texter_android_open(const char *path, int flags, ...) __asm__("open");
		int texter_android_close(int fd) __asm__("close");
		long texter_android_lseek(int fd, long offset, int whence) __asm__("lseek");
		void *texter_android_mmap(void *address, size_t length, int protection, int flags, int fd,
			long offset) __asm__("mmap");
		int texter_android_munmap(void *address, size_t length) __asm__("munmap");
	]]
end

local O_RDONLY = 0
local PROT_READ = 1
local MAP_PRIVATE = 2
local SEEK_END = 2

-- The bytes of a font file, where they lie: the mapping of the file, or a string when the platform
-- has no mapping to make. A font is megabytes of tables a line reads a few of, and what reads a
-- font here reads a byte at an offset rather than the whole file kept in a Lua string -- which is
-- what a variable font used to cost for each weight a screen drew it in. Every face made from the
-- same file reads the one mapping, and the mapping goes when the last of them does.
--
-- The offsets are from nought, which is what the font's own tables are written in.
---@class texter.android.Mapped: texter.common.Bytes
---@field length number
---@field pointer ffi.cdata* # uint8_t*: the first byte, and the pointer that unmaps it
local Bytes = {}
Bytes.__index = Bytes

---@param at number # From nought
---@return number
function Bytes:u16(at)
	if at < 0 or at + 1 >= self.length then
		return 0
	end

	local pointer = self.pointer

	return (pointer[at] << 8) | pointer[at + 1]
end

---@param at number # From nought
---@return number
function Bytes:u32(at)
	if at < 0 or at + 3 >= self.length then
		return 0
	end

	local pointer = self.pointer

	return (pointer[at] * 256 + pointer[at + 1]) * 65536 + pointer[at + 2] * 256 + pointer[at + 3]
end

--- The four bytes at an offset, as the tag they spell.
---@param at number # From nought
---@return string
function Bytes:tag(at)
	return self:slice(at, 4)
end

--- A stretch of the bytes. What a font says about itself is read through this, so an offset past
--- the end of the file is answered with what there is rather than with a fault: a font that is not
--- one is a file a user may have, not a reason to take the app down.
---@param at number # From nought
---@param length number
---@return string
function Bytes:slice(at, length)
	if at < 0 then
		length, at = length + at, 0
	end

	if length <= 0 or at >= self.length then
		return ""
	end

	if at + length > self.length then
		length = self.length - at
	end

	return ffi.string(self.pointer + at, length)
end

-- The same view over a string a caller already holds, for a platform that cannot map the file: what
-- reads a font asks a view the same questions on every platform.
---@class texter.android.Text: texter.common.Bytes
---@field length number
---@field data string
local Text = {}
Text.__index = Text

---@param at number # From nought
---@return number
function Text:u16(at)
	local high, low = self.data:byte(at + 1, at + 2)

	return ((high or 0) << 8) | (low or 0)
end

---@param at number # From nought
---@return number
function Text:u32(at)
	local a, b, c, d = self.data:byte(at + 1, at + 4)

	return ((a or 0) * 256 + (b or 0)) * 65536 + (c or 0) * 256 + (d or 0)
end

---@param at number # From nought
---@return string
function Text:tag(at)
	return self.data:sub(at + 1, at + 4)
end

---@param at number # From nought
---@param length number
---@return string
function Text:slice(at, length)
	return self.data:sub(at + 1, at + length)
end

--- A view of the bytes of a string.
---@param content string
---@return texter.android.Text
local function textBytes(content)
	return setmetatable({ data = content, length = #content }, Text)
end

--- A view of bytes a face has copied into memory of its own, which it keeps alive.
---@param buffer ffi.cdata*
---@param length number
---@return texter.android.Mapped
local function memoryBytes(buffer, length)
	return setmetatable({ pointer = ffi.cast("const uint8_t *", buffer), length = length }, Bytes)
end

--- A font file mapped, or nothing where the platform cannot map it.
---@param path string
---@return texter.android.Mapped? bytes
local function mapFile(path)
	if not isPosix then
		return nil
	end

	local descriptor = ffi.C.texter_android_open(path, O_RDONLY)

	if descriptor < 0 then
		return nil
	end

	local length = tonumber(ffi.C.texter_android_lseek(descriptor, 0, SEEK_END))

	if length == nil or length <= 0 then
		ffi.C.texter_android_close(descriptor)

		return nil
	end

	local address = ffi.C.texter_android_mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0)

	ffi.C.texter_android_close(descriptor)

	if address == nil or ffi.cast("intptr_t", address) == -1 then
		return nil
	end

	-- What is kept is the pointer that unmaps: the mapping goes when the last view of it does, and
	-- every read of the bytes goes through it.
	local pointer = ffi.gc(ffi.cast("const uint8_t *", address), function(mapped)
		ffi.C.texter_android_munmap(mapped, length)
	end)

	return setmetatable({ pointer = pointer, length = length }, Bytes)
end

-- Paint.ANTI_ALIAS_FLAG | Paint.SUBPIXEL_TEXT_FLAG.
local PAINT_FLAGS = 0x01 + 0x80

-- Paint.HINTING_OFF: what is drawn is the outline as the font states it, the way FreeType's light
-- target draws it on linux, so a line measured by the shaper is the line the glyphs are drawn at.
local HINTING_OFF = 0

-- A glyph is drawn into a bitmap of at least this many pixels on a side, grown as glyphs need: a
-- bitmap a glyph is a Java object a glyph.
local CANVAS_MIN = 64

-- What an ink is when a glyph has no picture: a space, or a mark a shaper places by an offset.
local NOTHING = { width = 0, height = 0, left = 0, top = 0 }

---@class texter.android.font
local font = {}

---@return number
local function sdkVersion()
	local activity = android.activity()
	return activity ~= nil and activity.sdkVersion or 0
end

--- Whether this Android draws text the way this backend asks: Canvas.drawGlyphs is API 31.
---@return boolean
function font.available()
	return android.isAndroid and graphicsLoaded and sdkVersion() >= 31
end

---@return string?
function font.why()
	if not android.isAndroid then
		return "Not inside an Android app: texter-android draws text through the app's Java framework"
	end
	if not graphicsLoaded then
		return "No libjnigraphics.so: it is what a drawn glyph is read back with"
	end
	if sdkVersion() < 31 then
		return "Android " .. sdkVersion() .. " is older than API 31, the first with Canvas.drawGlyphs"
	end
	return nil
end

--- What is read of a font file rather than of one face of it: its bytes, its cmap, the family it
--- names and the line metrics it states. None of those changes with the weight a variable font is
--- drawn at, so every weight of a file reads the one mapping and the one cmap.
---@class texter.android.FontFile
---@field bytes texter.common.Bytes # Where the font's tables lie, mapped or in memory
---@field cmap texter.common.Cmap? # What a codepoint comes to, or nothing where the font has none
---@field family string? # The family the font says it is
---@field unitsPerEm number
---@field ascender number # In font units: OS/2's typographic ascender where the font asks for it, hhea's otherwise
---@field descender number
---@field lineGap number
---@field colour boolean # Whether it has colour glyph tables, COLR, CBDT or sbix

--- A font file read: the Java Font it is, and what is read of the file rather than of the face.
---@class texter.android.Face: texter.Face
---@field path string
---@field index number
---@field file texter.android.FontFile # The file the face was read from, shared by its every weight
---@field font ffi.cdata* # Global reference to the android.graphics.fonts.Font
---@field typeface ffi.cdata* # Global reference to a Typeface of just this font, for shaping
---@field paints table<number, ffi.cdata*> # Global references to a Paint per pixel height
---@field buffer ffi.cdata*? # Where a font read from bytes lives, which Java reads in place
---@field private room number
---@field private stack ffi.array<ffi.uint8_t>
local Face = {}
Face.__index = Face

--- The offset of a table of the font at `index` of a file, from nought.
---@param source texter.common.Bytes
---@param index number
---@param wanted string
---@return number? at
local function tableAt(source, index, wanted)
	local start = 0
	if source:tag(0) == "ttcf" then
		start = source:u32(12 + index * 4)
	end
	local count = source:u16(start + 4)
	for record = 0, math.min(count, 512) - 1 do
		local entry = start + 12 + record * 16
		if source:tag(entry) == wanted then
			return source:u32(entry + 8)
		end
	end
	return nil
end

---@param source texter.common.Bytes
---@param at number # From nought
---@return number
local function s16(source, at)
	local value = source:u16(at)
	return value >= 0x8000 and value - 0x10000 or value
end

--- The line metrics a font states for itself: what FreeType reads as ascender, descender and
--- height. OS/2's typographic values where the font says to use them, hhea's otherwise -- which
--- is the same choice Android makes for its own lines.
---@param source texter.common.Bytes
---@param index number
---@return number unitsPerEm, number ascender, number descender, number lineGap
local function lineMetrics(source, index)
	local head = tableAt(source, index, "head")
	local unitsPerEm = head and source:u16(head + 18) or 1000

	local os2 = tableAt(source, index, "OS/2")
	if os2 and (source:u16(os2 + 62) & 0x80) ~= 0 then
		return unitsPerEm, s16(source, os2 + 68), s16(source, os2 + 70), s16(source, os2 + 72)
	end

	local hhea = tableAt(source, index, "hhea")
	if hhea then
		return unitsPerEm, s16(source, hhea + 4), s16(source, hhea + 6), s16(source, hhea + 8)
	end

	return unitsPerEm, math.floor(unitsPerEm * 0.8), -math.floor(unitsPerEm * 0.2), 0
end

--- What is read of a font's bytes once, whatever weight draws from them.
---@param source texter.common.Bytes
---@param index number
---@return texter.android.FontFile
local function fileOfBytes(source, index)
	local unitsPerEm, ascender, descender, lineGap = lineMetrics(source, index)

	return {
		bytes = source,
		cmap = cmap.of(source, index),
		family = common.sfnt.family(source),
		unitsPerEm = unitsPerEm,
		ascender = ascender,
		descender = descender,
		lineGap = lineGap,
		colour = tableAt(source, index, "COLR") ~= nil
			or tableAt(source, index, "CBDT") ~= nil
			or tableAt(source, index, "sbix") ~= nil,
	}
end

-- The files read, by where they are and which font of a collection: what a second weight of one
-- file reads rather than maps and parses again. Held weakly, so a file no face draws from any more
-- is unmapped when the collector next runs.
---@type table<string, texter.android.FontFile>
local files = setmetatable({}, { __mode = "v" })

--- The file at a path, read the first time a face of it is made.
---@param path string
---@param index number
---@return texter.android.FontFile? file
---@return string? err
local function fileAt(path, index)
	local key = path .. "\0" .. index
	local known = files[key]

	if known ~= nil then
		return known
	end

	local source = mapFile(path)

	if source == nil then
		-- A platform that cannot map a file, or one the mapping refuses, is read whole as it used to
		-- be: correctness first, and the copy is the cost only where there is no mapping.
		local file = io.open(path, "rb")

		if file == nil then
			return nil, "Could not read " .. path
		end

		local content = file:read("*a")

		file:close()

		if type(content) ~= "string" then
			return nil, "Could not read " .. path
		end

		source = textBytes(content)
	end

	---@cast source -nil

	local made = fileOfBytes(source, index)

	files[key] = made

	return made
end

--- How large the em is, in pixels, for a line `pixelHeight` tall: what a pixel height is here is
--- a line's height, and what the Paint is given is a text size, which is an em.
---@param face texter.android.Face
---@param pixelHeight number
local function emOf(face, pixelHeight)
	local file = face.file
	local line = file.ascender - file.descender
	local scale = line > 0 and pixelHeight / line or pixelHeight / file.unitsPerEm

	return scale * file.unitsPerEm
end

font.emOf = emOf

--- A face from a Java Font that has been built.
---@param javaFont ffi.cdata*
---@param file texter.android.FontFile
---@param path string
---@param index number
---@param buffer ffi.cdata*?
local function fromFont(javaFont, file, path, index, buffer)
	-- A Typeface of this one font and nothing after it: the shaper otherwise falls back to the
	-- system's fonts for a character this one lacks, and those glyph ids are not this face's.
	local typeface = jni.frame(function()
		local family = jni.call(jni.new("android/graphics/fonts/FontFamily$Builder",
				"(Landroid/graphics/fonts/Font;)V", javaFont),
			"android/graphics/fonts/FontFamily$Builder", "build", "()Landroid/graphics/fonts/FontFamily;", "object")
		local builder = jni.new("android/graphics/Typeface$CustomFallbackBuilder",
			"(Landroid/graphics/fonts/FontFamily;)V", family)
		return jni.global(jni.call(builder, "android/graphics/Typeface$CustomFallbackBuilder", "build",
			"()Landroid/graphics/Typeface;", "object"))
	end)

	return setmetatable({
		path = path,
		index = index,
		file = file,
		font = jni.global(javaFont),
		typeface = assert(typeface, "Typeface.CustomFallbackBuilder failed"),
		paints = {},
		buffer = buffer,
		room = 0,
		stack = ByteArray(0),
	}, Face)
end

--- Reads a font file. A variable font -- Android's Roboto is one file for every weight -- is set to
--- `opts.weight` on its weight axis, which is what makes it draw bold; a font with no such axis
--- draws as it is. Nothing of the file is read into a Lua string: what the face parses is the
--- mapping of it, which every weight of it shares.
---@param path string
---@param index number?
---@param opts { weight: number? }?
---@return texter.android.Face? face
---@return string? err
function font.open(path, index, opts)
	local which = index or 0
	local file, err = fileAt(path, which)
	if file == nil then
		return nil, err
	end

	local weight = opts ~= nil and tonumber(opts.weight) or nil

	local made, err = jni.frame(function()
		local builder = jni.new("android/graphics/fonts/Font$Builder", "(Ljava/io/File;)V",
			jni.new("java/io/File", "(Ljava/lang/String;)V", jni.string(path)))
		builder = jni.call(builder, "android/graphics/fonts/Font$Builder", "setTtcIndex",
			"(I)Landroid/graphics/fonts/Font$Builder;", "object", which)
		if weight ~= nil and weight ~= 400 then
			builder = jni.call(builder, "android/graphics/fonts/Font$Builder", "setFontVariationSettings",
				"(Ljava/lang/String;)Landroid/graphics/fonts/Font$Builder;", "object",
				jni.string(string.format("'wght' %d", math.floor(weight))))
			builder = jni.call(builder, "android/graphics/fonts/Font$Builder", "setWeight",
				"(I)Landroid/graphics/fonts/Font$Builder;", "object", math.max(1, math.min(1000, math.floor(weight))))
		end
		local javaFont = jni.call(builder, "android/graphics/fonts/Font$Builder", "build",
			"()Landroid/graphics/fonts/Font;", "object")
		return fromFont(javaFont, file, path, which, nil)
	end)

	if made == nil then
		return nil, path .. " is not a font Android can read: " .. tostring(err)
	end
	return made
end

--- Reads a font from its bytes. Java reads them in place for as long as the face lives, so they are
--- copied into memory the face keeps.
---@param content string
---@param index number?
---@return texter.android.Face? face
---@return string? err
function font.openBytes(content, index)
	local which = index or 0

	-- Copied rather than handed to the constructor as an initialiser: see this repository's AGENTS.md.
	local buffer = ByteArray(#content)
	ffi.copy(buffer, content, #content)

	-- What the face parses is the copy Java reads rather than a second copy of the same bytes in a
	-- Lua string: a font is megabytes, and one of them is enough.
	local file = fileOfBytes(memoryBytes(buffer, #content), which)

	local made, err = jni.frame(function()
		local direct = jni.directBuffer(buffer, #content)
		local builder = jni.new("android/graphics/fonts/Font$Builder", "(Ljava/nio/ByteBuffer;)V", direct)
		builder = jni.call(builder, "android/graphics/fonts/Font$Builder", "setTtcIndex",
			"(I)Landroid/graphics/fonts/Font$Builder;", "object", which)
		local javaFont = jni.call(builder, "android/graphics/fonts/Font$Builder", "build",
			"()Landroid/graphics/fonts/Font;", "object")
		return fromFont(javaFont, file, "<memory>", which, buffer)
	end)

	if made == nil then
		return nil, "the font is not one Android can read: " .. tostring(err)
	end
	return made
end

--- The Paint a face draws and shapes with at a pixel height, made once and kept.
---@param pixelHeight number
function Face:paint(pixelHeight)
	local known = self.paints[pixelHeight]
	if known ~= nil then
		return known
	end

	local paint = assert(jni.frame(function()
		local made = jni.new("android/graphics/Paint", "()V")
		jni.call(made, "android/graphics/Paint", "setFlags", "(I)V", "void", PAINT_FLAGS)
		jni.call(made, "android/graphics/Paint", "setHinting", "(I)V", "void", HINTING_OFF)
		jni.call(made, "android/graphics/Paint", "setTypeface",
			"(Landroid/graphics/Typeface;)Landroid/graphics/Typeface;", "object", self.typeface)
		jni.call(made, "android/graphics/Paint", "setTextSize", "(F)V", "void", emOf(self, pixelHeight))
		-- White, so what an ALPHA_8 bitmap holds is the glyph's coverage and an ARGB one the glyph's
		-- own colours where it has them.
		jni.call(made, "android/graphics/Paint", "setColor", "(I)V", "void", -1)
		return jni.global(made)
	end))

	self.paints[pixelHeight] = paint
	return paint
end

--- The glyph a codepoint is in this font, or nought where it is not one of its own.
---@param codepoint number
---@return number
function Face:glyphFor(codepoint)
	local cmapOf = self.file.cmap

	return cmapOf and cmapOf:glyph(codepoint) or 0
end

--- Whether the font draws this character at all.
---@param codepoint number
---@return boolean
function Face:hasGlyph(codepoint)
	return self:glyphFor(codepoint) ~= 0
end

--- How tall a line of this font is at a size, in pixels: what it reaches above the baseline, what
--- it goes below it (as a negative number), and the gap it asks for between two lines of itself.
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function Face:metrics(pixelHeight)
	local file = self.file
	local scale = emOf(self, pixelHeight) / file.unitsPerEm

	return file.ascender * scale, file.descender * scale, math.max(0, file.lineGap * scale)
end

--- How far the pen moves for a character, in pixels at this size: what Font.getGlyphBounds
--- answers with, besides the box it fills in.
---@param codepoint number
---@param pixelHeight number
---@return number
function Face:advance(codepoint, pixelHeight)
	local paint = self:paint(pixelHeight)
	local glyph = self:glyphFor(codepoint)
	return assert(jni.frame(function()
		return jni.call(self.font, "android/graphics/fonts/Font", "getGlyphBounds",
			"(ILandroid/graphics/Paint;Landroid/graphics/RectF;)F", "float", glyph, paint,
			jni.new("android/graphics/RectF", "()V"))
	end))
end

-- What a glyph is drawn into, kept across glyphs and faces: a bitmap of each kind and the Canvas
-- over it, grown when a glyph does not fit.
---@class texter.android.Canvas
---@field bitmap ffi.cdata*
---@field canvas ffi.cdata*
---@field size number
---@type table<string, texter.android.Canvas>
local canvases = {}

---@param colour boolean
---@param need number
---@return texter.android.Canvas
local function canvasFor(colour, need)
	local kind = colour and "ARGB_8888" or "ALPHA_8"
	local kept = canvases[kind]
	if kept ~= nil and kept.size >= need then
		return kept
	end

	local size = math.max(CANVAS_MIN, kept and kept.size * 2 or 0)
	while size < need do size = size * 2 end

	if kept ~= nil then
		jni.call(kept.bitmap, "android/graphics/Bitmap", "recycle", "()V", "void")
		jni.release(kept.bitmap)
		jni.release(kept.canvas)
	end

	local made = assert(jni.frame(function()
		local config = jni.staticField("android/graphics/Bitmap$Config", kind, "Landroid/graphics/Bitmap$Config;")
		local bitmap = jni.callStatic("android/graphics/Bitmap", "createBitmap",
			"(IILandroid/graphics/Bitmap$Config;)Landroid/graphics/Bitmap;", size, size, config)
		local canvas = jni.new("android/graphics/Canvas", "(Landroid/graphics/Bitmap;)V", bitmap)
		return { bitmap = jni.global(bitmap), canvas = jni.global(canvas), size = size }
	end))

	---@cast made texter.android.Canvas

	canvases[kind] = made
	return made
end

local glyphIds = GlyphIds()
local positions = Positions()
local bitmapInfo = BitmapInfo()
local pixelsOut = PixelsOut()

--- Whether a glyph is one the font draws in colours of its own: a COLR, CBDT or sbix glyph. Asked
--- of the font's tables rather than drawn twice: a font that has any of those draws them for every
--- glyph its colour table covers, and a glyph it has no colours for comes out grey on white.
---@param face texter.android.Face
local function isColourFont(face)
	return face.file.colour
end

--- The ink of a glyph, drawn into the bitmap this module keeps and copied into the buffer this face
--- keeps: what a caller packs into an atlas. A colour glyph comes back as four bytes a pixel in the
--- order FreeType hands them over -- blue, green, red, alpha, premultiplied -- because that is what
--- the texter contract says a colour ink is.
---@param glyph number
---@param pixelHeight number
---@param offset number? # How far right of the pen, in pixels, the glyph's origin sits
---@return texter.Ink
function Face:inkOf(glyph, pixelHeight, offset)
	local paint = self:paint(pixelHeight)
	local colour = isColourFont(self)

	-- The box the glyph's ink is in, relative to its origin: Skia's own answer, so the bitmap is the
	-- size of the glyph rather than of the line.
	local left, top, right, bottom = 0, 0, 0, 0
	assert(jni.frame(function()
		local rect = jni.new("android/graphics/RectF", "()V")
		jni.call(self.font, "android/graphics/fonts/Font", "getGlyphBounds",
			"(ILandroid/graphics/Paint;Landroid/graphics/RectF;)F", "float", glyph, paint, rect)
		left = jni.floatField(rect, "android/graphics/RectF", "left")
		top = jni.floatField(rect, "android/graphics/RectF", "top")
		right = jni.floatField(rect, "android/graphics/RectF", "right")
		bottom = jni.floatField(rect, "android/graphics/RectF", "bottom")
		return true
	end))

	local shift = offset or 0
	local x0 = math.floor(left + shift)
	local y0 = math.floor(top)
	local width = math.ceil(right + shift) - x0
	local height = math.ceil(bottom) - y0

	if width <= 0 or height <= 0 then
		return NOTHING
	end

	-- One pixel of room on each side: what antialiasing spills past the box Skia states.
	x0, y0, width, height = x0 - 1, y0 - 1, width + 2, height + 2

	local target = canvasFor(colour, math.max(width, height))
	local env = jni.env()

	glyphIds[0] = glyph
	positions[0] = shift - x0
	positions[1] = -y0

	assert(jni.frame(function()
		local clear = jni.staticField("android/graphics/PorterDuff$Mode", "CLEAR", "Landroid/graphics/PorterDuff$Mode;")
		jni.call(target.canvas, "android/graphics/Canvas", "drawColor", "(ILandroid/graphics/PorterDuff$Mode;)V",
			"void", 0, clear)
		jni.call(target.canvas, "android/graphics/Canvas", "drawGlyphs",
			"([II[FIILandroid/graphics/fonts/Font;Landroid/graphics/Paint;)V", "void",
			jni.ints(glyphIds, 1), 0, jni.floats(positions, 2), 0, 1, self.font, paint)
		return true
	end))

	assert(graphics.AndroidBitmap_getInfo(env, target.bitmap, bitmapInfo) == 0, "AndroidBitmap_getInfo failed")
	assert(graphics.AndroidBitmap_lockPixels(env, target.bitmap, pixelsOut) == 0, "AndroidBitmap_lockPixels failed")

	local bytes = colour and 4 or 1
	local room = width * height * bytes
	if room > self.room then
		self.room = room
		self.stack = ByteArray(room)
	end

	local from = ffi.cast("uint8_t*", pixelsOut[0])
	local stride = bitmapInfo.stride
	local into = self.stack

	if colour then
		-- ARGB_8888 is red, green, blue, alpha in memory, premultiplied; the contract is FreeType's
		-- blue, green, red, alpha.
		for row = 0, height - 1 do
			local source = from + row * stride
			local dest = into + row * width * 4
			for column = 0, width - 1 do
				local at = column * 4
				dest[at] = source[at + 2]
				dest[at + 1] = source[at + 1]
				dest[at + 2] = source[at]
				dest[at + 3] = source[at + 3]
			end
		end
	else
		for row = 0, height - 1 do
			ffi.copy(into + row * width, from + row * stride, width)
		end
	end

	graphics.AndroidBitmap_unlockPixels(env, target.bitmap)

	return {
		width = width,
		height = height,
		left = x0,
		top = y0,
		pixels = into,
		colour = colour or nil,
	}
end

--- The ink of a character, which is the glyph it comes to.
---@param codepoint number
---@param pixelHeight number
---@param offset number?
---@return texter.Ink
function Face:ink(codepoint, pixelHeight, offset)
	return self:inkOf(self:glyphFor(codepoint), pixelHeight, offset)
end

--- What was handed out is this face's own buffer, which the next glyph is written into.
---@param _ink texter.Ink
function Face:freeInk(_ink)
end

return font
