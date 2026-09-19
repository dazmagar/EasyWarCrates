local ADDON, ns = ...

-- Which catalogued drop spot is the transport flying at?
--
-- Pure maths, same as Detect/Heading.lua: tests/ runs it outside the game.
--
-- Cast a ray from the transport along its measured heading and ask, of each
-- catalogued spot, how well it explains that ray. No launch point and no route
-- database: the transport enters a zone from varying map edges, which is
-- exactly what breaks an origin-based model (RCT fits one origin per zone and
-- eight of its twelve land mid-map as a result, which is what a least-squares
-- fit over several entry edges produces).
--
-- A spot is scored by how far it sits from the ray SIDEWAYS, measured in units
-- of what could plausibly put it there: the crate's landing scatter, plus the
-- bearing error over that range. Scoring this way rather than by bare angle is
-- what makes the verdict sharpen as the transport closes in. The angular
-- version did the opposite -- its tolerance was SCATTER/range, so it grew
-- without bound at short range -- and in Zul'Aman that produced a full minute
-- of silence on a call that was already correct, ending only when the
-- transport physically flew past the rival and knocked it out of the running.

local Predict = {}
ns.Predict = Predict

-- How far a crate lands from its catalogued spot, as a standard deviation in
-- map fractions. Wowhead's spawn records give a median radius of 0.12% and a
-- p90 of 0.61%; a Rayleigh fit to that p90 puts sigma near 0.3%. 0.4% is used
-- because the two fits disagree -- the tail is heavier than Rayleigh -- and
-- understating this makes every verdict overconfident.
local SCATTER = 0.004

-- Floor under the fit's own reported heading error, in radians. The regression
-- routinely reports 0.00 degrees because a transport flies a dead-straight
-- line, and taken at face value that would have the model trust the bearing
-- absolutely. It should not: the bearing is read over a 20-second window and
-- the transport can still turn. 0.004 rad is 0.23 degrees, which is the order
-- the committed calls actually miss by.
local ERR_FLOOR = 0.004

-- Sideways distance, in sigma, beyond which a spot cannot explain the ray.
local GATE = 3.0
-- Share of the posterior at which the call is firm.
local FIRM = 0.90
-- A spot this plausible relative to the leader is still in contention.
local CONTEND = 0.20
-- Contenders spread wider than this across the ray are not one line, so the
-- nearest of them is not on the way to the rest and picking it is a guess.
local CORRIDOR = 0.04

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
local ARRIVAL = 0.05

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
    table.sort(out, function(a, b)
        if a.tan == b.tan then return a.along < b.along end
        return a.tan < b.tan
    end)
    return out
end
Predict.Candidates = candidates

-- spots: from ns.GetDropPoints(mapID). fit: from a Heading track.
-- Always returns a table. Read .ok and .leading before acting.
--
--   best        highest posterior
--   aim         the spot to actually fly to, and the one to pin
--   p           posterior of best, 0..1
--   contenders  spots not ruled out, nearest first
--   ok          the call is firm
--   leading     aim is worth acting on now, though it may still change
--   reason      why not firm: off-ray | ambiguous | spread
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

    local err = fit.err or 0
    if err < ERR_FLOOR then err = ERR_FLOOR end

    -- Sideways offset in sigma, and the likelihood that follows from it.
    local total = 0
    for i = 1, #ranked do
        local c = ranked[i]
        local sigma = math.sqrt(SCATTER * SCATTER + (c.along * err) ^ 2)
        c.z = c.perp / sigma
        c.like = math.exp(-0.5 * c.z * c.z)
        total = total + c.like
    end
    for i = 1, #ranked do ranked[i].p = ranked[i].like / total end

    table.sort(ranked, function(a, b)
        if a.like == b.like then return a.along < b.along end
        return a.like > b.like
    end)

    local best, second = ranked[1], ranked[2]
    local result = {
        best   = best,
        second = second,
        ranked = ranked,
        p      = best.p,
        angle  = math.atan(best.tan),
    }

    -- Arrival, tested before anything else and by distance alone. The
    -- transport is on top of this spot; that is the answer regardless of what
    -- else shares its bearing further out.
    if best.along <= ARRIVAL and best.perp <= SCATTER * GATE then
        result.aim, result.ok, result.leading, result.arriving = best, true, true, true
        return result
    end

    if best.z > GATE then
        result.reason = "off-ray"
        return result
    end

    -- Everything still in the running, in the order the transport reaches it.
    local contenders, spread = {}, 0
    for i = 1, #ranked do
        local c = ranked[i]
        if c.like >= CONTEND * best.like then
            contenders[#contenders + 1] = c
            if c.perp > spread then spread = c.perp end
        end
    end
    table.sort(contenders, function(a, b) return a.along < b.along end)
    result.contenders, result.spread = contenders, spread

    -- Fly to the nearest contender, not the highest-scoring one. When several
    -- spots sit on one line the transport passes them in order, so the near
    -- one is on the way to the far one and going there costs nothing if it
    -- turns out to be wrong. Two Zul'Aman spots 7% apart lie so exactly on the
    -- same line that their perpendicular offsets differ by 0.001% of the map;
    -- no bearing will ever separate them, and answering "the near one, and if
    -- not, straight on" is worth far more than answering nothing.
    result.aim = contenders[1]

    if best.p >= FIRM then
        result.ok, result.leading = true, true
        return result
    end
    if spread > CORRIDOR then
        -- A fan, not a line. The nearest is not on the way to the rest.
        result.reason = "spread"
        return result
    end
    result.leading, result.reason = true, "ambiguous"
    return result
end

-- How near a hovering transport must sit to a catalogued spot to be called as
-- that spot. Generous next to the 0.4% landing scatter, because this is the
-- transport's own circling radius, not the crate's.
local HOVER_SNAP = 0.03

-- A transport with no baseline has reached its drop point and is circling it.
-- Which spot that is needs no ray and no bearing -- it is the one underneath.
function Predict.Hovering(spots, x, y)
    if type(spots) ~= "table" or #spots == 0 then
        return { ok = false, reason = "no-catalogue" }
    end
    local best, dist
    for i = 1, #spots do
        local dx, dy = spots[i].x - x, spots[i].y - y
        local d = math.sqrt(dx * dx + dy * dy)
        if not dist or d < dist then best, dist = spots[i], d end
    end
    if dist > HOVER_SNAP then
        return { ok = false, reason = "nowhere-known", spot = best, distance = dist }
    end
    return { ok = true, spot = best, distance = dist }
end
Predict.HOVER_SNAP = HOVER_SNAP

Predict.SCATTER   = SCATTER
Predict.ERR_FLOOR = ERR_FLOOR
Predict.GATE      = GATE
Predict.FIRM      = FIRM
Predict.CONTEND   = CONTEND
Predict.CORRIDOR  = CORRIDOR
Predict.ARRIVAL   = ARRIVAL
