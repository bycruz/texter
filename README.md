# texter

Text shaping and glyphs from what the machine already has.

A bundle of texter is nothing at all. Reading a font file, turning a string into the glyphs it is
drawn from, and drawing one of those glyphs is text, and every desktop already has a library that
does it -- the one it draws its own windows with. What this package is, is one API over whichever
of those the machine turned out to have.

That is worth more than it sounds, because what a desktop's own text library knows is every script
the desktop can display:

- **Arabic, Hebrew, Syriac** are joined and reordered rather than drawn a letter at a time.
- **Devanagari, Thai, Khmer, Myanmar** are reordered and stacked by the script's own rules.
- **Chinese, Japanese, Korean** are read out of fonts whose outlines are CFF, which a reader of
  TrueType outlines alone cannot open.
- **Emoji** come as the font's own bitmaps and layers.
- **A line of two directions** -- a word of Arabic inside a line of English -- is cut into runs and
  put in the order a screen draws them.

None of that is written here, and none of it is a package a caller has to find: it is the platform.

## Backends

| Platform | Package | What it uses |
| -------- | ------- | ------------ |
| linux, android | `texter-freetype` | FreeType, HarfBuzz, fribidi |
| windows | `texter-win32` | Uniscribe (`usp10`) and GDI (`gdi32`) |
| macOS | `texter-coretext` | CoreText and CoreGraphics |

The backend is picked by the platform and pulled in by the feature that platform turns on, which is
what `packages/texter/lde.json` says and what lde does with it:

```json
"features": {
	"linux": ["texter-freetype"],
	"android": ["texter-freetype"],
	"windows": ["texter-win32"],
	"macos": ["texter-coretext"]
}
```

A program on linux installs `texter-freetype` and neither of the other two, and the code that could
not run where it is running is not in the bundle, not in the lockfile and not on disk. What is left
in the bundle is a handful of lua files -- the API, the backend of that platform, and the reading of
strings and names the two of them share -- and not a line of C.

## Installation

```bash
lde add texter
```

```lua
local texter = require("texter")

if not texter.available() then
	print(texter.why())   -- "No FreeType on this machine: it is what reads font files and draws
	                      -- their glyphs", or which of the backend's libraries is not there
end

local face = assert(texter.face("/usr/share/fonts/google-noto/NotoSans-Regular.ttf"))
local line = texter.shape(face, "abc مرحبا abc", 24)

for _, glyph in ipairs(line.glyphs) do
	-- in the order a screen draws them, from the left: where to put it, which glyph of the font
	-- it is, and which byte of the string it came from
	local ink = texter.ink(face, glyph.glyph, 24)
	print(glyph.x, glyph.glyph, glyph.cluster, ink.width, ink.height, ink.left, ink.top)
end
```

`examples/shapes` is the same thing as a program that prints what every sample came to, and it is
the thing to run on a machine whose backend has never run there:

```bash
lde run -C examples/shapes
```

## What it answers with

| | |
| - | - |
| `texter.available()` | whether this machine has the libraries text is drawn with |
| `texter.why()` | what is missing, where it is missing |
| `texter.face(path, index?)` | a font file read: a whole file, one font of a collection, at any size afterwards |
| `texter.shape(face, text, pixelHeight, opts?)` | a line: the glyphs it is drawn from, where each goes, and which byte of the string it came from |
| `texter.ink(face, glyph, pixelHeight)` | one glyph of a font: eight bits of coverage a pixel, its size, and where it sits |
| `texter.metrics(face, pixelHeight)` | how tall a line of it is: above the baseline, below it, and the gap between lines |
| `texter.penOf(line, byte)` | where a caret for a byte of the line goes |
| `texter.byteAt(line, x)` | which byte of the line a point is over |
| `texter.install()` | hands all of it to wonderland, if wonderland is there |

What those come back as is described in `packages/texter/src/init.lua` as `texter.Face`,
`texter.Line`, `texter.Glyph`, `texter.Run` and `texter.Ink`. Three things about them are the
contract every backend keeps, and they are what makes this a library rather than three bindings:

**A cluster is a byte of the string.** Not a character, not a UTF-16 unit and not a glyph: the byte
of the Lua string that glyph came from, from nought. That is what a caret, a click and a selection
are about. Windows counts a line in UTF-16 units and macOS the same, HarfBuzz counts characters, and
all three are mapped back to bytes by `texter-common`.

