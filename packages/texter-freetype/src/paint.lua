-- A glyph a font draws as a picture of its own, out of the graph a `COLR` version 1 table is.
--
-- A colour font of the newest kind does not hold a glyph's picture. It holds a *graph* of how to
-- paint one -- a solid colour, a gradient between stops, another glyph's outline filled with either
-- of those, a transform of any of them, a hundred of them layered, and a way of putting two of them
-- together -- and the glyph's own outline is empty, so what is drawn is whatever a client makes of
-- the graph. FreeType reads the graph and hands it over a node at a time (`FT_Get_Color_Glyph_Paint`
-- and the rest of `ftcolor.h`) and does not paint it, which is why a font like `Noto Color Emoji`
-- -- COLR v1, and what desktops install -- comes back as nothing at all until something paints it.
-- This is that something.
--
-- What comes out is what a colour glyph of any other kind comes out as: four bytes a pixel, blue,
-- green, red and alpha, each of them multiplied by the alpha, which is what FreeType composes a
-- COLR v0 font into and what a CBDT or sbix one hands over. So what a caller does with a colour
-- glyph does not depend on which kind of colour the font is.
--
-- What is painted is the whole of a graph: layers, glyphs, references to other colour glyphs,
-- transforms, the gradients (linear, radial and sweep, with the three ways of carrying on past
-- their ends), and the ways two paints are put together that a font of pictures is drawn with --
-- the Porter-Duff ones and the separable blends. A mode that is not one of those is drawn as the
-- source over the backdrop, which is what most of them come to on a picture a few pixels wide.
local ffi = require("ffi")

ffi.cdef [[
	typedef unsigned char FT_Byte;
	typedef unsigned short FT_UShort;
	typedef unsigned int FT_UInt;
	typedef unsigned short FT_UInt16;
	typedef long FT_Fixed;
	typedef long FT_Pos;
	typedef signed short FT_F2Dot14;
	typedef int FT_Error;
	typedef int FT_Bool;

	typedef struct { FT_Byte blue, green, red, alpha; } FT_Color;

	typedef struct { long xx, xy, yx, yy; } FT_Matrix;

	// What a paint's colour is: which entry of the palette, and how much of it. The alpha is two
	// point fourteen fixed point, where sixteen thousand three hundred and eighty-four is one.
	typedef struct {
		FT_UInt16 palette_index;
		FT_F2Dot14 alpha;
	} FT_ColorIndex;

	typedef struct {
		FT_Fixed stop_offset;
		FT_ColorIndex color;
	} FT_ColorStop;

	typedef struct {
		FT_UInt num_color_stops;
		FT_UInt current_color_stop;
		FT_Byte *p;
		FT_Bool read_variable;
	} FT_ColorStopIterator;

	typedef struct {
		int extend;
		FT_ColorStopIterator color_stop_iterator;
	} FT_ColorLine;

	typedef struct {
		FT_UInt num_layers;
		FT_UInt layer;
		FT_Byte *p;
	} FT_LayerIterator;

	typedef struct {
		FT_Byte *p;
		FT_Bool insert_root_transform;
	} FT_OpaquePaint;

	typedef struct { FT_ColorIndex color; } FT_PaintSolid;
	typedef struct { FT_ColorLine colorline; FT_Vector p0, p1, p2; } FT_PaintLinearGradient;
	typedef struct { FT_ColorLine colorline; FT_Vector c0; FT_Pos r0; FT_Vector c1; FT_Pos r1; } FT_PaintRadialGradient;
	typedef struct { FT_ColorLine colorline; FT_Vector center; FT_Fixed start_angle, end_angle; } FT_PaintSweepGradient;
	typedef struct { FT_OpaquePaint paint; FT_UInt glyphID; } FT_PaintGlyph;
	typedef struct { FT_UInt glyphID; } FT_PaintColrGlyph;
	typedef struct { FT_Fixed xx, xy, dx, yx, yy, dy; } FT_Affine23;
	typedef struct { FT_OpaquePaint paint; FT_Affine23 affine; } FT_PaintTransform;
	typedef struct { FT_OpaquePaint paint; FT_Fixed dx, dy; } FT_PaintTranslate;
	typedef struct { FT_OpaquePaint paint; FT_Fixed scale_x, scale_y, center_x, center_y; } FT_PaintScale;
	typedef struct { FT_OpaquePaint paint; FT_Fixed angle, center_x, center_y; } FT_PaintRotate;
	typedef struct { FT_OpaquePaint paint; FT_Fixed x_skew_angle, y_skew_angle, center_x, center_y; } FT_PaintSkew;
	typedef struct {
		FT_OpaquePaint source_paint;
		int composite_mode;
		FT_OpaquePaint backdrop_paint;
	} FT_PaintComposite;
	typedef struct { FT_LayerIterator layer_iterator; } FT_PaintColrLayers;

	typedef struct {
		int format;
		union {
			FT_PaintColrLayers colr_layers;
			FT_PaintGlyph glyph;
			FT_PaintSolid solid;
			FT_PaintLinearGradient linear_gradient;
			FT_PaintRadialGradient radial_gradient;
			FT_PaintSweepGradient sweep_gradient;
			FT_PaintTransform transform;
			FT_PaintTranslate translate;
			FT_PaintScale scale;
			FT_PaintRotate rotate;
			FT_PaintSkew skew;
			FT_PaintComposite composite;
			FT_PaintColrGlyph colr_glyph;
		} u;
	} FT_COLR_Paint;

	// A colour glyph's box, which is four corners rather than the two a bounding box is: what a
	// graph comes to, where the glyph's own outline comes to nothing.
	typedef struct {
		FT_Vector bottom_left;
		FT_Vector top_left;
		FT_Vector top_right;
		FT_Vector bottom_right;
	} FT_ClipBox;

	typedef struct {
		FT_UShort num_palettes;
		const FT_UShort *palette_name_ids;
		const FT_UShort *palette_flags;
		FT_UShort num_palette_entries;
		const FT_UShort *palette_entry_name_ids;
	} FT_Palette_Data;

	FT_Bool FT_Get_Color_Glyph_Paint(FT_Face face, FT_UInt base_glyph, int root_transform, FT_OpaquePaint *paint);
	FT_Bool FT_Get_Paint(FT_Face face, FT_OpaquePaint opaque_paint, FT_COLR_Paint *paint);
	FT_Bool FT_Get_Paint_Layers(FT_Face face, FT_LayerIterator *iterator, FT_OpaquePaint *paint);
	FT_Bool FT_Get_Colorline_Stops(FT_Face face, FT_ColorStop *color_stop, FT_ColorStopIterator *iterator);
	FT_Bool FT_Get_Color_Glyph_ClipBox(FT_Face face, FT_UInt base_glyph, FT_ClipBox *clip_box);
	FT_Error FT_Palette_Data_Get(FT_Face face, FT_Palette_Data *palette);
	FT_Error FT_Palette_Select(FT_Face face, FT_UShort palette_index, FT_Color **palette);
]]

