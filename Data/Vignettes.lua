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
-- Untracked by RCT, WarCrateTracker and CrateTrackerZK alike, so this id has
-- one source and /ewc scan is how it gets checked.
local SPECTRAL = {
    [6892] = true,
}

ns.SPECTRAL = SPECTRAL

function ns.IsSpectral(vignetteID)
    return SPECTRAL[vignetteID] == true
end

function ns.VignetteStage(vignetteID)
    return STAGE[vignetteID]
end

-- Stages that mean the crate is down and its position is the real landing
-- spot, as opposed to somewhere it was merely passing over.
ns.LANDED_STAGE = {
    ground  = true,
    claimed = true,
}
