local ADDON, ns = ...

-- Which catalogued drop spot is the transport flying at?
--
-- Pure maths, same as Detect/Heading.lua: tests/ runs it outside the game.
--
-- Cast a ray from the transport along its measured heading and rank the zone's
-- catalogued spots by how far off that ray they sit. No launch point and no
-- route database: the transport enters a zone from varying map edges, which is
-- exactly what breaks an origin-based model (RCT fits one origin per zone and
-- eight of its twelve land mid-map as a result, which is what a least-squares
-- fit over several entry edges produces).
--
-- Ranking is by ANGLE off the ray, never by plain perpendicular distance. A
-- spot sitting 1% of the map off the ray means something very different 5%
-- ahead than 40% ahead, and the verdict must not drift with how far along the
-- flight we happen to be. Angles are compared as tangents (perp/along, with
-- along > 0), which is monotonic in the angle and avoids atan2 -- that call is
-- spelled differently in WoW's Lua 5.1 and in the 5.4+ used by the tests.

local Predict = {}
ns.Predict = Predict

-- A crate lands this far from its catalogued spot in the worst case. Measured
-- over Wowhead's spawn records: median radius 0.12% of the map, p90 0.61%,
-- max 0.86%. The acceptance cone has to contain it, and since it is a distance
-- rather than an angle it opens the cone wider the closer the target is.
local SCATTER = 0.010
-- How many sigma of the fit's own heading error to tolerate. The fit reports
-- err honestly, so this is the only knob that says how brave to be.
local ERR_SIGMA = 2.5
-- Once the transport is this close to a spot and sitting on the ray, it has
-- arrived: that spot is the answer by proximity, and no bearing test applies.
--
-- This was a candidate FILTER and that was a real bug, caught on a live flight
-- in Zul'Aman. Discarding anything nearer than this dropped the transport's
-- actual target out of the running exactly as it reached it. The true spot had
-- ranked first for a solid minute; the moment it fell inside the filter the
-- next spot along the same bearing inherited first place, lost its rival, and
-- the addon committed confidently to a point 7.2% of the map from where the
-- crate landed. A prediction that gets worse as it gets closer is worse than
-- no prediction.
--
-- It is also where the angular test stops meaning anything: the cone below is
-- SCATTER/along, which blows up as along goes to zero, so at close range
-- everything is "within cone" and no margin is ever enough.
local ARRIVAL = 0.05
-- Required separation between the best and second spot, as a multiple of the
-- uncertainty at that range. Roughly one in six geometries puts two spots on
-- the same line from a given entry edge, and no amount of flying separates
-- those: this is what makes the addon stay quiet instead of guessing.
local MARGIN = 1.0

local function candidates(spots, px, py, hx, hy)
    local out = {}
    for i = 1, #spots do
        local s = spots[i]
        local dx, dy = s.x - px, s.y - py
        local along = dx * hx + dy * hy
        if along > 0 then
            local perp = dx * -hy + dy * hx
            if perp < 0 then perp = -perp end
            out[#out + 1] = { spot = s, along = along, perp = perp, tan = perp / along }
        end
    end
    -- Angle decides. On a tie the nearer spot wins: two spots exactly on the
    -- bearing are indistinguishable by angle, and the transport reaches the
    -- near one first. Without this the order of equals is whatever table.sort
    -- happens to do, which is not something a waypoint should rest on.
    table.sort(out, function(a, b)
        if a.tan == b.tan then return a.along < b.along end
        return a.tan < b.tan
    end)
    return out
end
Predict.Candidates = candidates

-- spots: from ns.GetDropPoints(mapID). fit: from a Heading track.
-- Always returns a table. Read .ok before acting; .reason says why not.
function Predict.Evaluate(spots, fit)
    if type(spots) ~= "table" or #spots == 0 then
        return { ok = false, reason = "no-catalogue" }
    end
    if type(fit) ~= "table" or not fit.hx then
        return { ok = false, reason = "no-fit" }
    end

    local ranked = candidates(spots, fit.x, fit.y, fit.hx, fit.hy)
    if #ranked == 0 then
        return { ok = false, reason = "nothing-ahead" }
    end

    local best, second = ranked[1], ranked[2]
    -- Uncertainty in the same tangent units the ranking uses: the landing
    -- scatter seen from this range, plus the fit's own heading error.
    local cone = SCATTER / best.along + ERR_SIGMA * (fit.err or 0)

    local result = {
        best    = best,
        second  = second,
        ranked  = ranked,
        cone    = cone,
        margin  = second and (second.tan - best.tan) or math.huge,
        angle   = math.atan(best.tan),
    }

    -- Arrival, tested before anything angular and by distance alone. The
    -- transport is on top of this spot; that is the answer regardless of what
    -- else shares its bearing further out.
    if best.along <= ARRIVAL and best.perp <= SCATTER then
        result.ok, result.arriving = true, true
        return result
    end

    if best.tan > cone then
        result.ok, result.reason = false, "off-ray"
        return result
    end
    if second and result.margin < MARGIN * cone then
        result.ok, result.reason = false, "ambiguous"
        return result
    end

    result.ok = true
    return result
end

Predict.SCATTER   = SCATTER
Predict.ERR_SIGMA = ERR_SIGMA
Predict.ARRIVAL   = ARRIVAL
Predict.MARGIN    = MARGIN
