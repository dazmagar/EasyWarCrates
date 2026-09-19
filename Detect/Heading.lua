local ADDON, ns = ...

-- Heading of an in-flight transport, from its vignette positions over time.
--
-- Pure maths. No WoW API, no frames, no globals, so tests/ runs this file
-- under a plain Lua interpreter instead of guessing in a live raid.
--
-- Everything downstream hangs on how precise this number is. Simulated against
-- the 220 catalogued drop spots, picking the correct one the moment the
-- transport appears scores 90% at 0.5 degrees of heading error, 68% at 2
-- degrees and 35% at 8. Differencing two samples gives roughly
-- 2 * positionError / baseline -- about ten degrees over a one-second gap, so
-- that approach cannot work. Regressing x and y on time across the whole
-- window instead shrinks the error as 1/sqrt(n) and yields the speed the
-- landing ETA needs anyway.

local Heading = {}
ns.Heading = Heading

-- Only the recent past steers the fit: the transport flies straight to its
-- drop point and then circles, and stale circling samples would bend a fit
-- that is still being asked "where is it going".
local WINDOW_SECONDS = 20
local MIN_SAMPLES    = 5
-- A track that has not covered this much map has no direction worth reporting,
-- however many samples sit inside it.
local MIN_BASELINE   = 0.015
-- Two readings this close are the same reading. Keeping both would claim a
-- sample count the data does not support and flatter the error estimate.
local DEDUP          = 1e-6

local Track = {}
Track.__index = Track

function Heading.NewTrack(id)
    return setmetatable({ id = id, t = {}, x = {}, y = {}, head = 1, tail = 0 }, Track)
end

function Track:Count()
    return self.tail - self.head + 1
end

-- Drops samples that have aged out, never below MIN_SAMPLES: a transport that
-- goes quiet should keep the heading it had, not lose it.
function Track:Trim(now)
    local cutoff = now - WINDOW_SECONDS
    while self:Count() > MIN_SAMPLES and self.t[self.head] < cutoff do
        self.t[self.head], self.x[self.head], self.y[self.head] = nil, nil, nil
        self.head = self.head + 1
    end
end

-- Returns true when the sample added information. A rejected sample is not an
-- error; duplicates and out-of-order readings are normal.
function Track:Add(time, x, y)
    if type(time) ~= "number" or type(x) ~= "number" or type(y) ~= "number" then
        return false
    end

    local last = self.tail
    if last >= self.head then
        if time < self.t[last] then
            return false
        end
        local dx, dy = x - self.x[last], y - self.y[last]
        if (dx * dx + dy * dy) < DEDUP * DEDUP then
            -- Same place, later clock. Carry the timestamp so the window still
            -- ages, but do not pretend this is a second observation.
            self.t[last] = time
            self:Trim(time)
            return false
        end
    end

    local i = last + 1
    self.t[i], self.x[i], self.y[i] = time, x, y
    self.tail = i
    self:Trim(time)
    return true
end

-- nil until there is enough of a track to mean anything. Otherwise:
--   x, y      position at the newest sample, read off the fit rather than the
--             raw last reading, so one noisy point cannot swing the ray origin
--   hx, hy    unit heading
--   speed     map fractions per second
--   err       1-sigma heading error, radians -- the standard error of the
--             cross-track slope over speed. Predict sizes its tolerances off
--             this, so a noisy track demands more separation before it commits
--   rms       cross-track residual; large means the transport is turning
function Track:Fit()
    local n = self:Count()
    if n < MIN_SAMPLES then return nil end

    local h, tl = self.head, self.tail
    local st, sx, sy = 0, 0, 0
    for i = h, tl do
        st = st + self.t[i]; sx = sx + self.x[i]; sy = sy + self.y[i]
    end
    local mt, mx, my = st / n, sx / n, sy / n

    local stt, stx, sty = 0, 0, 0
    for i = h, tl do
        local dt = self.t[i] - mt
        stt = stt + dt * dt
        stx = stx + dt * (self.x[i] - mx)
        sty = sty + dt * (self.y[i] - my)
    end
    if stt <= 0 then return nil end

    local vx, vy = stx / stt, sty / stt
    local speed = math.sqrt(vx * vx + vy * vy)
    if speed <= 0 then return nil end
    local hx, hy = vx / speed, vy / speed

    local bx, by = self.x[tl] - self.x[h], self.y[tl] - self.y[h]
    local baseline = math.sqrt(bx * bx + by * by)
    if baseline < MIN_BASELINE then return nil end

    local sq = 0
    for i = h, tl do
        local dt = self.t[i] - mt
        local ex = (self.x[i] - mx) - vx * dt
        local ey = (self.y[i] - my) - vy * dt
        local cross = ex * -hy + ey * hx
        sq = sq + cross * cross
    end
    -- n-2: a straight-line fit spends two degrees of freedom.
    local sigma = math.sqrt(sq / math.max(1, n - 2))

    local dtl = self.t[tl] - mt
    return {
        x     = mx + vx * dtl,
        y     = my + vy * dtl,
        hx    = hx,
        hy    = hy,
        speed = speed,
        n     = n,
        span  = self.t[tl] - self.t[h],
        baseline = baseline,
        rms   = math.sqrt(sq / n),
        err   = sigma / math.sqrt(stt) / speed,
    }
end

Heading.WINDOW_SECONDS = WINDOW_SECONDS
Heading.MIN_SAMPLES    = MIN_SAMPLES
Heading.MIN_BASELINE   = MIN_BASELINE
