-- CoreText: the text macOS already has.
--
--   local texter = require("texter-coretext")
--
-- One framework does all of it here: CoreText reads a font file, shapes a line -- joining,
-- reordering, bidi, and the language's own rules -- and says where every glyph goes, and
-- CoreGraphics draws a glyph. Nothing is shipped with it: what an app brings is this file.
--
-- It has been run on a mac, and what is written below is what that machine answered with. Two
-- things about it were worked out from the machine rather than read off the documentation, and
-- neither of them is an error when it is wrong: a CFIndex is a long, so a range of a line that is
-- declared as an int is a range CoreText reads out of nothing and answers with -- every glyph of a
-- run coming back nought and no complaint -- and where in a bitmap a glyph's ink goes, whose
-- origin is at the bottom left.
local ffi = require("ffi")
local utf8 = require("texter-common").utf8

ffi.cdef [[
	typedef const void *CFTypeRef;
	typedef const void *CFAllocatorRef;
	typedef struct __CFString *CFStringRef;
	typedef struct __CFURL *CFURLRef;
	typedef struct __CFArray *CFArrayRef;
	typedef struct __CFDictionary *CFDictionaryRef;
	typedef struct __CFAttributedString *CFAttributedStringRef;
	typedef const void *CFDictionaryKeyCallBacks;
	typedef const void *CFDictionaryValueCallBacks;
	typedef unsigned char Boolean;
	typedef double CGFloat;
	typedef unsigned short UniChar;
	typedef unsigned short CGGlyph;
	typedef unsigned int CFStringEncoding;
	// A CFIndex is a long, and not the int it looks like: a range of a line is two of them, sixteen
	// bytes passed by value, and what a half-sized one is handed to CoreText is a range CoreText
	// reads out of whatever was in the registers -- every glyph of a run then comes back nought,
	// every index nought, and nothing about it is an error.
	typedef long CFIndex;
	typedef uint32_t CFOptionFlags;
	typedef long CFTypeID;

	typedef struct { CFIndex location, length; } CFRange;
	typedef struct { CGFloat x, y; } CGPoint;
	typedef struct { CGFloat width, height; } CGSize;
	typedef struct { CGPoint origin; CGSize size; } CGRect;
	typedef struct { CGFloat a, b, c, d, tx, ty; } CGAffineTransform;

	typedef struct __CTFont *CTFontRef;
	typedef struct __CTFontDescriptor *CTFontDescriptorRef;
	typedef struct __CTLine *CTLineRef;
	typedef struct __CTRun *CTRunRef;
	typedef struct __CTTypesetter *CTTypesetterRef;
	typedef struct CGContext *CGContextRef;
	typedef struct CGColorSpace *CGColorSpaceRef;
	typedef struct CGColor *CGColorRef;
	typedef struct CGPath *CGPathRef;

	CFStringRef CFStringCreateWithBytes(CFAllocatorRef allocator, const unsigned char *bytes, CFIndex length,
		CFStringEncoding encoding, Boolean external);
	CFStringRef CFStringCreateWithCString(CFAllocatorRef allocator, const char *bytes, CFStringEncoding encoding);
	CFIndex CFStringGetLength(CFStringRef text);
	void CFStringGetCharacters(CFStringRef text, CFRange range, UniChar *into);
	CFURLRef CFURLCreateFromFileSystemRepresentation(CFAllocatorRef allocator, const unsigned char *path,
		CFIndex length, Boolean isDirectory);
	CFArrayRef CTFontManagerCreateFontDescriptorsFromURL(CFURLRef url);
	CFIndex CFArrayGetCount(CFArrayRef array);
	const void *CFArrayGetValueAtIndex(CFArrayRef array, CFIndex index);
	void CFRelease(CFTypeRef object);
	CFTypeRef CFRetain(CFTypeRef object);

	CTFontRef CTFontCreateWithFontDescriptor(CTFontDescriptorRef descriptor, CGFloat size,
		const CGAffineTransform *matrix);
	CGFloat CTFontGetAscent(CTFontRef font);
	CGFloat CTFontGetDescent(CTFontRef font);
	CGFloat CTFontGetLeading(CTFontRef font);
	CGGlyph CTFontGetGlyphWithName(CTFontRef font, CFStringRef name);
	Boolean CTFontGetGlyphsForCharacters(CTFontRef font, const UniChar *characters, CGGlyph *glyphs, CFIndex count);
	double CTFontGetAdvancesForGlyphs(CTFontRef font, int orientation, const CGGlyph *glyphs, CGSize *advances,
		CFIndex count);
	CGRect CTFontGetBoundingRectsForGlyphs(CTFontRef font, int orientation, const CGGlyph *glyphs, CGRect *rects,
		CFIndex count);
	void CTFontDrawGlyphs(CTFontRef font, const CGGlyph *glyphs, const CGPoint *positions, size_t count,
		CGContextRef context);

	CFAttributedStringRef CFAttributedStringCreate(CFAllocatorRef allocator, CFStringRef text,
		CFDictionaryRef attributes);
	CFDictionaryRef CFDictionaryCreate(CFAllocatorRef allocator, const void **keys, const void **values,
		CFIndex count, const CFDictionaryKeyCallBacks *keyCallbacks, const CFDictionaryValueCallBacks *valueCallbacks);
	CTLineRef CTLineCreateWithAttributedString(CFAttributedStringRef text);
	CFArrayRef CTLineGetGlyphRuns(CTLineRef line);
	double CTLineGetTypographicBounds(CTLineRef line, CGFloat *ascent, CGFloat *descent, CGFloat *leading);
	CFIndex CTRunGetGlyphCount(CTRunRef run);
	void CTRunGetGlyphs(CTRunRef run, CFRange range, CGGlyph *glyphs);
	void CTRunGetPositions(CTRunRef run, CFRange range, CGPoint *positions);
	void CTRunGetStringIndices(CTRunRef run, CFRange range, CFIndex *indices);
	CFRange CTRunGetStringRange(CTRunRef run);
	uint32_t CTRunGetStatus(CTRunRef run);

	CGColorSpaceRef CGColorSpaceCreateDeviceGray(void);
	void CGColorSpaceRelease(CGColorSpaceRef space);
	void CGColorRelease(CGColorRef colour);
	void CGContextRelease(CGContextRef context);
	void CGContextSaveGState(CGContextRef context);
	void CGContextRestoreGState(CGContextRef context);
	CGContextRef CGBitmapContextCreate(void *data, size_t width, size_t height, size_t bitsPerComponent,
		size_t bytesPerRow, CGColorSpaceRef space, uint32_t bitmapInfo);
	CGColorRef CGColorCreateGenericGray(CGFloat gray, CGFloat alpha);
	void CGContextSetFillColorWithColor(CGContextRef context, CGColorRef color);
	void CGContextSetAllowsAntialiasing(CGContextRef context, Boolean allowed);
	void CGContextSetShouldAntialias(CGContextRef context, Boolean antialias);
	void CGContextSetShouldSmoothFonts(CGContextRef context, Boolean smooth);
	void CGContextSetShouldSubpixelQuantizeFonts(CGContextRef context, Boolean quantize);
	void CGContextSetTextMatrix(CGContextRef context, CGAffineTransform matrix);
	void CGContextTranslateCTM(CGContextRef context, CGFloat x, CGFloat y);
]]

