local ADDON, ns = ...

-- The vignette ids a War Supply Crate shows as it goes from transport to loot.
--
-- Confirmed independently in three codebases -- RCT, WarCrateTracker and
-- CrateTrackerZK -- which is why they are trusted enough to filter on. But all
-- three shipped against interface 120100, so if Midnight 12.2 renumbered them
-- this file is the single place that breaks, and /ewc scan prints whatever the
-- game is really sending so the new numbers can be read straight off.
--
-- Filtering on the id and never on vignetteInfo.name: the name is localised,
-- so matching "War Supply Crate" works only on an English client.
-- WarCrateTracker has exactly that bug.
local STAGE = {
    [3689] = "flying",   -- the transport, still carrying the crate. MOVES --
                         -- this is the one that makes prediction possible
    [2967] = "falling",  -- released, under its parachute
    [6066] = "ground",   -- landed, lootable
    -- Both mean claimed and neither says by whom. The game draws only your own
    -- faction's claimed marker, so seeing either id means YOUR side took it,
    -- whichever one arrived -- and the marker never appearing is how you learn
    -- the other side did. WarCratePredict shipped a 6067=Alliance,
    -- 6068=Horde table from one player's sample and had it contradicted live:
    -- it announced "claimed by Horde" on a Horde character while an Alliance
    -- player was watched looting the crate. Read the faction from the player,
    -- never from the id.
    [6067] = "claimed",
    [6068] = "claimed",
}

ns.VIGNETTE_STAGE = STAGE

-- A different object entirely, and deliberately not in STAGE above: it is not
-- a crate and nothing that reasons about crates should mistake it for one.
--
-- Spectral Battle Chest. Dmitrii's account, from every time he has met one:
-- it simply appears on the ground -- no transport, no parachute -- its vignette
-- is visible from anywhere in Slayer's Rise rather than needing proximity, and
-- it stays about one to two minutes.
--
-- Each of those changes what tracking means. Nothing flies, so there is no
-- heading to fit and no release to time. Zone-wide visibility means one player
-- standing in the zone sees every spawn, so its cycle is measurable in an
-- evening without flying a route. One to two minutes is long enough to reach
-- if you are already there and too short to be worth telling anyone who is
-- not. So: notice it, say where, and count it down. Nothing more.
--
-- What is documented, and it is not much: object 527903, added in 12.0.1, and
-- it spawns every thirty minutes in Slayer's Rise for up to five players of
-- either faction to loot before it despawns. Whether that half hour runs from
-- the spawn or from the last loot is not said anywhere, nor is where in the
-- zone it appears, nor how long it stays -- the wiki page does not even have a
-- screenshot. So the thirty minutes is written here as the one figure with a
-- source and nothing is built on it; the record of untracked vignettes
-- measures the rest, which is the same way every interval in this addon was
-- arrived at.
--
-- Untracked by RCT, WarCrateTracker and CrateTrackerZK alike, so this id has
-- one source and /ewc scan is how it gets checked.
local SPECTRAL = {
    [6892] = true,   -- object 527903, documented at 30 minutes
}

ns.SPECTRAL = SPECTRAL

function ns.IsSpectral(vignetteID)
    return SPECTRAL[vignetteID] == true
end

function ns.VignetteStage(vignetteID)
    return STAGE[vignetteID]
end

-- Vignette art that is never a crate.
--
-- db.strangers exists to catch an object this addon does not yet know -- a
-- renumbered crate id, a chest on a cycle -- and it jammed instead: 30 of 30,
-- raised to 60, full again the same evening. Reading the 60 said why. They are
-- the contents of a Midnight zone: rares, vendors, lore objects, warfront
-- icons, quest objects. Six zones hold more of those than any cap worth
-- setting, so the store needed to stop collecting them rather than to hold
-- more.
--
-- Named from those samples instead of from a guess about what a crate looks
-- like, which is the opposite way round from how this was first attempted.
--
-- What is deliberately NOT here is the loot art. VignetteLootElite is what the
-- Spectral Battle Chest wears -- the object this store was built for -- and
-- VignetteLoot is its ordinary cousin. Refusing those to save eleven slots
-- would have thrown away the question.
--
-- And this only decides what is filed. /ewc scan prints every vignette drawn
-- in the zone whatever its art, so a crate id renumbered onto unfamiliar art
-- is still there to be read off the screen.
local SCENERY = {
    ["VignetteKill"] = true,         -- a rare, i.e. something you kill
    ["VignetteKillElite"] = true,
    ["Quartermaster"] = true,
    ["Class"] = true,                -- also a renown quartermaster
    ["AncientMana"] = true,          -- Glowing Moth and friends
    ["loreobject-32x32"] = true,
    ["housing-decor-vendor_32"] = true,
    ["dragon-rostrum"] = true,
    ["QuestObjective"] = true,
    ["AllianceSymbol"] = true,       -- a turn-in
    ["HordeSymbol"] = true,
    ["poi-prey"] = true,
    ["Ammunition"] = true,           -- Ethereal Tool Rack, nine at a time
    ["Vehicle-TempleofKotmogu-PurpleBall"] = true,  -- an area effect
}

-- Every warfront map icon, of which there are many and all of them are noise
-- here. Matched on the stem because the full names carry faction, map and size.
local SCENERY_STEM = "Warfront"

function ns.IsSceneryArt(atlasName)
    if type(atlasName) ~= "string" or atlasName == "" then return false end
    if SCENERY[atlasName] then return true end
    return atlasName:sub(1, #SCENERY_STEM) == SCENERY_STEM
end

-- Stages that mean the crate is down and its position is the real landing
-- spot, as opposed to somewhere it was merely passing over.
ns.LANDED_STAGE = {
    ground  = true,
    claimed = true,
}
