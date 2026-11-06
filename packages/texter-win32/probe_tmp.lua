local win32 = require("texter-win32")
local face = assert(win32.face("C:/Windows/Fonts/arial.ttf", 0))
for _, size in ipairs({ 12, 24 }) do
	local line = win32.shape(face, "songs", size)
	local parts = {}
	for _, glyph in ipairs(line.glyphs) do
		local ink = win32.ink(face, glyph.glyph, size, { offset = 0 })
		parts[#parts + 1] = string.format("adv %.2f ink %dx%d left %d", glyph.advance, ink.width, ink.height, ink.left)
	end
	print(string.format("size %d width %.2f em %s scale %.4f", size, line.width, tostring(face.em), face.designScale or -1))
	print("  " .. table.concat(parts, " | "))
	print(string.format("  advance('s') %.2f", face:advance(0x73, size)))
end