**A line is in the order a screen draws it.** `line.glyphs` goes left to right, whatever direction
the text reads in, so a renderer draws them in the order they came and never has to know about bidi.
`line.runs` are the same for the stretches of the line that are set in one direction, in the order
they are drawn in, each with the bytes it covers and whether it is set right to left.

**A pixel height is a line's height.** How tall a line of a font is at that size is what `metrics`
answers, and what a glyph's ink is measured against: `ink.left` from the pen and `ink.top` from the
baseline, both in whole pixels, `ink.top` nought or less for a glyph that sits above the baseline.
It is not an em size, and it is not the size a font file says.

## It has been run on these

| | linux | windows | macOS |
| - | ----- | ------- | ----- |
| machine | Nobara 44 (KDE), x86_64 | Windows 10.0.26200, x86_64 | macOS 14.8.8, x86_64 |
| `texter` | 2 passed | 2 passed | 2 passed |
| `texter-common` | 6 passed | 6 passed | 6 passed |
| `texter-freetype` | 9 passed, 1 skipped | – | – |
| `texter-win32` | – | 10 passed | – |
| `texter-coretext` | – | – | 10 passed |
| `examples/shapes` | run | run | run |

A package of another platform's backend skips rather than fails, which is what the skips are.

What each backend was verified to have got right is in its own tests, and what running it on the
machine changed is written at the top of each backend's source: on windows the matrix a glyph
outline is asked for is four sixteen point sixteen longs, and not the shorts the name `MAT2`
suggests, and every glyph of every font comes back as an error until that is right. On macOS a
`CFIndex` is a long, and a range of a line declared as an int is a range CoreText reads out of
nothing: every glyph of a run comes back nought, no index has a byte, and nothing about it is an
error. Both of those were found by running this, which is the reason this section is a table.

## What is not in it

| | |
| - | - |
| Shaping *inside* a line of wonderland | texter shapes a line and wonderland's text layout draws a glyph a character, so a run of Arabic is drawn by texter's readers and as its letters apart by wonderland's layout. What is left is putting `texter.shape` between them |
| Laying a paragraph out | wrapping, line breaking, justification, tabs, hanging punctuation: a line is what this shapes, and a paragraph is a thing to be written on top of it |
| A font that is not where a caller looked | a chain of faces to fall back through is what `Line` and `hasGlyph` are for, and one is in wonderland's font manager; there is none in here |
| Colour emoji, as a painter | the coverage of a glyph is what an atlas packs, so a font whose emoji are bitmaps (`CBDT`, `sbix`) works and a COLR v1 font -- which is what `Noto Color Emoji` is on most desktops -- is a paint graph a client draws itself |
| macOS fallback fonts | CoreText puts a font of its own in for a script a face has not got: those glyph ids are not of the face, so their ink is nothing. A caller that draws them opens a face that has them |
| A line height that is exact on windows | GDI's font mapper rasterises in whole pixels and has no cell for every size: twenty-four pixels is twenty-four, twenty is nineteen, and asking again is what settles on the closest of them |
| An installed font, by name | a face is a file: what fonts a machine has, and which one is called `Noto Sans`, is `fontconfig` and a font directory walk, which is wonderland's `wonderland.font.scan` |
| Phones | a phone reports itself as linux or as iOS, and it is the linux backend that would run on android; iOS has no backend at all, which is what `why()` says there. Neither has been run on a phone |

## The packages

| | |
| - | - |
| `packages/texter` | the one API over whatever the machine has, and the classes every backend answers with |
| `packages/texter-common` | reading a string as characters and where each of them starts, and reading a font file's own name table. A leaf: no dependencies, and both backends depend on it so that a caret lands in the same place on every platform |
| `packages/texter-freetype` | FreeType, HarfBuzz and fribidi through ffi |
| `packages/texter-win32` | Uniscribe and GDI through ffi |
| `packages/texter-coretext` | CoreText and CoreGraphics through ffi |

## Testing

There is no test runner to install: every package has tests, and `lde test` runs the ones of the
package it is run in.

```bash
lde test -C packages/texter           # the API and the backend its platform picks
lde test -C packages/texter-freetype  # the machine's own text, if this machine is linux
lde test -C packages/texter-win32     # ... if it is windows
lde test -C packages/texter-coretext  # ... if it is macOS
```

A backend's tests run on the platform they are a backend for and nowhere else: they load the
platform's own libraries, so on anything else they skip rather than fail, which is what makes `lde
test -C packages/texter-win32` on a linux machine a green run with the windows tests skipped.
