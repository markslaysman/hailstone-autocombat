-- Named settings profiles. Pure helpers: storage is handled by init.lua through mq.pickle.
-- The default profile continues to use the original per-character settings file.
local M = {}

local function name(value)
  if type(value) ~= 'string' then return nil end
  value = value:lower()
  if #value == 0 or #value > 32 or not value:match('^[%w_%-]+$') then return nil end
  return value
end
M.name = name

function M.manifest_path(base)
  return (base:gsub('%.lua$', '')) .. '__profiles.lua'
end

function M.settings_path(base, value)
  value = name(value)
  if not value then return nil end
  if value == 'default' then return base end
  return (base:gsub('%.lua$', '')) .. '__profile_' .. value .. '.lua'
end

function M.repair(given)
  given = type(given) == 'table' and given or {}
  local result = { version = 1, active = 'default', names = { 'default' } }
  local seen = { default = true }
  for _, value in ipairs(type(given.names) == 'table' and given.names or {}) do
    local n = name(value)
    if n and not seen[n] then
      result.names[#result.names + 1] = n
      seen[n] = true
    end
  end
  local active = name(given.active)
  if active and seen[active] then result.active = active end
  return result
end

function M.has(manifest, value)
  local n = name(value)
  if not n then return false end
  for _, existing in ipairs(manifest.names) do
    if existing == n then return true end
  end
  return false
end

function M.add(manifest, value)
  local n = name(value)
  if not n or M.has(manifest, n) then return nil end
  local result = M.repair(manifest)
  result.names[#result.names + 1] = n
  return result
end

function M.activate(manifest, value)
  local n = name(value)
  if not n or not M.has(manifest, n) then return nil end
  local result = M.repair(manifest)
  result.active = n
  return result
end

return M
