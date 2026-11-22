-- The tests and the runner of lde-test, as modules of this app: an APK carries only its bundle, so
-- what the phone runs has to be in it.
local build = require("lde-build")

local sep = package.config:sub(1, 1)
local root = build.outDir .. sep .. ".." .. sep .. ".." .. sep
local tests = root .. ".." .. sep .. ".." .. sep .. "packages" .. sep .. "texter-android" .. sep .. "tests" .. sep .. "android.test.lua"
local runner = root .. "target" .. sep .. "lde-test" .. sep .. "test.lua"

---@param path string
local function slurp(path)
	local file = assert(io.open(path, "rb"), "missing " .. path)
	local content = file:read("*a")
	file:close()
	return content
end

build:write("suite.lua", slurp(tests))

-- lde-test keeps its runner as a string so it can be loaded into a fresh state; here it is loaded
-- into this one.
local source = assert(slurp(runner):match("local SOURCE = %[==%[(.-)%]==%]"), "lde-test runner not found")
build:write("runner.lua", "return [==[" .. source .. "]==]\n")
