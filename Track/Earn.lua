local ADDON, ns = ...

-- What the rotation is paying, per hour.
--
-- Conquest is why anybody flies to a crate, so the question worth answering is
-- not how much one crate gave but whether the hour was worth the flying. Taken
-- from the totals the game reports rather than from a table of what a crate is
-- worth: the reward changes with the patch, and a measured figure does not.
--
-- Session only. It never reaches disk -- an hourly rate from yesterday
-- describes an evening that is over -- and nothing here needs saving to be
-- true tomorrow.
--
-- Pure table maths, so tests/ drives it.

local Earn = {}
ns.Earn = Earn

-- As far back as a rate looks.
local WINDOW = 3600
-- The shortest span worth dividing by. Two crates inside three minutes would
-- read as four thousand an hour, which is not a rate but one lucky sample
-- wearing an hour's confidence.
local MIN_SPAN = 600
-- Longer than this between samples and the player was not playing. An hour
-- that contains a twenty-minute absence is not an hour of farming.
--
-- Which puts one requirement on the caller: sample on a ticker and not only
-- when a total changes. A quiet half hour of flying about earning nothing is
-- still half an hour of farming, and with nothing sampled in it, it would read
-- as an absence and throw the measurement away.
local SESSION_GAP = 900

Earn.WINDOW, Earn.MIN_SPAN, Earn.SESSION_GAP = WINDOW, MIN_SPAN, SESSION_GAP

function Earn.New()
    return { samples = {}, honor = 0, conquest = 0 }
end

-- honor and conquest are the player's current totals, as the game gives them.
--
-- Only rises count. A total falls when the player spends it, and a conquest
-- purchase taking 1750 out of the bank in one tick is not a negative wage.
function Earn.Note(state, now, honor, conquest)
    if type(state) ~= "table" then return nil end
    now = tonumber(now)
    honor, conquest = tonumber(honor), tonumber(conquest)
    -- C_CurrencyInfo answers nil while the client is still loading, and nil is
    -- not a total of zero: read as one, the real figure arriving a minute later
    -- would look like a thousand honor earned in a minute.
    if not now or not honor or not conquest then return nil end
    -- Both of them reading zero is a client that has not loaded the player
    -- yet, not a player with nothing. Taken as the baseline, the whole bank
    -- arrives as a rise in the next sample: 76000 honor an hour, measured, on
    -- a character that earned nothing at all. The only player for whom both
    -- really are zero has never earned either, and pays one sample for this.
    if honor == 0 and conquest == 0 then return nil end

    local samples = state.samples
    local last = samples[#samples]
    if last then
        if (now - last.at) > SESSION_GAP then
            -- Away. What came before describes a different sitting, so the
            -- totals carry over and the measurement starts here.
            state.samples, samples = {}, nil
            samples = state.samples
            last = nil
        else
            state.honor = state.honor + math.max(0, honor - state.lastHonor)
            state.conquest = state.conquest + math.max(0, conquest - state.lastConquest)
        end
    end
    state.lastHonor, state.lastConquest = honor, conquest

    samples[#samples + 1] = { at = now, honor = state.honor, conquest = state.conquest }
    while #samples > 1 and (now - samples[1].at) > WINDOW do table.remove(samples, 1) end
    return samples[#samples]
end

-- honorPerHour, conquestPerHour, span -- or nil, nil, span while the span is
-- too short to divide by, which is what the window shows as "learning".
function Earn.Rate(state, now)
    local samples = state and state.samples
    if not samples or #samples < 2 then return nil, nil, 0 end
    local first, last = samples[1], samples[#samples]
    local span = last.at - first.at
    if span < MIN_SPAN then return nil, nil, span end
    return math.floor((last.honor - first.honor) / span * 3600 + 0.5),
        math.floor((last.conquest - first.conquest) / span * 3600 + 0.5),
        span
end

-- Everything earned since the measurement began, for the line beside the rate.
function Earn.Session(state)
    local samples = state and state.samples
    if not samples or #samples == 0 then return { honor = 0, conquest = 0, span = 0 } end
    local first, last = samples[1], samples[#samples]
    return {
        honor = last.honor - first.honor,
        conquest = last.conquest - first.conquest,
        span = last.at - first.at,
    }
end

function Earn.Reset(state, now)
    if type(state) ~= "table" then return end
    state.samples = {}
    if state.lastHonor and tonumber(now) then
        -- The totals are kept: they are what the next rise is measured
        -- against, and forgetting them would count the whole bank as earned.
        state.samples[1] = { at = tonumber(now), honor = state.honor, conquest = state.conquest }
    end
end
