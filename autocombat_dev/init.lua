-- Standalone development copy of AutoCombat; original addon remains separate.
-- Auto Combat for Hailstone: fights for you in one of three modes.
--   Manual  full:    run into a pack; it targets the mobs on you (the extended target list's auto haters), keeps in
--                    melee range, attacks, sends the pet, and fires your Spells and Abilities rows.
--           partial: you position yourself and pick the mob; it fires the rows on the NPC you target once it is on
--                    you or you attack it, and only turns to face it.
--   Hunter:          as Manual full, and when nothing is on you it rests, then finds a mob and walks to it
--                    (/nav), roaming the zone or pulling back to a camp, until paused.
--   Assist:          as Manual full, but it fights only what the assist (the group's main assist, or a name) is on,
--                    once its health is low enough, and follows the assist between fights.
-- The Spells and Abilities pages are ordered rows: the first row whose conditions hold and that is ready fires.
--
-- Two windows: a compact one (the mode, Start / Pause, what it is doing; it opens when the script starts) and the
-- settings (its gear button, or /autocombatdev settings).
--
-- Burn mode (the compact window's Burn, /autocombatdev burn): the rows marked "only during burn" fire only while it is
-- on; it ends by itself once the extended target list is clear after a fight, or when turned off.
--
-- The extended target window (the Modern pack's, through its lib/xtarget.lua) gets Force (fight this one first, until
-- it dies) and Ignore (leave it alone while anything else is on the list) on each mob.
--
-- /autocombatdev [show | settings | on | off | toggle | burn [on|off] | force | ignore |
--             mode manual|hunter|assist | style full|partial | camp | status]
-- Settings are kept per server and character in scripts/config/autocombatdev/. A server may turn modes off in its
-- hailstone.cfg: [autocombat] manual = off, hunter = off, assist = off.
local mq = require('mq')
local hs = require('hailstone')
local catalog = require('lib.catalog')
local settings_mod = require('lib.settings')
local profiles = require('lib.profiles')
local engine = require('lib.engine')
local world_mod = require('lib.world')
local rules = require('lib.rules')
local mobcon = require('lib.mobcon')
local whitelist = require('lib.whitelist')

local NAME = "autocombat_dev"
local TICK_MS = 100

local S = settings_mod.defaults()   -- the settings in use
local rev = 1                       -- bumped on every change, so the window knows to read them again
local dirty_at = nil                -- when an unsaved change was made
local loaded_for = nil              -- legacy per-character path, used as the profile identity
local active_settings_path = nil    -- path for the selected settings profile
local profile_manifest = profiles.repair(nil)
local open = true                   -- the compact window shows (from the start, so /lua run brings it up)
local settings_open = false         -- the settings window shows
local E = engine.new()
local held = false                  -- autoskill held
local row_status = { spells = {}, abilities = {}, items = {} }
local spell_cache = nil
local con_cache = mobcon.new() -- bounded, per-zone faction results from OP_Consider packets
local can_read_consider = false

local function say(text) hs.chat('[Auto Combat DEV] ' .. text, 15) end

-- ---------------------------------------------------------------- settings

local function clean(s) return (tostring(s or ""):gsub("[^%w_%-]", "_")) end

local function settings_path()
  local server = mq.TLO.EverQuest.Server() or ""
  local char = mq.TLO.Me.Name() or ""
  if server == "" or char == "" then return nil end
  return "autocombat_dev/" .. clean(server) .. "_" .. clean(char) .. ".lua"
end

local function read_table(path)
  local chunk = loadfile(path)
  if not chunk then return nil end
  local ok, data = pcall(chunk)
  if ok and type(data) == 'table' then return data end
  return nil
end

local function load_settings()
  local path = settings_path()
  if not path or path == loaded_for then return end
  loaded_for = path
  mobcon.set_zone(con_cache, nil) -- the same zone's spawn IDs may belong to another character
  E.consider = nil
  profile_manifest = profiles.repair(read_table(profiles.manifest_path(path)))
  active_settings_path = profiles.settings_path(path, profile_manifest.active)
  local data = read_table(active_settings_path)
  if not data and profile_manifest.active ~= 'default' then
    -- Missing or corrupt selected profile: recover the original settings, never overwrite them.
    profile_manifest.active = 'default'
    active_settings_path = path
    data = read_table(path)
  end
  S = settings_mod.repair(data)
  rev = rev + 1
  spell_cache = nil
end

local function changed()
  rev = rev + 1
  dirty_at = mq.gettime()
end

local function flush_settings()
  if not dirty_at then return true end
  if not active_settings_path then return false end
  local ok = pcall(mq.pickle, active_settings_path, S)
  if ok then dirty_at = nil end
  return ok
end

local function save_if_due()
  if dirty_at and mq.gettime() - dirty_at > 1500 then flush_settings() end
end

-- ---------------------------------------------------------------- the server's rules

local function allowed()
  local a = {}
  for _, m in ipairs(settings_mod.MODES) do
    local v = hs.server_rule("autocombat", m)
    a[m] = not (v and (v:lower() == "off" or v:lower() == "no" or v == "0"))
  end
  return a
end

-- ---------------------------------------------------------------- acting

local act = {
  cmd = function(line) mq.cmd(line) end,
  use = function(kind, name) return hs.use_ability(kind, name) end,
  delay = function(ms, fn) mq.delay(ms, fn) end,
  casting = function() return mq.TLO.Me.Casting() ~= nil end,
  say = say,
  consider = function(id, name)
    if not can_read_consider then return false end
    local player = hs.player()
    local data = mobcon.request(con_cache, id, name, mq.gettime(), player and player.spawn_id)
    if not data then return false end
    -- Send OP_Consider directly for this NPC. Do not change the visible target
    -- or print the server's response to the chat window.
    local ok = pcall(hs.send_packet, 'zone', mobcon.OPCODE, data)
    if not ok then mobcon.cancel(con_cache, true) end
    return ok
  end,
}

local function start()
  load_settings()
  local a = allowed()
  if a[S.mode] == false then
    say("this server does not allow " .. S.mode .. " mode.")
    return
  end
  engine.start(E, act)
  say("on (" .. S.mode .. (S.mode == "manual" and (", " .. S.style) or "") .. ").")
end

local function pause(why)
  if E.running then engine.pause(E, act, why) end
  mobcon.cancel(con_cache)
  if not why then say("paused.") end
end

-- Create a snapshot or switch profile. Switching always pauses and resets the combat engine.
-- The original character file is always the 'default' profile (no conversion needed).
local function profile_action(action, value)
  load_settings()
  if not loaded_for then say('log in to manage profiles.') return false end
  if action == 'list' then
    say('profiles: ' .. table.concat(profile_manifest.names, ', ') .. ' (active: ' .. profile_manifest.active .. ').')
    return true
  end
  local n = profiles.name(value)
  if not n then say('profile names must be 1-32 letters, numbers, dashes or underscores.') return false end
  if action == 'save' then
    local updated = profiles.add(profile_manifest, n)
    if not updated then say('profile already exists: ' .. n .. '.') return false end
    if not flush_settings() or not pcall(mq.pickle, active_settings_path, S) then
      say('could not save current settings; profile not created.') return false
    end
    -- Also materialize the default file for first-time users before creating a named profile.
    local path = profiles.settings_path(loaded_for, n)
    local ok = pcall(mq.pickle, path, S)
    if not ok then say('could not write profile: ' .. n .. '.') return false end
    if not pcall(mq.pickle, profiles.manifest_path(loaded_for), updated) then
      say('could not update the profile list; current profile unchanged.')
      return false
    end
    profile_manifest = updated
    rev = rev + 1
    say('saved a copy as ' .. n .. '; active profile is still ' .. profile_manifest.active .. '.')
    return true
  elseif action == 'load' then
    if not profiles.has(profile_manifest, n) then say('unknown profile: ' .. n .. '.') return false end
    if n == profile_manifest.active then say('already using ' .. n .. '.') return true end
    local path = profiles.settings_path(loaded_for, n)
    local data = read_table(path)
    if not data then say('profile file missing or invalid: ' .. n .. '.') return false end
    if not flush_settings() then say('could not save changes; switch cancelled.') return false end
    -- Stop before changing the rotation or hunting mode. Never auto-resume.
    if E.running then pause('switching profile') end
    local updated = profiles.activate(profile_manifest, n)
    if not pcall(mq.pickle, profiles.manifest_path(loaded_for), updated) then
      say('could not record selected profile; switch cancelled.')
      return false
    end
    profile_manifest = updated
    active_settings_path = path
    S = settings_mod.repair(data)
    E = engine.new() -- forget old combat targets, cooldown memory and Burn state
    spell_cache = nil
    row_status = { spells = {}, abilities = {}, items = {} }
    rev = rev + 1
    say('profile ' .. n .. ' loaded (paused).')
    return true
  end
  return false
end

-- ---------------------------------------------------------------- the extended target list and the marks

-- Each slot of the extended target list, in order ({ id = 0 } when empty), for the window's buttons; and the ids of
-- its auto haters.
local function xtargets()
  local out, haters = {}, {}
  local n = tonumber(hs.player() and hs.player().xtarget_slots) or 0
  for i = 1, n do
    local x = hs.xtarget(i)
    local id = x and x.spawn_id or 0
    out[i] = { id = id, name = x and x.name or "" }
    if id ~= 0 and x.type == 1 then haters[#haters + 1] = id end
  end
  return out, haters
end

local xt_list = {}

local function mark(kind, id, name)
  if not id or id == 0 then
    local t = mq.TLO.Target
    id, name = tonumber(t.ID()) or 0, t.CleanName()
    if id == 0 then return say("target a mob first.") end
  end
  if kind == "force" then engine.force(E, id, name, act) else engine.ignore(E, id, name, act) end
  say(E.last .. ".")
end

local function burn(on)
  if on == nil then on = not E.burn end
  engine.set_burn(E, on, act)
  say(E.burn and "burn on: the burn rows may fire until the extended target list is clear." or "burn off.")
end

local function set_camp()
  load_settings()
  S.hunter.camp = { x = mq.TLO.Me.X(), y = mq.TLO.Me.Y(), z = mq.TLO.Me.Z(), zone = mq.TLO.Zone.ShortName() or "" }
  S = settings_mod.repair(S)
  changed()
  say(string.format("camp set here (%.0f, %.0f).", S.hunter.camp.y, S.hunter.camp.x))
end

-- Rows from the Ability Book's autoskill list, added to the Abilities page (not twice).
local function import_autoskill()
  local have = {}
  for _, r in ipairs(S.abilities) do have[r.kind .. ":" .. r.name:lower()] = true end
  local added = 0
  for _, a in ipairs(hs.autoskill_list() or {}) do
    local kind = a.key:match("^(%a+):")
    kind = kind == "spell" and "disc" or kind
    if a.name ~= "" and (kind == "aa" or kind == "disc" or kind == "skill") and not have[kind .. ":" .. a.name:lower()] then
      local row = { name = a.name, kind = kind, target = "enemy", phase = "combat", conditions = {} }
      if a.when == "always" then row.phase = "always" elseif a.when == "resting" then row.phase = "rest" end
      if a.when ~= "fighting" then row.target = "self" end
      local c = row.conditions
      if a.endurance > 0 then c[#c + 1] = { who = "me", what = "endurance", op = ">=", value = a.endurance } end
      if a.mana > 0 then c[#c + 1] = { who = "me", what = "mana", op = ">=", value = a.mana } end
      if a.target_hp_below > 0 then c[#c + 1] = { who = "target", what = "hp", op = "<", value = a.target_hp_below } end
      if a.target_hp_above > 0 then c[#c + 1] = { who = "target", what = "hp", op = ">", value = a.target_hp_above } end
      if a.self_hp_below > 0 then c[#c + 1] = { who = "me", what = "hp", op = "<", value = a.self_hp_below } end
      S.abilities[#S.abilities + 1] = row
      have[kind .. ":" .. a.name:lower()] = true
      added = added + 1
    end
  end
  S = settings_mod.repair(S)
  changed()
  return added
end

-- A starting row for a spell (settings.row_for_spell): what the spell is decides its target, phase and conditions.
local function spell_row(sp, name)
  return settings_mod.row_for_spell({
    name = name,
    beneficial = sp.Beneficial() == true,
    target_type = sp.TargetType() or "",
    duration = tonumber(sp.Duration.TotalSeconds()) or 0,
    ae_range = tonumber(sp.AERange()) or 0,
  })
end

-- Rows for the memorized spells (the spell bar), added to the Spells page in gem order (not twice).
local function import_spellbar()
  load_settings()
  local have = {}
  for _, r in ipairs(S.spells) do have[r.name:lower()] = true end
  local added = 0
  local gems = tonumber(mq.TLO.Me.NumGems()) or 0
  for i = 1, gems do
    local g = mq.TLO.Me.Gem(i)
    local name = g.Name()
    if name and name ~= "" and not have[name:lower()] then
      local row = spell_row(g, name)
      if row then
        S.spells[#S.spells + 1] = row
        have[name:lower()] = true
        added = added + 1
      end
    end
  end
  S = settings_mod.repair(S)
  changed()
  return added
end

-- The spells to pick from: the memorized ones first, then the spell book's, by name.
local function spell_names(refresh)
  if spell_cache and not refresh then return spell_cache end
  local out, seen = {}, {}
  local gems = tonumber(mq.TLO.Me.NumGems()) or 0
  for i = 1, gems do
    local n = mq.TLO.Me.Gem(i).Name()
    if n and not seen[n] then out[#out + 1] = { name = n, gem = i } seen[n] = true end
  end
  local book = {}
  for i = 1, 720 do
    local n = mq.TLO.Me.Book(i).Name()
    if n and not seen[n] then book[#book + 1] = n seen[n] = true end
  end
  table.sort(book)
  for _, n in ipairs(book) do out[#out + 1] = { name = n, gem = 0 } end
  spell_cache = out
  return out
end

-- ---------------------------------------------------------------- the window's functions

hs.ui_function("state", function()
  return {
    open = open,
    settings_open = settings_open,
    running = E.running,
    burn = E.burn,
    xtargets = xt_list,
    force_id = E.force_id,
    ignored = (function() -- a list of ids: a table keyed by them would not cross to the window
      local out = {}
      for id in pairs(E.ignore) do out[#out + 1] = id end
      return out
    end)(),
    fight_id = E.running and E.fight_id or 0,
    mode = S.mode,
    profile = profile_manifest.active,
    style = S.style,
    status = E.running and E.status or "Paused",
    last = E.last,
    log = E.log,
    rev = rev,
    allowed = allowed(),
    rows = row_status,
    character = loaded_for ~= nil,
    zone = whitelist.zone(mq.TLO.Zone.ShortName()) or "",
    target_name = (function()
      local t = mq.TLO.Target
      if (tonumber(t.ID()) or 0) <= 0 or t.Type() ~= "NPC" then return nil end
      return t.CleanName() or t.Name()
    end)(),
  }
end)
hs.ui_function("settings", function() load_settings() return S end)
hs.ui_function("catalog", function() return catalog end)
hs.ui_function("profiles", function()
  load_settings()
  return { active = profile_manifest.active, names = profile_manifest.names }
end)
hs.ui_function("profile", function(action, name) return profile_action(action, name) end)
hs.ui_function("spells", function(refresh) return spell_names(refresh) end)
hs.ui_function("row_for_spell", function(name)
  if type(name) ~= "string" or name == "" then return nil end
  return spell_row(mq.TLO.Spell(name), name)
end)
-- The items carried with a click effect (world.clickies), for the Items page; a list of tables, each with the
-- click spell's id and name, cast time, recast and how long it still has to go.
hs.ui_function("clickies", function() return world_mod.clickies() end)
-- A starting Items row for a carried item, from its click spell (as Import spell bar's rows).
hs.ui_function("row_for_item", function(name)
  if type(name) ~= "string" or name == "" then return nil end
  for _, it in ipairs(world_mod.clickies()) do
    if it.name:lower() == name:lower() then
      return settings_mod.row_for_spell({ kind = "item", name = it.name, spell = it.spell, beneficial = it.beneficial,
        target_type = it.target_type, duration = it.duration, ae_range = it.ae_range })
    end
  end
  return settings_mod.row({ kind = "item", name = name })
end)
hs.ui_function("set", function(path, value)
  local ok
  S, ok = settings_mod.set(S, path, value)
  if ok then
    changed()
    if path == "mode" and E.running and allowed()[S.mode] == false then pause("this server does not allow " .. S.mode .. " mode") end
  end
  return ok
end)
hs.ui_function("set_rows", function(list, rows)
  if list ~= "spells" and list ~= "abilities" and list ~= "items" then return false end
  S[list] = rows or {}
  S = settings_mod.repair(S)
  changed()
  return true
end)
-- The whitelist is kept per zone and per character. Only NPC targets can
-- be added using the button; manual entries are validated by lib/whitelist.
hs.ui_function("whitelist", function(action, name)
  load_settings()
  if mq.TLO.EverQuest.GameState() ~= "INGAME" then return false end
  local zone = whitelist.zone(mq.TLO.Zone.ShortName())
  if not zone then return false end
  if action == "add_target" then
    local t = mq.TLO.Target
    if (tonumber(t.ID()) or 0) <= 0 or t.Type() ~= "NPC" then return false end
    name = t.CleanName() or t.Name()
    action = "add"
  end
  local modified = false
  if action == "add" then modified = whitelist.add(S.targeting.whitelist, zone, name)
  elseif action == "remove" then modified = whitelist.remove(S.targeting.whitelist, zone, name)
  end
  if modified then
    -- A new priority target should be considered on the next Hunter look.
    if E.hunt and not E.hunt.pulled then
      E.hunt = nil
      if E.nav == "mob" then act.cmd('/nav stop') E.nav = nil end
    end
    E.consider, E.last_look = nil, -1e9
    S = settings_mod.repair(S)
    changed()
  end
  return modified
end)
hs.ui_function("set_ignore", function(list)
  S.targeting.ignore = list or {}
  S = settings_mod.repair(S)
  changed()
  return true
end)
hs.ui_function("command", function(what, arg)
  if what == "start" then start()
  elseif what == "pause" then pause()
  elseif what == "toggle" then if E.running then pause() else start() end
  elseif what == "close" then open = false
  elseif what == "settings" then settings_open = not settings_open
  elseif what == "close_settings" then settings_open = false
  elseif what == "burn" then burn()
  elseif what == "force" or what == "ignore" then
    local id = tonumber(arg) or 0
    local name
    for _, x in ipairs(xt_list) do if x.id == id then name = x.name end end
    if id ~= 0 then mark(what, id, name) end
  elseif what == "target" then
    if (tonumber(arg) or 0) ~= 0 then mq.cmd('/target id ' .. math.floor(tonumber(arg))) end
  elseif what == "camp" then set_camp()
  elseif what == "profile" and type(arg) == "table" then return profile_action(arg.action, arg.name)
  elseif what == "clear_camp" then S.hunter.camp = nil changed()
  elseif what == "import_autoskill" then return import_autoskill()
  elseif what == "import_spellbar" then return import_spellbar()
  end
  return true
end)
hs.menu("Auto Combat DEV", "/autocombatdev show")

-- ---------------------------------------------------------------- the command

mq.bind('/autocombatdev', function(a, b, c)
  a = (a or ""):lower()
  if a == "" or a == "show" then open = not open
  elseif a == "settings" or a == "setup" then settings_open = not settings_open
  elseif a == "force" or a == "ignore" then mark(a)
  elseif a == "on" or a == "start" then start()
  elseif a == "off" or a == "pause" or a == "stop" then pause()
  elseif a == "toggle" then if E.running then pause() else start() end
  elseif a == "burn" then
    local v = (b or ""):lower()
    if v == "on" then burn(true) elseif v == "off" then burn(false) else burn() end
  elseif a == "camp" then set_camp()
  elseif a == "profile" then
    local action = (b or ''):lower()
    if action == 'list' then profile_action('list')
    elseif action == 'save' or action == 'load' then profile_action(action, c)
    else say('usage: /autocombatdev profile list|save <name>|load <name>') end
  elseif a == "mode" or a == "style" then
    local list = a == "mode" and settings_mod.MODES or settings_mod.STYLES
    local v = (b or ""):lower()
    local ok
    for _, m in ipairs(list) do ok = ok or m == v end
    if not ok then return say("usage: /autocombatdev " .. a .. " " .. table.concat(list, "|")) end
    load_settings()
    S = settings_mod.set(S, a, v)
    changed()
    if E.running and allowed()[S.mode] == false then pause("this server does not allow " .. S.mode .. " mode") end
    say(a .. " " .. v .. ".")
  elseif a == "status" then
    say((E.running and E.status or "paused") .. " (" .. S.mode .. (S.mode == "manual" and (", " .. S.style) or "")
      .. (E.burn and ", burning" or "") .. ")")
  else
    say("/autocombatdev [show | settings | on | off | toggle | burn [on|off] | force | ignore"
      .. " | mode manual|hunter|assist | style full|partial | camp | profile | status]")
  end
end)

-- Intercept our own OP_Consider replies and Triune's separate immunity
-- notices before the client converts them into chat. The latter may arrive
-- through several incoming chat opcodes, not just OP_SpecialMesg.
local consider_hook = pcall(hs.on_packet, 'zone', 'in', mobcon.OPCODE, function(opcode, data)
  return mobcon.record_packet(con_cache, opcode, data, mq.gettime())
end)
local notice_hook = pcall(hs.on_packet, 'zone', 'in', 0, function(opcode, data)
  if not con_cache.notice then return false end -- quick path for ordinary traffic
  return mobcon.record_notice(con_cache, opcode, data, mq.gettime())
end)
-- Do not initiate automatic considerations if we cannot suppress BOTH replies
-- and their associated notices; this avoids noisy, partly configured installs.
can_read_consider = consider_hook and notice_hook

-- ---------------------------------------------------------------- the loop

local last_status = -1e9
while true do
  load_settings()
  local want_hold = E.running and S.general.hold_autoskill
  if want_hold ~= held then
    hs.hold_autoskill(want_hold)
    held = want_hold
  end
  local list, hater_ids = xtargets()
  xt_list = list
  engine.update_marks(E, hater_ids, world_mod.alive, act)
  local w = E.running and world_mod.read(S, allowed(), function(id, zone, now, name)
    mobcon.set_zone(con_cache, zone)
    return mobcon.lookup(con_cache, id, now, name)
  end) or nil
  if w and w.in_game then mobcon.set_zone(con_cache, w.zone) end
  if E.burn and engine.burn_tick(E, w and #w.haters or world_mod.hater_count(), act) then
    say("burn over: the extended target list is clear.")
  end
  if w then
    w.burn = E.burn
    w.me.burning = E.burn
    local ok, err = pcall(engine.tick, E, w, S, act)
    if not ok then
      pause("stopped by an error: " .. tostring(err))
    elseif settings_open and w.in_game and mq.gettime() - last_status > 500 then
      -- Why each row would not fire now, for the window.
      last_status = mq.gettime()
      for _, list in ipairs(settings_mod.LISTS) do
        local out = {}
        for i, r in ipairs(S[list]) do out[i] = rules.blocker(list, i, r, w, E.memory) end
        row_status[list] = out
      end
    end
  end
  save_if_due()
  mq.delay(TICK_MS)
end
