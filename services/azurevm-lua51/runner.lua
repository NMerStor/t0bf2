local root = "/app/lib/lua-sources/azurevm/"
package.path = root .. "?.lua;" .. root .. "?/init.lua;" .. package.path

print = function(...)
	local values = {}
	for index = 1, select("#", ...) do
		values[index] = tostring(select(index, ...))
	end
	io.stderr:write(table.concat(values, "\t"), "\n")
end

local source = io.read("*a")
local presetName = arg[1]
local seed = tonumber(arg[2])

if not source or source == "" then
	error("source must be a non-empty string")
end
if not seed or seed < 1 or seed > 2147483647 or seed % 1 ~= 0 then
	error("seed must be an integer between 1 and 2147483647")
end

local presets = require("presets")
local preset = presets[presetName]
if not preset then
	error("Unknown preset: " .. tostring(presetName))
end

if not loadstring(source) then
	local Transpiler = require("prometheus.azure_vm.transpiler")
	source = Transpiler.transpile(source)
end

local Pipeline = require("prometheus.pipeline")
local pipeline = Pipeline:fromConfig(preset)
pipeline.Seed = seed
pipeline.seed = seed

local output = pipeline:apply(source)
io.stdout:write(output)