-- FT_COLR_PAINTFORMAT_*: what a node of a graph is.
local COLR_LAYERS = 1
local SOLID = 2
local LINEAR = 4
local RADIAL = 6
local SWEEP = 8
local GLYPH = 10
local COLR_GLYPH = 11
local TRANSFORM = 12
local TRANSLATE = 14
local SCALE = 16
local ROTATE = 24
local SKEW = 28
local COMPOSITE = 32

-- FT_COLR_PAINT_EXTEND_*: how a gradient carries on past the ends of itself.
local PAD = 0
local REPEAT = 1
local REFLECT = 2

-- FT_COLOR_INCLUDE_ROOT_TRANSFORM: what a colour glyph's graph is asked for with, so that where its
-- own space comes to pixels is the graph's to say rather than this module's.
local INCLUDE_ROOT_TRANSFORM = 0

-- FT_COLOR_NO_ROOT_TRANSFORM: what a graph *inside* one is asked for with. A picture that is
-- another picture is in the space of the graph it is named from, which the root of that one already
-- says how to read: what its own root would say is the same thing a second time.
local NO_ROOT_TRANSFORM = 1

-- FT_COLR_COMPOSITE_*: how two paints are put together. The ones a font of pictures is drawn with
-- are named here; anything else is drawn as the source over the backdrop.
local CLEAR = 0
local SRC = 1
local DEST = 2
local SRC_OVER = 3
local DEST_OVER = 4
local SRC_IN = 5
local DEST_IN = 6
local SRC_OUT = 7
local DEST_OUT = 8
local SRC_ATOP = 9
local DEST_ATOP = 10
local XOR = 11
local PLUS = 12
local SCREEN = 13
local DARKEN = 15
local LIGHTEN = 16
local MULTIPLY = 23

-- One, in the two ways a colour font counts in.
local ONE_16_16 = 65536
local ONE_2_14 = 16384

-- What a shape's outline is loaded as: not as whatever bitmap the font has of it, and *not* scaled
-- to a size -- a graph states where its shapes are and how big they are in the font's own units, so
-- what it is applied to is the shape as the font states it, and what turns that into pixels is what
-- the face is at, applied to the whole of it afterwards.
local LOAD_NO_BITMAP = 8
local LOAD_NO_SCALE = 1

local RENDER_NORMAL = 0
local PIXEL_MODE_GRAY = 2

-- How deep a graph is followed, and how many nodes of it are read, before it is taken for a font
-- that is not a picture of anything: a colour glyph may name another colour glyph, and a font that
-- names itself is a font that would be painted forever.
local MAX_DEPTH = 12
local MAX_NODES = 4096

-- What is painted into, kept and grown rather than made again: one buffer a level of the graph,
-- and one mask for the shapes a paint is put through.
local room = 0

---@type table<number, ffi.cdata*>
local levels = {}

---@type ffi.cdata*
local mask = nil

--- Grows what is painted into to hold a picture of this many pixels, in as many levels as a graph
--- may nest.
---@param pixels number
local function grow(pixels)
	if room >= pixels then
		return
	end

	room = pixels
	levels = {}

	for index = 1, MAX_DEPTH + 1 do
		levels[index] = ffi.new("unsigned char[?]", room * 4)
	end

	mask = ffi.new("unsigned char[?]", room)
end

--- What a fixed point value of a font comes to, in the whole numbers this counts in: a fixed
--- point value is a long, and what a long is to this language is a value of its own rather than a
--- number, so every one of them is read where it is rather than where it is used.
---@param value ffi.cdata*|number
---@return number
local function fixed(value)
	return tonumber(value) / ONE_16_16
