-- What shaping and packing a screen of text costs, for measuring changes to this library.
--
--   lde run bench.lua                          -- the numbers
--   lde run bench.lua --jit                    -- and which hot code never compiled
--   ROUNDS=5000 BATCHES=8 lde run bench.lua    -- more rounds, the fastest batch kept
--
-- Two numbers matter: the milliseconds, which are the fastest batch of several -- a machine doing
-- other things only ever makes a batch slower -- and the kilobytes a call allocates, which is what
-- the collector then has to pay for. A line of text is shaped once a frame in a screen that rebuilds
-- its view, and every glyph of it is inked once, so those are the two calls measured here.
io.stdout:setvbuf("line")

local texter = require("texter")

local FONT_PATHS = {
	"/usr/share/fonts/google-noto/NotoSans-Regular.ttf",
	"/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf",
	"/usr/share/fonts/TTF/DejaVuSans.ttf",
	"/System/Library/Fonts/Supplemental/Arial.ttf",
	"C:/Windows/Fonts/arial.ttf",
}

local ROUNDS = tonumber(os.getenv("ROUNDS") or "2000")
local BATCHES = tonumber(os.getenv("BATCHES") or "8")

---@return string? path
local function aFont()
	for _, path in ipairs(FONT_PATHS) do
		local file = io.open(path, "rb")

		if file then
			file:close()

			return path
		end
	end
end

local fontPath = aFont()

print(string.format("texter %s, backend %s", tostring(texter.available()), tostring(texter.name)))

if not texter.available() or fontPath == nil then
	print("  " .. tostring(texter.why() or "no font found to shape with"))

	os.exit(1)
end

local face = assert(texter.face(fontPath))

print(string.format("font %s\n", fontPath))

--- Runs what is handed to it a batch at a time and prints the fastest of them, with what one call
--- allocated.
---@param name string
---@param work fun()
---@param rounds number?
local function measure(name, work, rounds)
	rounds = rounds or ROUNDS

	for _ = 1, math.max(20, math.floor(rounds / 10)) do
		work()
	end

	collectgarbage("collect")
	collectgarbage("stop")

	local before = collectgarbage("count")
	local allocated = 0
	local best = math.huge

	for _ = 1, BATCHES do
		allocated = allocated + (collectgarbage("count") - before)
		before = collectgarbage("count")

		local start = os.clock()

		for _ = 1, rounds do
			work()
		end

		best = math.min(best, (os.clock() - start) / rounds * 1000)
	end

	collectgarbage("restart")

	print(string.format("  %-34s %8.4f ms  %8.2f KB", name, best, allocated / (rounds * BATCHES)))
end

-- The lines a screen is made of: a label, a sentence, a line of two directions, and one long
-- enough that the work is per character rather than per call.
local LABEL = "Settings"
local SENTENCE = "the quick brown fox jumps over the lazy dog, and then does it again"
local MIXED = "abc مرحبا abc"
local paragraphs = {}

for index = 1, 40 do
	paragraphs[index] = SENTENCE
end

measure("shape a label, 16px", function()
	texter.shape(face, LABEL, 16)
end)

measure("shape a sentence, 16px", function()
	texter.shape(face, SENTENCE, 16)
end)

measure("shape a line of two directions, 24px", function()
	texter.shape(face, MIXED, 24)
end, 1000)

measure("shape an empty line", function()
	texter.shape(face, "", 16)
end)

measure("metrics of a face at a size", function()
	texter.metrics(face, 16)
end)

local line = texter.shape(face, SENTENCE, 16)
local first = line.glyphs[1].glyph

measure("ink one glyph", function()
	texter.ink(face, first, 16)
end)

-- What a screen of text costs: forty lines shaped, and every glyph of each of them packed.
measure("shape and pack forty lines", function()
	for index = 1, #paragraphs do
		local shaped = texter.shape(face, paragraphs[index], 16)

		for at = 1, #shaped.glyphs do
			texter.ink(face, shaped.glyphs[at].glyph, 16)
		end
	end
end, 100)

-- A size change is what an atlas pays when a screen draws the same font at another size: the face
-- is put at a size, and every glyph after that is at that size.
measure("shape at twenty sizes, one glyph each", function()
	for size = 8, 27 do
		local shaped = texter.shape(face, LABEL, size)

		texter.ink(face, shaped.glyphs[1].glyph, size)
	end
end, 500)
