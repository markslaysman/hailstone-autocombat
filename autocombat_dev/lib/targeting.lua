-- Standalone development copy of AutoCombat; original addon remains separate.
-- Auto Combat: which mob to fight. Pure: spawns are plain tables from the snapshot (lib/world.lua):
-- { id, name, hp, npc, dead, distance, level, named, con (level colour), faction_con ("Scowling" ...), mezzed, x, y, z,
--   players_near }.
local whitelist = require('lib.whitelist')
local mobcon = require('lib.mobcon')
local M = {}

local function lower(s) return (s or ""):lower() end

-- Hailstone's NPC class IDs (game::PlayerClass in the client). Services
-- aren't hunting targets, even if their faction is hostile to this player.
-- The name fallback covers servers that give an innkeeper a combat class.
local SERVICE_CLASSES = {
  [40] = true, [41] = true, -- banker, merchant
  [58] = true, [59] = true, [60] = true, [61] = true, [62] = true,
  [63] = true, [64] = true, [66] = true, [67] = true, [68] = true,
  [69] = true, [70] = true, [71] = true, [72] = true, [73] = true,
  [74] = true,
}

local function service_npc(spawn)
  local class = tonumber(spawn.class_id)
  if class and ((class >= 20 and class <= 35) or SERVICE_CLASSES[class]) then return true end
  return lower(spawn.name):match("^innkeep") ~= nil
end

-- Whether the targeting settings let this mob be chosen for Hunter.
function M.allowed(spawn, t, zone)
  if spawn.npc == false or spawn.owned then return false end -- no PCs or pets (swarm pets too)
  -- An explicit zone-specific whitelist entry overrides the ordinary filters,
  -- including service classes, ignore names, and faction restrictions.
  if whitelist.contains(t.whitelist, zone, spawn.name) then return true end
  if t.mob_cons and mobcon.none_enabled(t.mob_cons) then return false end
  if service_npc(spawn) then return false end -- no nav to merchants, innkeepers, bankers or trainers
  if t.min_level > 0 and (spawn.level or 0) < t.min_level then return false end
  if t.max_level > 0 and (spawn.level or 0) > t.max_level then return false end
  if spawn.con and t.cons[spawn.con] == false then return false end
  if spawn.faction_con and t.mob_cons and t.mob_cons[spawn.faction_con] == false then return false end
  if spawn.named and not t.named then return false end
  local name = lower(spawn.name)
  for _, n in ipairs(t.ignore) do
    if n ~= "" and name:find(lower(n), 1, true) then return false end
  end
  return true
end

local function better(priority)
  if priority == "highest_hp" then
    return function(a, b) if a.hp ~= b.hp then return a.hp > b.hp end return a.distance < b.distance end
  end
  if priority == "closest" then
    return function(a, b) if a.distance ~= b.distance then return a.distance < b.distance end return a.id < b.id end
  end
  if priority == "named_first" then
    return function(a, b)
      if (a.named or false) ~= (b.named or false) then return a.named == true end
      return a.distance < b.distance
    end
  end
  return function(a, b) if a.hp ~= b.hp then return a.hp < b.hp end return a.distance < b.distance end
end

-- The mob on me to fight: the current one while it is still on me and not mezzed (no switching mid-fight), else the
-- best by priority, leaving mezzed ones until nothing else is left. Haters are fought whatever the filters say:
-- they are fighting me.
function M.choose_hater(haters, current_id, priority)
  if #haters == 0 then return nil end
  for _, h in ipairs(haters) do
    if h.id == current_id and not h.mezzed then return h end
  end
  local awake = {}
  for _, h in ipairs(haters) do
    if not h.mezzed then awake[#awake + 1] = h end
  end
  local pool = #awake > 0 and awake or haters
  table.sort(pool, better(priority))
  return pool[1]
end

local function flat(a, b)
  local dx, dy = a[1] - b[1], a[2] - b[2]
  return math.sqrt(dx * dx + dy * dy)
end

-- Hunter: the mobs worth walking to, best first. `from` is where it looks from (me, or the camp), `skip` the ids
-- given up on. `whole_zone` drops the search radius (roam, when nothing is near). The second result counts the mobs
-- the targeting settings left out, for the status line.
function M.hunt_candidates(spawns, t, h, from, skip, camp_style, whole_zone, zone)
  local out, filtered = {}, 0
  for _, s in ipairs(spawns) do
    local is_white = whitelist.contains(t.whitelist, zone, s.name) and not s.owned
    local wanted = s.npc and not s.dead and M.allowed(s, t, zone)
      and (is_white or not (t.skip_near_players and s.players_near))
    if not wanted then filtered = filtered + 1 end
    if wanted and not skip[s.id] then
      local d = flat({ s.x, s.y }, from)
      local dz = math.abs((s.z or 0) - (from[3] or 0))
      local reach = camp_style and h.leash or t.radius
      if is_white or whole_zone or (d <= reach and dz <= t.zradius) then
        s.from_distance = d
        s.whitelisted = is_white
        out[#out + 1] = s
      end
    end
  end
  table.sort(out, function(a, b)
    if a.whitelisted ~= b.whitelisted then return a.whitelisted == true end
    if t.priority == "named_first" and (a.named or false) ~= (b.named or false) then return a.named == true end
    if a.from_distance ~= b.from_distance then return a.from_distance < b.from_distance end
    return a.id < b.id
  end)
  return out, filtered
end

return M
