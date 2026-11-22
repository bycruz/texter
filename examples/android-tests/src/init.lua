local android = require("androidapi")

local passed, failed, skipped = 0, 0, 0

---@param name string
---@param ok boolean
---@param skip boolean
---@param err string?
local function onResult(name, ok, skip, err)
	if skip then
		skipped = skipped + 1
		android.log("info", "SKIP " .. name)
	elseif ok then
		passed = passed + 1
		android.log("info", "PASS " .. name)
	else
		failed = failed + 1
		android.log("error", "FAIL " .. name .. ": " .. tostring(err))
	end
end

local runSuite = assert(load(require("texter-android-tests.runner"), "@lde-test.test"))(onResult)
require("texter-android-tests.suite")
runSuite()

android.log("info", string.format("RESULT %d passed, %d failed, %d skipped", passed, failed, skipped))
android.finish()