-- kCFStringEncodingUTF8 and kCFStringEncodingASCII: the two ways a string is handed in.
local ENCODING_UTF8 = 0x08000100

-- kCFStringEncodingUTF16LE: the string CoreText is handed is built from the units this module read,
-- in the byte order of the machine, so that what a run's indices are indices *of* is the same text a
-- caret is counted in -- a string built from the bytes instead is a string CoreText decodes itself,
-- and a string that is not text is then two strings that are not the same length.
local ENCODING_UTF16LE = 0x14000100
local ENCODING_ASCII = 0x0600

-- kCTRunStatusRightToLeft: a run that is set right to left, which is the first bit of the status
-- and not the second -- the second one is a run whose glyphs are not in the order they are drawn.
local RUN_RIGHT_TO_LEFT = 1

-- kCTFontOrientationDefault: the glyphs are asked for as they are drawn, not for their vertical
-- metrics.
local ORIENTATION_DEFAULT = 0

-- CFDictionaryCreate with no callbacks: the keys and values are the ones CF keeps itself.
local NO_CALLBACKS = nil

local framework = "/System/Library/Frameworks/"

local core = ffi.load(framework .. "CoreFoundation.framework/CoreFoundation")
local coreText = ffi.load(framework .. "CoreText.framework/CoreText")
local coreGraphics = ffi.load(framework .. "CoreGraphics.framework/CoreGraphics")