end

--- What a colour is, in the four numbers a pixel is made of, each from nought to one.
---@class texter.paint.Colour
---@field blue number
---@field green number
---@field red number
---@field alpha number

---@type texter.paint.Colour
local colour = { blue = 0, green = 0, red = 0, alpha = 0 }

--- The palettes of the faces read so far: what a colour index of a graph names.
---@type table<ffi.cdata*, ffi.cdata*?>
local palettes = setmetatable({}, { __mode = "k" })

--- The colours a font's indices name, which is what every paint of it is drawn in. It is read once
--- for a face: a palette is a few hundred bytes and every glyph of the font is drawn in it.
---@param library ffi.cdata*
---@param face texter.freetype.ffi.Face
---@return ffi.cdata*? palette
local function paletteOf(library, face)
	local known = palettes[face]

	if known ~= nil then
		return known or nil
	end

	local data = ffi.new("FT_Palette_Data")

	if library.FT_Palette_Data_Get(face, data) ~= 0 then
		palettes[face] = false

		return nil
	end

	-- A font may say which of its palettes is the one it is drawn in, and one that says nothing is
	-- drawn in the first of what it has.
	local wanted = 0

	if data.num_palettes == 0 then
		palettes[face] = false

		return nil
	end

	local chosen = ffi.new("FT_Color *[1]")

	if library.FT_Palette_Select(face, wanted, chosen) ~= 0 then
		palettes[face] = false

		return nil
	end

	palettes[face] = chosen[0]

	return chosen[0]
end

--- What a colour index of a graph is worth, and how much of it.
---@param palette ffi.cdata*?
---@param index number
---@param alpha number # From nought to one
---@return texter.paint.Colour
local function colourOf(palette, index, alpha)
	if palette == nil then
		colour.blue, colour.green, colour.red, colour.alpha = 0, 0, 0, 0

		return colour
	end

	local entry = palette[index]

	colour.blue, colour.green, colour.red = entry.blue / 255, entry.green / 255, entry.red / 255
	colour.alpha = entry.alpha / 255 * alpha

	return colour
end

--- The stops a gradient is drawn between, in the order the font states them.
---@class texter.paint.Stop
---@field offset number
---@field red number
---@field green number
---@field blue number
---@field alpha number

---@param library ffi.cdata*
---@param face texter.freetype.ffi.Face
---@param line ffi.cdata* # The color line of a gradient, which holds where its stops are read from
---@param palette ffi.cdata*?
---@return texter.paint.Stop[]
local function stopsOf(library, face, line, palette)
	local stops = {}
	local stop = ffi.new("FT_ColorStop[1]")
	local iterator = ffi.new("FT_ColorStopIterator[1]")

	iterator[0] = line[0].color_stop_iterator

	while library.FT_Get_Colorline_Stops(face, stop, iterator) ~= 0 do
		local entry = stop[0].color
		local at = colourOf(palette, entry.palette_index, entry.alpha / ONE_2_14)

		stops[#stops + 1] = {
			offset = fixed(stop[0].stop_offset),
			red = at.red,
			green = at.green,
			blue = at.blue,
			alpha = at.alpha,
		}
	end

	return stops
end

--- What turns the graph's own coordinates into pixels, which is what the *root* of it says rather
--- than what the size says: a colour font states its shapes, the places it moves them to and the
--- lines its gradients run along in a space of its own, and the root transform is the one thing
--- that maps that space to the pixels a screen draws in -- "a transform to configure the client's
--- graphics context matrix", as FreeType puts it. Everything below the root is drawn in the space
--- that transform comes from.
---@type texter.paint.Placement
local toPixels = { xx = 1, xy = 0, yx = 0, yy = 1, dx = 0, dy = 0 }

--- Where along a gradient a point is, carried on past the ends of it the way the font says to.
---@param extend number
---@param at number
---@return number
local function carried(extend, at)
	if extend == REPEAT then
		return at - math.floor(at)
	elseif extend == REFLECT then
		local wrapped = (at / 2) % 1

		return math.abs(wrapped * 2 - 1)
	end

	return math.min(1, math.max(0, at))
end

