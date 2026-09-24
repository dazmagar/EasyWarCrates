local ADDON, ns = ...

ns.ADDON = ADDON

-- Units. Every coordinate inside this addon is a map FRACTION (0..1), which is
-- what C_VignetteInfo.GetVignettePosition and C_Map.GetPlayerMapPosition hand
-- back. The only exception is Data/DropPoints.lua, which is written in percent
-- because that is how the source data and every player reads coordinates; its
-- loader converts once, and tests/spec_droppoints.lua pins that conversion.
ns.PCT = 0.01

ns.version = "0.1.0"

-- M:SS for a countdown, or "--" when there is nothing to count. Padded to a
-- fixed width so columns of these line up -- 1:55 and 14:55 otherwise shunt
-- everything after them sideways.
function ns.FormatClock(seconds)
    if type(seconds) ~= "number" then return "   --" end
    local s = math.max(0, math.floor(seconds + 0.5))
    return string.format("%2d:%02d", math.floor(s / 60), s % 60)
end

-- The densest run of numbers that agree, as first and last index into a sorted
-- list, plus how many. nil when nothing agrees with anything.
--
-- Shared because the same shape of data turns up everywhere here: a pile of
-- readings with a tight core and one-sided contamination at the edges. A mean
-- is dragged by the tail, and min-to-max is dominated by it and grows wider
-- the more readings arrive. The core is the measurement; the rest is what the
-- game did to it.
--
-- Zul'Aman's cycle gaps read 1091 to 1098 seven times and 1061 once. Eversong
-- reads 1087 to 1095 ten times, then 1137, 1151 and 1183.
function ns.DensestRun(sorted, window)
    local bestFrom, bestTo, bestN
    local from = 1
    for to = 1, #sorted do
        while sorted[to] - sorted[from] > window do from = from + 1 end
        local n = to - from + 1
        if not bestN or n > bestN then bestFrom, bestTo, bestN = from, to, n end
    end
    if not bestN then return nil end
    return bestFrom, bestTo, bestN
end

function ns.MedianOf(sorted, from, to)
    local n = to - from + 1
    if n % 2 == 1 then return sorted[from + (n - 1) / 2] end
    return (sorted[from + n / 2 - 1] + sorted[from + n / 2]) / 2
end