local coretext = {}

---@class texter.coretext.Face
---@field path string
---@field index number
---@field descriptor CTFontDescriptorRef
---@field fonts table<number, CTFontRef> # One for each pixel height it has been asked for
---@field scale number # The size a font is made at for one pixel of line height

-- The size a face is asked about a character at, where a caller does not say: whether a font draws
-- a character is not a question about a size.
local DEFAULT_HEIGHT = 16
---@field private canvas ffi.cdata*? # The bitmap context glyphs are drawn into, kept
---@field private canvasPixels ffi.cdata*? # What it draws into, kept
---@field private canvasWidth number # How wide that is, which is what a row of it is
---@field private canvasHeight number
---@field private room number # How many pixels the compact copy of a glyph holds
---@field private stack ffi.cdata*?
---@field private space ffi.cdata*? # The grey colour space every canvas of this face is made in
---@field private colour ffi.cdata*? # What a glyph is drawn in
local Face = {}

---@return boolean
function coretext.available()
	return core ~= nil and coreText ~= nil
end

---@return string?
function coretext.why()
	if coretext.available() then
		return nil
	end

	return "macOS without CoreText is not a thing: this backend found no framework to load"
end

---@param bytes string
---@param encoding number
---@return CFStringRef
local function stringOf(bytes, encoding)
	if encoding == ENCODING_UTF8 then
		return core.CFStringCreateWithBytes(nil, ffi.cast("const unsigned char *", bytes), #bytes, encoding, 0)
	end

	return core.CFStringCreateWithCString(nil, bytes, encoding)
end

-- What one run of a line is asked for and what it answers with, kept and grown rather than made
-- again: a line is a run or two and a frame is a line or a hundred, and three arrays a run are three
-- arrays the collector pays for. What they hold is read before the next run rather than kept.
local room = 0

---@type ffi.cdata*
local glyphBuffer, positionBuffer, indexBuffer = nil, nil, nil

---@param count number
local function grow(count)
	if room >= count then
		return
	end

	room = count
	glyphBuffer = ffi.new("CGGlyph[?]", room)
	positionBuffer = ffi.new("CGPoint[?]", room)
	indexBuffer = ffi.new("CFIndex[?]", room)
end

--- Reads a font file: macOS registers a font by URL and hands back what it is, which is a font made
--- at any size afterwards.
---@param path string
---@param index number?
---@return texter.coretext.Face? face
---@return string? err
function coretext.face(path, index)
	local url = core.CFURLCreateFromFileSystemRepresentation(nil, path, #path, 0)

	if url == nil then
		return nil, "macOS would not look at " .. path
	end

	local descriptors = coreText.CTFontManagerCreateFontDescriptorsFromURL(url)

	core.CFRelease(url)

	if descriptors == nil then
		return nil, path .. " is not a font macOS can read"
	end

	-- What comes back from a count is a long, which ffi hands over as a cdata of its own: what a
	-- count is here is a number, and arithmetic on it is what says that it is one.
	local count = tonumber(core.CFArrayGetCount(descriptors))

	if count == 0 then
		core.CFRelease(descriptors)

		return nil, path .. " holds no font"
	end

	local at = math.min((index or 0) + 1, count)

	-- What an array holds is a bare pointer: what it is a pointer *to* is what this knows, and ffi
	-- does not guess.
	local descriptor = ffi.cast("CTFontDescriptorRef", core.CFArrayGetValueAtIndex(descriptors, at - 1))

	-- The descriptor is what the fonts of every size are made from, so it is kept: what the array
	-- holds goes with the array.
	core.CFRetain(ffi.cast("CFTypeRef", descriptor))
	core.CFRelease(descriptors)

	---@cast descriptor CTFontDescriptorRef
	local face = setmetatable({
		path = path,
		index = index or 0,
		descriptor = descriptor,
		fonts = {},
		scale = 0,
		canvas = nil,
		canvasPixels = nil,
		canvasWidth = 0,
		canvasHeight = 0,
		room = 0,
		stack = nil,
		space = nil,
		colour = nil,
	}, { __index = Face })

	-- A pixel height is how tall a *line* of text is here, and CoreText is asked for a size in
	-- points: the ratio between them is the font's own, measured once at a size of a hundred.
	local nominal = coreText.CTFontCreateWithFontDescriptor(descriptor, 100, nil)

	if nominal == nil then
		return nil, path .. " made no font"
	end

	local line = coreText.CTFontGetAscent(nominal) + coreText.CTFontGetDescent(nominal)

	core.CFRelease(nominal)

	if line <= 0 then
		return nil, path .. " states no line height"
	end

	face.scale = 100 / line

	return face
end

--- The font at a pixel height, made once for each: what a size is here is a size of a line.
---@param self texter.coretext.Face
---@param pixelHeight number
---@return CTFontRef
function Face:font(pixelHeight)
	-- The heights a face is asked for are whole pixels, and a table keyed by a number with a
	-- fraction in it is a table that grows for nothing.
	local key = math.floor(pixelHeight * 64 + 0.5)

	if self.fonts[key] == nil then
		self.fonts[key] = coreText.CTFontCreateWithFontDescriptor(self.descriptor, pixelHeight * self.scale, nil)
	end

	return assert(self.fonts[key])
end

---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function Face:metrics(pixelHeight)
	local font = self:font(pixelHeight)
	local ascent = coreText.CTFontGetAscent(font)
	local descent = coreText.CTFontGetDescent(font)
	local leading = coreText.CTFontGetLeading(font)
	local line = ascent + descent

	-- What is asked for is the height of a line, so what comes back is scaled to it: the font was
	-- made at a size where that is what it comes to, and what is left over is the leading.
	return ascent, -descent, leading > 0 and leading or 0, line
end

--- The glyph a codepoint is in this font, or nought where it is not one of its own.
---
--- A codepoint is not a unit, and what CoreText is asked about characters in is UTF-16 units: a
--- character outside the basic plane -- which every emoji is -- is two units that are one character,
--- so what is handed over is the pair of them, and the glyph that comes back is in the first place
--- the answer has room for.
---
--- Which glyph a codepoint is does not depend on the size it is drawn at, and a caller that does not
--- say which size it means gets the one a face is asked about a character at: what a font draws is
--- what it draws at any size.
---@param codepoint number
---@param pixelHeight number?
---@return number
function Face:glyphFor(codepoint, pixelHeight)
	local font = self:font(pixelHeight or DEFAULT_HEIGHT)
	local characters = ffi.new("UniChar[2]")
	local count = 1

	if codepoint >= 0x10000 then
		local point = codepoint - 0x10000

		characters[0] = 0xD800 + math.floor(point / 0x400)
		characters[1] = 0xDC00 + point % 0x400
		count = 2
	else
		characters[0] = codepoint
	end

	local glyphs = ffi.new("CGGlyph[2]")

	if coreText.CTFontGetGlyphsForCharacters(font, characters, glyphs, count) == 0 then
		return 0
	end

	return glyphs[0]
end

---@param codepoint number
---@return boolean
function Face:hasGlyph(codepoint)
	return self:glyphFor(codepoint) ~= 0
end

---@param codepoint number
---@param pixelHeight number
---@return number
function Face:advance(codepoint, pixelHeight)
	local font = self:font(pixelHeight)
	local glyphs = ffi.new("CGGlyph[1]", self:glyphFor(codepoint, pixelHeight))
	local sizes = ffi.new("CGSize[1]")

	coreText.CTFontGetAdvancesForGlyphs(font, ORIENTATION_DEFAULT, glyphs, sizes, 1)

	return tonumber(sizes[0].width)
end

--- A glyph with nothing to draw: a space, a mark a shaper places by an offset, and a glyph a font
--- has no picture of all answer with it. It is one value rather than one a call, because what it says
--- is the same every time and a line of text is mostly spaces.
local NOTHING = { width = 0, height = 0, left = 0, top = 0 }

---@param glyph number
---@param pixelHeight number
---@return texter.Ink
function Face:inkOf(glyph, pixelHeight)
	local font = self:font(pixelHeight)
	local glyphs = ffi.new("CGGlyph[1]", glyph)
	local rects = ffi.new("CGRect[1]")

	coreText.CTFontGetBoundingRectsForGlyphs(font, ORIENTATION_DEFAULT, glyphs, rects, 1)

	local bounds = rects[0]
	local width = math.ceil(tonumber(bounds.size.width))
	local height = math.ceil(tonumber(bounds.size.height))

	if width <= 0 or height <= 0 then
		return NOTHING
	end

	local context, pixels = self:canvasFor(width, height)

	-- What is drawn into is cleared first: what a context keeps is what was drawn into it, and a
	-- glyph drawn over another glyph is neither of them.
	ffi.fill(pixels, self.canvasWidth * self.canvasHeight, 0)

	-- A bitmap context is bottom up and a glyph is drawn from the baseline: the origin is put where
	-- the glyph's own box starts, which is what the bounding rectangle says, and the y is turned
	-- around so that what is drawn is the right way up in the bitmap. What is drawn moves the
	-- context's own origin, so the state goes back the way it was drawn in.
	local positions = ffi.new("CGPoint[1]")

	positions[0].x, positions[0].y = 0, 0

	coreGraphics.CGContextSaveGState(context)
	coreGraphics.CGContextTranslateCTM(context, -tonumber(bounds.origin.x), -tonumber(bounds.origin.y))
	coreText.CTFontDrawGlyphs(font, glyphs, positions, 1, context)
	coreGraphics.CGContextRestoreGState(context)

	-- What an atlas packs is a glyph's rows one after another with no padding, and what a context
	-- draws into is rows of the width it was made at: the glyph's own part of each row is copied out.
	local room = width * height

	if room > self.room then
		self.room = room
		self.stack = ffi.new("unsigned char[?]", room)
	end

	local stack = assert(self.stack)

	if self.canvasWidth == width then
		ffi.copy(stack, pixels, room)
	else
		for row = 0, height - 1 do
			ffi.copy(stack + row * width, pixels + row * self.canvasWidth, width)
		end
	end

	return {
		width = width,
		height = height,
		left = math.floor(tonumber(bounds.origin.x)),
		top = -math.floor(tonumber(bounds.origin.y) + tonumber(bounds.size.height)),
		pixels = stack,
	}
end

--- The bitmap a glyph is drawn into: one for the whole face, made the first time it is drawn into
--- and made again only when a glyph is larger than it -- which is a few times in the life of a face
--- rather than once a glyph, and what a context a glyph is a context the machine made and gave
--- nothing back of.
---
--- What comes back is the context and its pixels, and the pixels are as wide as the context rather
--- than as wide as the glyph: a row of a glyph is a row of the context trimmed to it.
---@param self texter.coretext.Face
---@param width number
---@param height number
---@return CGContextRef context
---@return ffi.cdata* pixels
function Face:canvasFor(width, height)
	if self.canvas ~= nil and width <= self.canvasWidth and height <= self.canvasHeight then
		return self.canvas, self.canvasPixels
	end

	local wide = math.max(width, self.canvasWidth * 2)
	local high = math.max(height, self.canvasHeight * 2)

	if self.canvas ~= nil then
		coreGraphics.CGContextRelease(self.canvas)
	end

	if self.space == nil then
		self.space = coreGraphics.CGColorSpaceCreateDeviceGray()
	end

	local pixels = ffi.new("unsigned char[?]", wide * high)
	local context = coreGraphics.CGBitmapContextCreate(pixels, wide, high, 8, wide, self.space, 0)

	coreGraphics.CGContextSetAllowsAntialiasing(context, 1)
	coreGraphics.CGContextSetShouldAntialias(context, 1)
	-- The coverage of a glyph rather than the shape of it: what an atlas packs is the ink, and a
	-- font that is smoothed is one drawn for a screen rather than for its own pixels.
	coreGraphics.CGContextSetShouldSmoothFonts(context, 0)
	coreGraphics.CGContextSetShouldSubpixelQuantizeFonts(context, 0)

	if self.colour == nil then
		self.colour = coreGraphics.CGColorCreateGenericGray(1.0, 1.0)
	end

	coreGraphics.CGContextSetFillColorWithColor(context, self.colour)
	coreGraphics.CGContextSetTextMatrix(context, ffi.new("CGAffineTransform", 1, 0, 0, 1, 0, 0))

	self.canvas, self.canvasPixels, self.canvasWidth, self.canvasHeight = context, pixels, wide, high

	return context, pixels
end

---@param codepoint number
---@param pixelHeight number
---@return texter.Ink
function Face:ink(codepoint, pixelHeight)
	return self:inkOf(self:glyphFor(codepoint, pixelHeight), pixelHeight)
end

---@param ink texter.Ink
function Face:freeInk(_ink)
end

--- Shapes a line: CoreText does the whole of it -- the script's own rules, the bidi algorithm, the
--- direction of every run -- and what comes back is the glyphs in the order they are drawn in.
---@param face texter.coretext.Face
---@param text string
---@param pixelHeight number
---@param opts texter.ShapeOpts?
---@return texter.Line
function coretext.shape(face, text, pixelHeight, _opts)
	local font = face:font(pixelHeight)
	local wide = utf8.units(text)
	local characters = wide.units
	local bytes = wide.offsets

	-- What the line is made of is a string of the framework's own, and it is not a local called
	-- `string`: that is what a caller formats with, and one of that name here would make every use
	-- of it in this function read a field of a font instead.
	local cfText = core.CFStringCreateWithBytes(nil, ffi.cast("const unsigned char *", characters),
		wide.count * 2, ENCODING_UTF16LE, 0)

	-- The attribute CoreText is told the font by is the name "NSFont", which is what the framework's
	-- own constant is: a string made here is the same string.
	local name = stringOf("NSFont", ENCODING_ASCII)
	local keys = ffi.new("const void *[1]", ffi.cast("const void *", name))
	local values = ffi.new("const void *[1]", ffi.cast("const void *", font))
	local attributes = core.CFDictionaryCreate(nil, keys, values, 1, NO_CALLBACKS, NO_CALLBACKS)
	local attributed = core.CFAttributedStringCreate(nil, cfText, attributes)
	local line = coreText.CTLineCreateWithAttributedString(attributed)
	local runs = coreText.CTLineGetGlyphRuns(line)
	local glyphs, placed = {}, {}
	local ascent, descent, leading = ffi.new("CGFloat[1]"), ffi.new("CGFloat[1]"), ffi.new("CGFloat[1]")
	-- How wide the whole line is, which is the line's own and not a run's: what a run is worth is a
	-- part of it, and asking the line what it comes to once a run is asking it as many times as
	-- there are runs.
	local width = coreText.CTLineGetTypographicBounds(line, ascent, descent, leading)

	--- What byte of the line a UTF-16 unit of it starts at.
	---@param unit number
	---@return number
	local function byteOf(unit)
		local at = unit >= 0 and bytes[unit] or nil

		return (at or (#text + 1)) - 1
	end

	for index = 0, tonumber(core.CFArrayGetCount(runs)) - 1 do
		local run = ffi.cast("CTRunRef", core.CFArrayGetValueAtIndex(runs, index))
		local glyphCount = tonumber(coreText.CTRunGetGlyphCount(run))

		grow(glyphCount)

		local out, positions, indices = glyphBuffer, positionBuffer, indexBuffer
		-- What a run is asked for is a range of *its* glyphs, which is all of them: the whole run is
		-- what is shaped, and a line that needs half of one is not a line yet.
		local range = ffi.new("CFRange", 0, glyphCount)

		coreText.CTRunGetGlyphs(run, range, out)
		coreText.CTRunGetPositions(run, range, positions)
		coreText.CTRunGetStringIndices(run, range, indices)

		local rtl = tonumber(coreText.CTRunGetStatus(run)) % (RUN_RIGHT_TO_LEFT * 2) >= RUN_RIGHT_TO_LEFT

		-- A run of two directions in one line is a run whose indices go either way, so what the
		-- run covers is asked of every index of it rather than of the first and the last.
		local low, high = math.huge, -math.huge

		for at = 0, glyphCount - 1 do
			local unit = tonumber(indices[at])

			low, high = math.min(low, unit), math.max(high, unit)
		end

		placed[#placed + 1] = {
			first = byteOf(low) + 1,
			last = byteOf(high) + 1,
			rtl = rtl,
			level = rtl and 1 or 0,
		}

		for at = 0, glyphCount - 1 do
			-- Where a glyph goes is where CoreText put it: a position is a place in the line, so
			-- the runs of it and the two directions of them are already in the answer.
			glyphs[#glyphs + 1] = {
				glyph = out[at],
				cluster = byteOf(tonumber(indices[at])),
				x = tonumber(positions[at].x),
				y = -tonumber(positions[at].y),
				advance = 0,
			}
		end
	end

	-- What is left is each glyph's own advance, which is what a caller that draws a glyph at a time
	-- needs: the place of the next one less the place of this one, and the last one's is the end of
	-- the line. What is not in a place of its own -- a mark that sits over the letter before it --
	-- takes no room, which is what an advance of nought is.
	for index = 1, #glyphs do
		local next = glyphs[index + 1]

		glyphs[index].advance = (next and next.x or width) - glyphs[index].x
	end

	core.CFRelease(line)
	core.CFRelease(attributed)
	core.CFRelease(attributes)
	core.CFRelease(name)
	core.CFRelease(cfText)

	local rtl = #placed > 0 and placed[1].rtl or false

	return { glyphs = glyphs, width = width, rtl = rtl, runs = placed, text = text }
end

---@param face texter.coretext.Face
---@param glyph number
---@param pixelHeight number
---@return texter.Ink
function coretext.ink(face, glyph, pixelHeight)
	return face:inkOf(glyph, pixelHeight)
end

---@param face texter.coretext.Face
---@param pixelHeight number
---@return number ascent
---@return number descent
---@return number lineGap
function coretext.metrics(face, pixelHeight)
	return face:metrics(pixelHeight)
end

---@param line texter.Line
---@param byte number
---@return number
function coretext.penOf(line, byte)
	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		if glyph.cluster >= byte then
			return pen
		end

		pen = pen + glyph.advance
	end

	return line.width
end

---@param line texter.Line
---@param x number
---@return number
function coretext.byteAt(line, x)
	local pen = 0.0

	for _, glyph in ipairs(line.glyphs) do
		if x < pen + glyph.advance / 2 then
			return glyph.cluster
		end

		pen = pen + glyph.advance
	end

	return #line.text + 1
end

-- What a screen packs a glyph from and shapes a line with: the faces this module opens, in the shape
-- `wonderland` asks a reader of fonts for -- see `wonderland.font.Provider`. The faces are what an
-- atlas needs; `shape` and `ink` are here because a screen that draws text shapes its lines and
-- packs the glyphs a line came to, which are glyphs of a font rather than characters of a string.
---@type wonderland.font.Provider
coretext.provider = {
	open = function(path, index)
		return coretext.face(path, index)
	end,
	shape = function(face, text, pixelHeight, opts)
		return coretext.shape(face, text, pixelHeight, opts)
	end,
	ink = function(face, glyph, pixelHeight)
		return coretext.ink(face, glyph, pixelHeight)
	end,
}

return coretext