--- The colour a gradient has at a point along it, which is between the two stops it falls between.
---@param stops texter.paint.Stop[]
---@param at number
---@return number red
---@return number green
---@return number blue
---@return number alpha
local function between(stops, at)
	local first = stops[1]

	if first == nil then
		return 0, 0, 0, 0
	end

	local last = stops[#stops]

	if at <= first.offset then
		return first.red, first.green, first.blue, first.alpha
	end

	if at >= last.offset then
		return last.red, last.green, last.blue, last.alpha
	end

	for index = 2, #stops do
		local upper = stops[index]

		if at <= upper.offset then
			local lower = stops[index - 1]
			local span = upper.offset - lower.offset
			local along = span > 0 and (at - lower.offset) / span or 0

			return lower.red + (upper.red - lower.red) * along, lower.green + (upper.green - lower.green) * along,
				lower.blue + (upper.blue - lower.blue) * along, lower.alpha + (upper.alpha - lower.alpha) * along
		end
	end

	return last.red, last.green, last.blue, last.alpha
end

--- Where a node of a graph draws, which is what the nodes above it have moved and scaled it by: a
--- matrix and a move, one after the other.
---@class texter.paint.Placement
---@field xx number
---@field xy number
---@field yx number
---@field yy number
---@field dx number
---@field dy number

---@type texter.paint.Placement
local NOWHERE = { xx = 1, xy = 0, yx = 0, yy = 1, dx = 0, dy = 0 }

--- A move and a matrix after the ones a node was already drawn with.
---@param placement texter.paint.Placement
---@param xx number
---@param xy number
---@param yx number
---@param yy number
---@param dx number
---@param dy number
---@return texter.paint.Placement
local function after(placement, xx, xy, yx, yy, dx, dy)
	return {
		xx = placement.xx * xx + placement.xy * yx,
		xy = placement.xx * xy + placement.xy * yy,
		yx = placement.yx * xx + placement.yy * yx,
		yy = placement.yx * xy + placement.yy * yy,
		dx = placement.xx * dx + placement.xy * dy + placement.dx,
		dy = placement.yx * dx + placement.yy * dy + placement.dy,
	}
end

--- Whether a placement moves nothing, which is the whole of what most graphs do.
---@param placement texter.paint.Placement
---@return boolean
local function still(placement)
	return placement.xx == 1 and placement.xy == 0 and placement.yx == 0 and placement.yy == 1
		and placement.dx == 0 and placement.dy == 0
end

--- One pixel of a source, put over what is already there: what compositing is, with the source
--- multiplied by whatever part of it the shape it is painted on covers.
---@param into ffi.cdata* # The picture, four bytes a pixel
---@param at number # Which pixel of it, in bytes
---@param blue number
---@param green number
---@param red number
---@param alpha number
local function over(into, at, blue, green, red, alpha)
	local rest = 1 - alpha / 255

	into[at] = into[at] * rest + blue
	into[at + 1] = into[at + 1] * rest + green
	into[at + 2] = into[at + 2] * rest + red
	into[at + 3] = into[at + 3] * rest + alpha
end

--- Two paints put together, one of them the source and the other the backdrop, the way the mode
--- says. Both are four bytes a pixel, each already multiplied by its own alpha.
---@param mode number
---@param into ffi.cdata* # The backdrop, which what comes of it is written back into
---@param from ffi.cdata* # The source
---@param pixels number
local function blend(mode, into, from, pixels)
	for at = 0, pixels * 4 - 1, 4 do
		local sa, da = from[at + 3], into[at + 3]
		local sb, sg, sr = from[at], from[at + 1], from[at + 2]
		local db, dg, dr = into[at], into[at + 1], into[at + 2]
		local blue, green, red, alpha

		if mode == CLEAR then
			blue, green, red, alpha = 0, 0, 0, 0
		elseif mode == SRC then
			blue, green, red, alpha = sb, sg, sr, sa
		elseif mode == DEST then
			blue, green, red, alpha = db, dg, dr, da
		elseif mode == DEST_OVER then
			blue = db + sb * (1 - da / 255)
			green = dg + sg * (1 - da / 255)
			red = dr + sr * (1 - da / 255)
			alpha = da + sa * (1 - da / 255)
		elseif mode == SRC_IN then
			blue, green, red, alpha = sb * da / 255, sg * da / 255, sr * da / 255, sa * da / 255
		elseif mode == DEST_IN then
			blue, green, red, alpha = db * sa / 255, dg * sa / 255, dr * sa / 255, da * sa / 255
		elseif mode == SRC_OUT then
			blue = sb * (1 - da / 255)
			green = sg * (1 - da / 255)
			red = sr * (1 - da / 255)
			alpha = sa * (1 - da / 255)
		elseif mode == DEST_OUT then
			blue = db * (1 - sa / 255)
			green = dg * (1 - sa / 255)
			red = dr * (1 - sa / 255)
			alpha = da * (1 - sa / 255)
		elseif mode == SRC_ATOP then
			blue = sb * da / 255 + db * (1 - sa / 255)
			green = sg * da / 255 + dg * (1 - sa / 255)
			red = sr * da / 255 + dr * (1 - sa / 255)
			alpha = sa * da / 255 + da * (1 - sa / 255)
		elseif mode == DEST_ATOP then
			blue = db * sa / 255 + sb * (1 - da / 255)
			green = dg * sa / 255 + sg * (1 - da / 255)
			red = dr * sa / 255 + sr * (1 - da / 255)
			alpha = da * sa / 255 + sa * (1 - da / 255)
		elseif mode == XOR then
			blue = sb * (1 - da / 255) + db * (1 - sa / 255)
			green = sg * (1 - da / 255) + dg * (1 - sa / 255)
			red = sr * (1 - da / 255) + dr * (1 - sa / 255)
			alpha = sa * (1 - da / 255) + da * (1 - sa / 255)
		elseif mode == PLUS then
			blue, green, red, alpha = math.min(255, sb + db), math.min(255, sg + dg), math.min(255, sr + dr),
				math.min(255, sa + da)
		elseif mode == MULTIPLY or mode == SCREEN or mode == DARKEN or mode == LIGHTEN then
			-- A blend of the two colours, which is only what both of them cover: what is left over
			-- is each of them on its own, the way a source over a backdrop leaves it.
			local weight = sa * da / 255 / 255
			local function mixed(s, d, a)
				return s * (1 - da / 255) + d * (1 - sa / 255) + a * weight
			end

			local function plain(s, a)
				return a > 0 and s / (a / 255) or 0
			end

			local sbp, sgp, srp = plain(sb, sa), plain(sg, sa), plain(sr, sa)
			local dbp, dgp, drp = plain(db, da), plain(dg, da), plain(dr, da)
			local ab, ag, ar

			if mode == MULTIPLY then
				ab, ag, ar = sbp * dbp / 255, sgp * dgp / 255, srp * drp / 255
			elseif mode == SCREEN then
				ab, ag, ar = 255 - (255 - sbp) * (255 - dbp) / 255, 255 - (255 - sgp) * (255 - dgp) / 255,
					255 - (255 - srp) * (255 - drp) / 255
			elseif mode == DARKEN then
				ab, ag, ar = math.min(sbp, dbp), math.min(sgp, dgp), math.min(srp, drp)
			else
				ab, ag, ar = math.max(sbp, dbp), math.max(sgp, dgp), math.max(srp, drp)
			end

			blue = mixed(sb, db, ab)
			green = mixed(sg, dg, ag)
			red = mixed(sr, dr, ar)
			alpha = sa + da * (1 - sa / 255)
		else
			-- Source over backdrop, which is what the rest of them come to on a picture.
			blue = sb + db * (1 - sa / 255)
			green = sg + dg * (1 - sa / 255)
			red = sr + dr * (1 - sa / 255)
			alpha = sa + da * (1 - sa / 255)
		end

		into[at] = math.min(255, blue)
		into[at + 1] = math.min(255, green)
		into[at + 2] = math.min(255, red)
		into[at + 3] = math.min(255, alpha)
	end
end

-- How many nodes of a graph have been read, which is what stops a font that is a graph of itself.
local nodes = 0

--- Paints a node of a graph, and everything under it, into a buffer.
---@param library ffi.cdata*
---@param face texter.freetype.ffi.Face
---@param opaque FT_OpaquePaint
---@param into ffi.cdata* # Where it is painted, four bytes a pixel, cleared by the caller
---@param width number
---@param height number
---@param placement texter.paint.Placement
---@param depth number
---@param palette ffi.cdata*?
---@param left number # Where the picture's own corner is against the glyph's origin
---@param top number
---@return boolean painted
local function paintNode(library, face, opaque, into, width, height, placement, depth, palette, left, top)
	if depth > MAX_DEPTH or nodes > MAX_NODES then
		return false
	end

	nodes = nodes + 1

	local node = ffi.new("FT_COLR_Paint[1]")

	if library.FT_Get_Paint(face, opaque, node) == 0 then
		return false
	end

	local format = node[0].format
	local pixels = width * height

	if format == SOLID then
		local entry = node[0].u.solid.color
		local at = colourOf(palette, entry.palette_index, entry.alpha / ONE_2_14)
		local bytes = ffi.cast("unsigned char *", into)
		local blue = math.floor(at.blue * at.alpha * 255 + 0.5)
		local green = math.floor(at.green * at.alpha * 255 + 0.5)
		local red = math.floor(at.red * at.alpha * 255 + 0.5)
		local alpha = math.floor(at.alpha * 255 + 0.5)

		for pixel = 0, pixels - 1 do
			local step = pixel * 4

			bytes[step], bytes[step + 1], bytes[step + 2], bytes[step + 3] = blue, green, red, alpha
		end

		return true
	elseif format == LINEAR or format == RADIAL or format == SWEEP then
		local line, gradient

		if format == LINEAR then
			line, gradient = node[0].u.linear_gradient.colorline, node[0].u.linear_gradient
		elseif format == RADIAL then
			line, gradient = node[0].u.radial_gradient.colorline, node[0].u.radial_gradient
		else
			line, gradient = node[0].u.sweep_gradient.colorline, node[0].u.sweep_gradient
		end

		local stops = stopsOf(library, face, ffi.new("FT_ColorLine[1]", line), palette)

		if #stops == 0 then
			return false
		end

		-- A gradient is stated in the space the graph is in and what is painted is pixels: what is
		-- asked about is where a pixel is in that space, which is what the root of the graph turns
		-- into pixels, and a transform above the gradient is undone for it as well -- because the
		-- gradient is painted in the space of the shape it is painted on.
		local scaleX, scaleY = toPixels.xx, toPixels.yy

		local determinant = placement.xx * placement.yy - placement.xy * placement.yx
		local undo = nil

		if not still(placement) and determinant ~= 0 then
			undo = { xx = placement.yy / determinant, xy = -placement.xy / determinant,
				yx = -placement.yx / determinant, yy = placement.xx / determinant }
		end

		local bytes = ffi.cast("unsigned char *", into)

		for row = 0, height - 1 do
			for column = 0, width - 1 do
				-- Where the pixel is in the graph's own coordinates, which is where the gradient
				-- is: what the root of the graph says a coordinate comes to, read the other way.
				local x, y = (left + column - toPixels.dx) / scaleX, (top - row - toPixels.dy) / scaleY

				if undo ~= nil then
					x, y = (x - placement.dx) * undo.xx + (y - placement.dy) * undo.xy,
						(x - placement.dx) * undo.yx + (y - placement.dy) * undo.yy
				end

				local at

				if format == LINEAR then
					local x0, y0 = fixed(gradient.p0.x), fixed(gradient.p0.y)
					local x1, y1 = fixed(gradient.p1.x), fixed(gradient.p1.y)
					local x2, y2 = fixed(gradient.p2.x), fixed(gradient.p2.y)
					local px, py = x - x0, y - y0

					-- The stops are laid along the line from p0 to p1, and p2 turns it: with a p2
					-- that is not p0 the point is read in the two of them as a frame, which is what
					-- makes a rotated gradient rotated.
					local along1x, along1y = x1 - x0, y1 - y0
					local along2x, along2y = x2 - x0, y2 - y0
					local det = along1x * along2y - along1y * along2x

					if det ~= 0 then
						at = (px * along2y - py * along2x) / det
					else
						local length = along1x * along1x + along1y * along1y

						at = length > 0 and (px * along1x + py * along1y) / length or 0
					end
				elseif format == RADIAL then
					local x0, y0 = fixed(gradient.c0.x), fixed(gradient.c0.y)
					local x1, y1 = fixed(gradient.c1.x), fixed(gradient.c1.y)
					local r0, r1 = fixed(gradient.r0), fixed(gradient.r1)
					-- The two circles, and where the point is on the cone through them: the
					-- quadratic in t whose solution is the one that is outside both of them.
					local dx, dy, dr = x1 - x0, y1 - y0, r1 - r0
					local px, py = x - x0, y - y0
					local a = dx * dx + dy * dy - dr * dr
					local b = px * dx + py * dy + r0 * dr
					local c = px * px + py * py - r0 * r0

					if a == 0 then
						at = b ~= 0 and -c / (2 * b) or 0
					else
						local inside = b * b - a * c

						if inside < 0 then
							at = 0
						else
							local root = math.sqrt(inside)

							at = (-b + root) / a

							-- A negative radius is a cone turned inside out, and what is wanted of
							-- it is the other side of it.
							if r0 + (r1 - r0) * at < 0 then
								at = (-b - root) / a
							end
						end
					end
				else
					local cx, cy = fixed(gradient.center.x), fixed(gradient.center.y)
					local from = fixed(gradient.start_angle) * 180
					local to = fixed(gradient.end_angle) * 180
					-- The angles are counted from the y axis and the other way round from the way a
					-- screen counts them, and a sweep is finished where it started.
					local turns = 360
					local angle = math.deg(math.atan(x - cx, y - cy))
					local span = (to - from) % turns

					if span == 0 then
						span = turns
					end

					at = ((angle - from) % turns) / span
				end

				local red, green, blue, alpha = between(stops, carried(line.extend, at))
				local step = (row * width + column) * 4

				bytes[step] = math.floor(blue * alpha * 255 + 0.5)
				bytes[step + 1] = math.floor(green * alpha * 255 + 0.5)
				bytes[step + 2] = math.floor(red * alpha * 255 + 0.5)
				bytes[step + 3] = math.floor(alpha * 255 + 0.5)
			end
		end

		return true
	elseif format == COLR_LAYERS then
		-- The layers of a picture are painted one after another onto nothing, and what comes of
		-- them is what the node is: a picture over a picture over nothing.
		local inner = assert(levels[depth + 1], "a graph is nested deeper than it is allowed to be")
		local iterator = ffi.new("FT_LayerIterator[1]")
		local opaque2 = ffi.new("FT_OpaquePaint[1]")
		local painted = false

		iterator[0] = node[0].u.colr_layers.layer_iterator

		ffi.fill(inner, pixels * 4, 0)

		while library.FT_Get_Paint_Layers(face, iterator, opaque2) ~= 0 do
			local layer = assert(levels[depth + 2], "a graph is nested deeper than it is allowed to be")

			ffi.fill(layer, pixels * 4, 0)

			if paintNode(library, face, opaque2[0], layer, width, height, placement, depth + 2, palette, left, top) then
				blend(SRC_OVER, inner, layer, pixels)
				painted = true
			end
		end

		if not painted then
			return false
		end

		blend(SRC_OVER, into, inner, pixels)

		return true
	elseif format == GLYPH then
		-- A shape with a paint on it: the paint is what is painted, and the shape says where.
		local inner = assert(levels[depth + 1], "a graph is nested deeper than it is allowed to be")
		local glyph = node[0].u.glyph.glyphID

		if library.FT_Load_Glyph(face, glyph, LOAD_NO_BITMAP + LOAD_NO_SCALE) ~= 0 then
			return false
		end

		local slot = face.glyph

		local matrix = ffi.new("FT_Matrix[1]")

		if not still(placement) then
			-- Where the shape is drawn is where the nodes above it put it, which is done to the
			-- outline rather than to the pixels: a shape moved is a shape drawn somewhere else, and
			-- what moves it is in the space the graph states it in.
			matrix[0].xx, matrix[0].xy = math.floor(placement.xx * ONE_16_16 + 0.5),
				math.floor(placement.xy * ONE_16_16 + 0.5)
			matrix[0].yx, matrix[0].yy = math.floor(placement.yx * ONE_16_16 + 0.5),
				math.floor(placement.yy * ONE_16_16 + 0.5)

			library.FT_Outline_Transform(slot.outline, matrix)
			library.FT_Outline_Translate(slot.outline, math.floor(placement.dx + 0.5),
				math.floor(placement.dy + 0.5))
		end

		-- And then what the graph's own coordinates come to in pixels, which is what the root of it
		-- says: what an outline is drawn into a bitmap in is 26.6, so what the shape is scaled by
		-- is that transform sixty-four times over, and moved by it as well.
		matrix[0].xx, matrix[0].xy = math.floor(toPixels.xx * 64 * ONE_16_16 + 0.5),
			math.floor(toPixels.xy * 64 * ONE_16_16 + 0.5)
		matrix[0].yx, matrix[0].yy = math.floor(toPixels.yx * 64 * ONE_16_16 + 0.5),
			math.floor(toPixels.yy * 64 * ONE_16_16 + 0.5)

		library.FT_Outline_Transform(slot.outline, matrix)
		library.FT_Outline_Translate(slot.outline, math.floor(toPixels.dx * 64 + 0.5),
			math.floor(toPixels.dy * 64 + 0.5))

		if library.FT_Render_Glyph(slot, RENDER_NORMAL) ~= 0 then
			return false
		end

		local shape = slot.bitmap

		if shape.pixel_mode ~= PIXEL_MODE_GRAY or shape.width == 0 or shape.rows == 0 then
			return false
		end

		ffi.fill(inner, pixels * 4, 0)

		if not paintNode(library, face, node[0].u.glyph.paint, inner, width, height, NOWHERE, depth + 1, palette, left,
				top) then
			return false
		end

		local source = ffi.cast("unsigned char *", inner)
		local target = ffi.cast("unsigned char *", into)

		-- Where the shape's own bitmap sits in the picture: a bitmap says how far its corner is
		-- from the glyph's origin, and the picture knows where its own corner is.
		local across = tonumber(slot.bitmap_left) - left
		local down = top - tonumber(slot.bitmap_top)

		for row = 0, tonumber(shape.rows) - 1 do
			local intoRow = down + row

			if intoRow >= 0 and intoRow < height then
				local from = shape.buffer + row * tonumber(shape.pitch)

				for column = 0, tonumber(shape.width) - 1 do
					local intoColumn = across + column

					if intoColumn >= 0 and intoColumn < width then
						local coverage = from[column]

						if coverage > 0 then
							local at = (intoRow * width + intoColumn) * 4
							local alpha = source[at + 3] * coverage / 255

							over(target, at, source[at] * coverage / 255, source[at + 1] * coverage / 255,
								source[at + 2] * coverage / 255, alpha)
						end
					end
				end
			end
		end

		return true
	elseif format == COLR_GLYPH then
		local opaque2 = ffi.new("FT_OpaquePaint[1]")

		if library.FT_Get_Color_Glyph_Paint(face, node[0].u.colr_glyph.glyphID, NO_ROOT_TRANSFORM, opaque2) == 0 then
			return false
		end

		return paintNode(library, face, opaque2[0], into, width, height, placement, depth + 1, palette, left, top)
	elseif format == TRANSFORM or format == TRANSLATE or format == SCALE or format == ROTATE or format == SKEW then
		local inner, moved

		if format == TRANSFORM then
			local affine = node[0].u.transform.affine

			inner = node[0].u.transform.paint
			moved = after(placement, fixed(affine.xx), fixed(affine.xy), fixed(affine.yx),
				fixed(affine.yy), fixed(affine.dx), fixed(affine.dy))
		elseif format == TRANSLATE then
			inner = node[0].u.translate.paint
			moved = after(placement, 1, 0, 0, 1, fixed(node[0].u.translate.dx), fixed(node[0].u.translate.dy))
		elseif format == SCALE then
			local scale = node[0].u.scale
			local x, y = fixed(scale.scale_x), fixed(scale.scale_y)
			local centerX, centerY = fixed(scale.center_x), fixed(scale.center_y)

			inner = scale.paint
			-- A scale is about a centre, which is a move to it, the scale, and a move back.
			moved = after(placement, 1, 0, 0, 1, centerX, centerY)
			moved = after(moved, x, 0, 0, y, 0, 0)
			moved = after(moved, 1, 0, 0, 1, -centerX, -centerY)
		elseif format == ROTATE then
			local rotate = node[0].u.rotate
			local angle = fixed(rotate.angle) * math.pi
			local cos, sin = math.cos(angle), math.sin(angle)
			local centerX, centerY = fixed(rotate.center_x), fixed(rotate.center_y)

			inner = rotate.paint
			moved = after(placement, 1, 0, 0, 1, centerX, centerY)
			moved = after(moved, cos, -sin, sin, cos, 0, 0)
			moved = after(moved, 1, 0, 0, 1, -centerX, -centerY)
		else
			local skew = node[0].u.skew
			local x = math.tan(fixed(skew.x_skew_angle) * math.pi)
			local y = math.tan(fixed(skew.y_skew_angle) * math.pi)
			local centerX, centerY = fixed(skew.center_x), fixed(skew.center_y)

			inner = skew.paint
			moved = after(placement, 1, 0, 0, 1, centerX, centerY)
			moved = after(moved, 1, x, y, 1, 0, 0)
			moved = after(moved, 1, 0, 0, 1, -centerX, -centerY)
		end

		return paintNode(library, face, inner, into, width, height, moved, depth + 1, palette, left, top)
	elseif format == COMPOSITE then
		-- Two pictures and how they are put together: the source over the backdrop is the one a
		-- font of pictures uses to put a highlight on a shape.
		local composite = node[0].u.composite
		local source = assert(levels[depth + 1], "a graph is nested deeper than it is allowed to be")
		local backdrop = assert(levels[depth + 2], "a graph is nested deeper than it is allowed to be")

		ffi.fill(source, pixels * 4, 0)
		ffi.fill(backdrop, pixels * 4, 0)

		local paintedSource = paintNode(library, face, composite.source_paint, source, width, height, placement,
			depth + 2, palette, left, top)
		local paintedBackdrop = paintNode(library, face, composite.backdrop_paint, backdrop, width, height, placement,
			depth + 2, palette, left, top)

		if not paintedSource and not paintedBackdrop then
			return false
		end

		blend(composite.composite_mode, backdrop, source, pixels)
		blend(SRC_OVER, into, backdrop, pixels)

		return true
	end

	return false
end

local paint = {}

--- Whether this face has a graph of how to paint this glyph, which is what a colour glyph of the
--- newest kind is: a picture rather than an outline, and nothing FreeType draws by itself.
---@param library ffi.cdata*
---@param face texter.freetype.ffi.Face
---@param glyph number
---@return boolean
function paint.has(library, face, glyph)
	local opaque = ffi.new("FT_OpaquePaint[1]")

	return library.FT_Get_Color_Glyph_Paint(face, glyph, INCLUDE_ROOT_TRANSFORM, opaque) ~= 0
end

--- The box a colour glyph is painted in, which is what the graph comes to rather than what the
--- glyph's own empty outline comes to: what a caller is handed as the size of the picture.
---@param library ffi.cdata*
---@param face texter.freetype.ffi.Face
---@param glyph number
---@param height number # The pixel height the face is at, for a font that states no box
---@return number left
---@return number top
---@return number width
---@return number height
function paint.boxOf(library, face, glyph, height)
	local box = ffi.new("FT_ClipBox[1]")

	if library.FT_Get_Color_Glyph_ClipBox(face, glyph, box) ~= 0 then
		-- What a vector of it is, is a cdata of its own: a number of pixels is a number.
		local xMin, yMin = tonumber(box[0].bottom_left.x), tonumber(box[0].bottom_left.y)
		local xMax, yMax = tonumber(box[0].top_right.x), tonumber(box[0].top_left.y)

		if xMax > xMin and yMax > yMin then
			local left = math.floor(xMin / 64)
			local top = math.ceil(yMax / 64)

			return left, top, math.ceil(xMax / 64) - left, top - math.floor(yMin / 64)
		end
	end

	-- A font that states no box of its own is drawn in the room a line of it has, which is what a
	-- picture of a glyph is: one that is bigger than that is bigger than anything drawing it wants.
	local ascent, descent = face.ascender, face.descender
	local scale = (ascent - descent) > 0 and height / (ascent - descent) or 1

	return 0, math.ceil(ascent * scale), math.ceil(height), math.ceil(height)
end

--- Paints a colour glyph into a buffer, which is what a caller hands to a font of pictures: four
--- bytes a pixel, blue, green, red and alpha, each multiplied by the alpha.
---
--- What comes back is whether the glyph was a graph at all: a glyph that is not one is a glyph some
--- other path draws.
---@param library ffi.cdata*
---@param face texter.freetype.ffi.Face
---@param glyph number
---@param into ffi.cdata* # Where it is painted, the size of the box
---@param left number # Where the box is against the glyph's origin
---@param top number
---@param width number
---@param height number
---@return boolean painted
function paint.into(library, face, glyph, into, left, top, width, height)
	local opaque = ffi.new("FT_OpaquePaint[1]")

	if library.FT_Get_Color_Glyph_Paint(face, glyph, INCLUDE_ROOT_TRANSFORM, opaque) == 0 then
		return false
	end

	-- What a graph is drawn in is a space of its own and what the root of it says is how that space
	-- comes to pixels: everything below is painted in those coordinates, and this is the one thing
	-- that is not.
	local start = opaque[0]
	local first = ffi.new("FT_COLR_Paint[1]")

	if library.FT_Get_Paint(face, start, first) ~= 0 and first[0].format == TRANSFORM then
		local affine = first[0].u.transform.affine

		toPixels = { xx = fixed(affine.xx), xy = fixed(affine.xy), yx = fixed(affine.yx), yy = fixed(affine.yy),
			dx = fixed(affine.dx), dy = fixed(affine.dy) }
		start = first[0].u.transform.paint
	else
		toPixels = NOWHERE
	end

	grow(width * height)

	local root = assert(levels[1])

	ffi.fill(root, width * height * 4, 0)

	nodes = 0

	if not paintNode(library, face, start, root, width, height, NOWHERE, 1, paletteOf(library, face), left, top) then
		return false
	end

	ffi.copy(into, root, width * height * 4)

	return true
end

return paint
