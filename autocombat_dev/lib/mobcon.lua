-- Standalone development copy of AutoCombat; original addon remains separate.
-- NPC faction consideration via Hailstone's OP_Consider packet, not chat text.
-- A server reply includes the target spawn ID and the faction tier, so it can
-- be attributed without changing the player's current target or parsing chat.
local M = {}

M.OPCODE = 0x742b -- RoF2 OP_Consider (Hailstone src/net/opcodes_rof2.inc)
M.SPECIAL_MESSAGE_OPCODE = 0x0083 -- RoF2 OP_SpecialMesg (one possible notice carrier)
M.CACHE_MS = 10 * 60 * 1000
M.MAX_ENTRIES = 128
M.REPLY_MS = 2000
M.NOTICE_MS = 6000 -- allow for Triune notices delayed after the consideration reply

M.TIERS = { "Scowling", "Threateningly", "Dubious", "Apprehensive", "Indifferent",
  "Amiably", "Kindly", "Warmly", "Ally" }

-- OP_Consider's faction field on the wire follows eqstr 12212..12220
-- (1=ally .. 6=scowls, 7=threateningly, 8=dubiously, 9=apprehensively).
-- EQEmu's FACTION_VALUE enum puts 6..9 the other way round and swaps them
-- just before sending (Client::Handle_OP_Consider), so every EQEmu server
-- sends this order. Never infer it from the UI tier list above.
local WIRE_TIERS = { "Ally", "Warmly", "Kindly", "Amiably", "Indifferent",
  "Scowling", "Threateningly", "Dubious", "Apprehensive" }

-- Triune sends these literal texts as separate chat/system packets as a
-- side effect of /consider. Their wire opcode and target field may vary;
-- do not require either when matching a known notice from our own request.
local CON_NOTICES = {
  ["Something about this creature's gaze tells you it cannot be swayed by enchantments!"] = true,
  ["This creature's will is unbreakable - mesmerizing magic would have no effect!"] = true,
  ["This being moves with supernatural grace that defies any attempt to hinder its speed!"] = true,
}

local function normal(name)
  return (name or ""):lower():gsub("_", " "):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.new() return { zone = nil, entries = {}, pending = nil, issued = {}, notice = nil } end

function M.set_zone(c, zone)
  if zone ~= c.zone then
    c.zone, c.entries, c.pending, c.issued, c.notice = zone, {}, nil, {}, nil
  end
end

-- NPC IDs are recycled. Match both the spawn ID and name, expire old results,
-- and keep the cache bounded so exploring a large zone cannot grow it forever.
function M.lookup(c, id, now, name)
  local entry = c.entries[id]
  if entry and now - entry.at >= 0 and now - entry.at < M.CACHE_MS
      and (not name or entry.name == normal(name)) then
    return entry.tier
  end
  c.entries[id] = nil
  return nil
end

local function store(c, id, name, tier, now)
  if not c.entries[id] then
    local count, oldest_id, oldest_at = 0, nil, math.huge
    for key, entry in pairs(c.entries) do
      if now - entry.at >= M.CACHE_MS then
        c.entries[key] = nil
      else
        count = count + 1
        if entry.at < oldest_at then oldest_id, oldest_at = key, entry.at end
      end
    end
    if count >= M.MAX_ENTRIES then c.entries[oldest_id] = nil end
  end
  c.entries[id] = { tier = tier, name = normal(name), at = now }
end

-- Request the server's faction for a specific NPC directly. No /target or
-- /consider command is needed. The 20-byte RoF2 request is five LE dwords:
-- player ID, target ID, faction=0, level=0, pvp_con+padding=0.
function M.request(c, id, name, now, player_id)
  for key, entry in pairs(c.issued) do
    if now - entry.at > M.REPLY_MS + 1000 then c.issued[key] = nil end
  end
  if type(id) ~= "number" or id <= 0 or type(player_id) ~= "number" or player_id <= 0 then return nil end
  c.pending = { id = id, name = name, player_id = player_id, at = now }
  c.issued[id] = { player_id = player_id, at = now }
  c.notice = { id = id, player_id = player_id, at = now }
  return string.pack("<I4I4I4I4I4", player_id, id, 0, 0, 0)
end

-- Called from hailstone.on_packet('zone', 'in', OP_Consider, fn). Only swallow
-- replies to OUR requests; manually issued /consider keeps its normal chat
-- output. Returns true to suppress the client's chat line for our packet.
function M.record_packet(c, opcode, data, now)
  if opcode ~= M.OPCODE or type(data) ~= "string" or #data < 20 then return false end
  local player_id, target_id, faction = string.unpack("<I4I4I4", data)
  local sent = c.issued[target_id]
  -- Some EQEmu derivatives zero the player field in the reply. The target
  -- spawn ID plus an outstanding recent request still identify OUR response.
  -- Do not accept an unrelated nonzero player ID.
  if not sent or (player_id ~= 0 and sent.player_id ~= player_id) then return false end
  local elapsed = now - sent.at
  if elapsed < 0 or elapsed > M.REPLY_MS + 1000 then
    c.issued[target_id] = nil
    return false
  end
  c.issued[target_id] = nil
  local p = c.pending
  if p and p.id == target_id and (player_id == 0 or p.player_id == player_id) then
    c.pending = nil
    if elapsed <= M.REPLY_MS then
      local tier = WIRE_TIERS[faction]
      if tier then store(c, target_id, p.name, tier, now) end
    end
  end
  return true
end

-- Packet-level notice suppression. The chat text may be carried by more than
-- OP_SpecialMesg, and that packet's target_spawn_id is not necessarily the
-- player or the considered mob (it may be a broadcast value). Match only a
-- complete, NUL-terminated known text in the raw incoming payload. This is
-- called from the opcode=0 packet hook; it never parses or rewrites other text.
-- A manual /consider made during an automatic consideration window remains
-- inherently indistinguishable from the resulting automatic notice.
function M.record_notice(c, opcode, data, now)
  if type(data) ~= "string" then return false end
  local notice = c.notice
  if not notice then return false end
  local elapsed = now - notice.at
  if elapsed < 0 or elapsed > M.NOTICE_MS then
    if elapsed > M.NOTICE_MS then c.notice = nil end
    return false
  end
  -- OP_Consider itself has a distinct binary layout, handled by record_packet.
  if opcode == M.OPCODE then return false end
  for text in pairs(CON_NOTICES) do
    -- In OP_SpecialMesg this is the final field; in channel or other packets
    -- the following byte is NUL. An arbitrary chat quote with extra words
    -- after the phrase must not be mistaken for the server's system notice.
    if data:find(text .. "\0", 1, true) or data:sub(-#text) == text then
      return true
    end
  end
  return false
end

function M.cancel(c, discard)
  -- Keep an in-flight reply marker briefly on normal cancellation. If sending
  -- the request itself failed, nothing was sent, so remove the marker too.
  if discard and c.pending then
    c.issued[c.pending.id] = nil
    c.notice = nil
  end
  c.pending = nil
end

-- All allowed is the compatibility default: there is no need to query mobs.
function M.none_enabled(filters)
  for _, tier in ipairs(M.TIERS) do
    if filters[tier] ~= false then return false end
  end
  return true
end

function M.restricted(filters)
  for _, tier in ipairs(M.TIERS) do
    if filters[tier] == false then return true end
  end
  return false
end

return M
