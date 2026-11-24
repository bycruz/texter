-- texter-common: what every backend of texter needs, and none of them is the platform's.
--
--   local common = require("texter-common")
--   local characters = common.utf8.characters("مرحبا")
--   local family = common.sfnt.family(content)
--
-- Two things, and both of them are about the same problem: a platform's text API counts in
-- characters of its own -- UTF-16 units on windows and macOS, codepoints in HarfBuzz -- and what a
-- caret, a click and a selection are about is the byte of a Lua string. Reading a string as
-- characters, and knowing where each of them starts, is what every backend does and none of them
-- should do differently: a caret that lands a byte out is a caret that lands a byte out on every
-- platform together.
--
-- This package is a leaf: the backends depend on it and it depends on nothing, which is what keeps
-- them able to be one per platform without any of them being the one that knows about the others.
-- The bytes of a font, read where they lie: a Lua string a caller already holds, or the view a
-- backend maps the file into. What reads a font's tables asks a view five questions, all from an
-- offset of nought, and a backend that maps a file answers them from the mapping rather than from a
-- copy of the whole font in a Lua string.
---@class texter.common.Bytes
---@field length number # How many bytes there are
---@field u16 fun(self: texter.common.Bytes, at: number): number
---@field u32 fun(self: texter.common.Bytes, at: number): number
---@field tag fun(self: texter.common.Bytes, at: number): string # The four bytes there, as a tag
---@field slice fun(self: texter.common.Bytes, at: number, length: number): string

local cmap = require("texter-common.cmap")
local sfnt = require("texter-common.sfnt")
local utf8 = require("texter-common.utf8")

---@class texter-common
---@field utf8 texter.common.utf8
---@field sfnt texter.common.sfnt
---@field cmap texter.common.cmap
local common = {
	utf8 = utf8,
	sfnt = sfnt,
	cmap = cmap,
}

return common
