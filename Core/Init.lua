local ADDON, ns = ...

ns.ADDON = ADDON

-- Units. Every coordinate inside this addon is a map FRACTION (0..1), which is
-- what C_VignetteInfo.GetVignettePosition and C_Map.GetPlayerMapPosition hand
-- back. The only exception is Data/DropPoints.lua, which is written in percent
-- because that is how the source data and every player reads coordinates; its
-- loader converts once, and tests/spec_droppoints.lua pins that conversion.
ns.PCT = 0.01

ns.version = "0.1.0"

-- M:SS for a countdown, or "--" when there is nothing to count.
function ns.FormatClock(seconds)
    if type(seconds) ~= "number" then return "--" end
    local s = math.max(0, math.floor(seconds + 0.5))
    return string.format("%d:%02d", math.floor(s / 60), s % 60)
end
