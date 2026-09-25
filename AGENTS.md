# Using lde

This project is built using lde. Read https://lde.sh/llms.txt for everything you need
to know about building, running, handling dependencies and running tests.

# Things about LuaJIT that cost a day to find

## An array of characters is never made with its bytes beside its length

```lua
-- No. This corrupts the heap, and nothing is wrong where it happens.
local buffer = ffi.new("char[?]", #content, content)

-- Yes.
local buffer = ffi.new("char[?]", #content)

ffi.copy(buffer, content, #content)
```

An array with an unknown length -- anything spelled `[?]` -- that is handed its contents as a
*string* initialiser is a shape this LuaJIT gets wrong as soon as another large cdata object is
alive: what it writes is not where the object is, and what is corrupted is the allocator's own
bookkeeping, so the crash comes later and somewhere else -- in `lj_alloc_free`, at the end of a run
that passed every one of its tests, or not at all. What is needed to see it is a large allocation
held while the small arrays are made; a font file of half a megabyte is large enough.

The same array initialised from a *table* is fine, and an array with a length written out in the
type -- `unsigned char[8]` -- is fine. It is the unknown length and the string together.

`packages/texter-freetype/tests/freetype.test.lua` has a `buffer` helper that is what to copy.
