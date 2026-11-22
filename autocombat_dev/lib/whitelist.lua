-- Standalone development copy of AutoCombat; original addon remains separate.
-- Explicit Hunter targets, stored by zone short name in the character's settings.
-- Matches are case-insensitive full NPC names. EQ's three-digit spawn suffix
-- (e.g. a_fire_beetle005) is ignored so typed names work for respawns too.
local M = {}

M.MAX_ZONES = 64
M.MAX_NAMES = 128
M.MAX_NAME_LENGTH = 120

function M.zone(zone)
  if type(zone) ~= "string" then return nil end
  zone = zone:match("^%s*(.-)%s*$"):lower()
  if #zone == 0 or #zone > 64 or not zone:match("^[%w_%-]+$") then return nil end
  return zone
end

function M.name(name)
  if type(name) ~= "string" then return nil end
  name = name:match("^%s*(.-)%s*$")
  if #name == 0 or #name > M.MAX_NAME_LENGTH or name:find("[%c]") then return nil end
  return name
end

function M.key(name)
  name = M.name(name)
  if not name then return nil end
  name = name:lower():gsub("_", " "):gsub("%s+", " ")
  -- EQ spawn names commonly end in a three-digit instance number. Do not
  -- remove other digits (e.g. 'Model 7' is a distinct NPC name).
  local key = name:gsub("%d%d%d$", ""):gsub("%s+$", "")
  return key ~= "" and key or nil
end

function M.contains(lists, zone, name)
  zone = M.zone(zone)
  local key = M.key(name)
  if not zone or not key or type(lists) ~= "table" then return false end
  for _, n in ipairs(type(lists[zone]) == "table" and lists[zone] or {}) do
    if M.key(n) == key then return true end
  end
  return false
end

-- Loaded files and UI-supplied lists must be bounded and de-duplicated.
function M.repair(raw)
  local out = {}
  if type(raw) ~= "table" then return out end
  local zones = {}
  for zone in pairs(raw) do
    if M.zone(zone) then zones[#zones + 1] = zone end
  end
  table.sort(zones)
  local count = 0
  for _, zone in ipairs(zones) do
    local key = M.zone(zone)
    local source = raw[zone]
    if type(source) == "table" then
      local names, used = {}, {}
      for _, name in ipairs(source) do
        local n, canonical = M.name(name), M.key(name)
        if n and canonical and not used[canonical] then
          names[#names + 1], used[canonical] = n, true
          if #names >= M.MAX_NAMES then break end
        end
      end
      if #names > 0 and not out[key] and count < M.MAX_ZONES then
        out[key], count = names, count + 1
      end
    end
  end
  return out
end

-- Mutate only a validated, repaired list. Return false on duplicate, invalid,
-- or over-limit entries so the caller need not dirty the settings file.
function M.add(lists, zone, name)
  zone, name = M.zone(zone), M.name(name)
  if not zone or not name or not M.key(name) or type(lists) ~= "table" then return false end
  if M.contains(lists, zone, name) then return false end
  if not lists[zone] then
    local count = 0
    for _ in pairs(lists) do count = count + 1 end
    if count >= M.MAX_ZONES then return false end
    lists[zone] = {}
  end
  if #lists[zone] >= M.MAX_NAMES then return false end
  lists[zone][#lists[zone] + 1] = name
  return true
end

function M.remove(lists, zone, name)
  zone = M.zone(zone)
  local key = M.key(name)
  if not zone or not key or type(lists) ~= "table" or type(lists[zone]) ~= "table" then return false end
  for i, existing in ipairs(lists[zone]) do
    if M.key(existing) == key then
      table.remove(lists[zone], i)
      if #lists[zone] == 0 then lists[zone] = nil end
      return true
    end
  end
  return false
end

return M
