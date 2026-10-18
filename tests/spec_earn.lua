local ns, t = ...
local Earn = ns.Earn

local T0 = 1000000

-- What the rotation is paying, per hour, from the totals the game reports.
--
-- Measured rather than counted per crate: a crate is worth what it is worth,
-- and the question somebody farming asks is whether the hour was worth the
-- flying. Earnings only ever go up here -- a currency total can fall, because
-- the player bought something with it, and that is not a negative wage.
local function run(state, pairs_)
    for _, s in ipairs(pairs_) do
        Earn.Note(state, T0 + s[1], s[2], s[3])
    end
    return state
end

-- The caller samples on a ticker, not only when a total changes, so a quiet
-- stretch still produces samples. Anything sparser than SESSION_GAP reads as
-- the player having been away, which is the rule the gap test covers -- so a
-- fixture that means "half an hour of play" has to tick like one.
local function tick(state, from, to, step, honor, conquest, perStep)
    for at = from, to, step do
        Earn.Note(state, T0 + at, honor, conquest)
        honor = honor + (perStep and perStep[1] or 0)
        conquest = conquest + (perStep and perStep[2] or 0)
    end
    return state
end

t.test("half an hour of earning reads as twice that an hour", function()
    -- 50 honor and 50/3 conquest every five minutes: 300 and 100 in the half hour.
    local e = Earn.New()
    local honor, conquest = 1000, 500
    for at = 0, 1800, 300 do
        Earn.Note(e, T0 + at, honor, conquest)
        honor, conquest = honor + 50, conquest + 50 / 3
    end
    local perHour, conq, span = Earn.Rate(e, T0 + 1800)
    t.eq(span, 1800)
    t.eq(perHour, 600)
    t.eq(conq, 200)
end)

-- Ten minutes is the shortest span this will divide by. Two crates inside
-- three minutes would otherwise read as four thousand an hour, which is not a
-- rate, it is one lucky sample with an hour's worth of confidence on it.
t.test("too short a span has no rate, and says how long it has", function()
    local e = run(Earn.New(), { { 0, 1000, 500 }, { 120, 1300, 600 } })
    local honor, conquest, span = Earn.Rate(e, T0 + 120)
    t.eq(honor, nil)
    t.eq(conquest, nil)
    t.eq(span, 120, "so the window can say it is still learning")
end)

t.test("one sample is not a measurement", function()
    local e = run(Earn.New(), { { 0, 1000, 500 } })
    t.eq(Earn.Rate(e, T0), nil)
    t.eq(select(3, Earn.Rate(e, T0)), 0)
end)

-- Buying a piece of gear takes 1750 conquest out of the total in one tick.
t.test("spending is not a negative wage", function()
    local e = run(Earn.New(), {
        { 0, 1000, 2000 }, { 900, 1150, 2100 }, { 901, 1150, 350 }, { 1800, 1300, 450 },
    })
    local honor, conquest = Earn.Rate(e, T0 + 1800)
    t.eq(honor, 600)
    t.eq(conquest, 400, "200 earned in half an hour, and 1750 spent counts for nothing")
end)

-- Away from the keyboard for twenty minutes and the hour before it describes
-- somebody else's evening.
t.test("a long gap starts the measurement over", function()
    local e = run(Earn.New(), { { 0, 1000, 500 }, { 600, 1600, 700 } })
    t.eq(Earn.Rate(e, T0 + 600), 3600, "earning hard")
    run(e, { { 2400, 1600, 700 }, { 3300, 1750, 750 } })
    local honor, _, span = Earn.Rate(e, T0 + 3300)
    t.eq(span, 900, "the gap is not part of the hour")
    t.eq(honor, 600)
end)

t.test("an hour is as far back as it looks", function()
    local e = Earn.New()
    -- An hour of nothing, then ten minutes of earning.
    Earn.Note(e, T0, 1000, 500)
    for i = 1, 12 do Earn.Note(e, T0 + i * 300, 1000, 500) end
    Earn.Note(e, T0 + 4200, 1100, 500)
    local honor, _, span = Earn.Rate(e, T0 + 4200)
    t.ok(span <= Earn.WINDOW, ("span %s is inside the window"):format(tostring(span)))
    t.ok(honor > 0, "and the recent earning is in it")
end)

t.test("a reset forgets the session without forgetting the totals", function()
    local e = tick(Earn.New(), 0, 1800, 300, 1000, 500, { 50, 0 })
    t.ok(Earn.Rate(e, T0 + 1800), "earning before the reset")
    Earn.Reset(e, T0 + 1800)
    t.eq(Earn.Rate(e, T0 + 1800), nil, "nothing measured yet")

    -- 1300 honor is now the baseline, not 1300 earned.
    local honor = 1300
    for at = 2100, 3600, 300 do
        Earn.Note(e, T0 + at, honor, 600)
        honor = honor + 50
    end
    -- 250 honor across the half hour since the reset, and the quiet five
    -- minutes right after it are part of that half hour. A reset that started
    -- the clock at the next earning instead would flatter every rate after it.
    local perHour, _, span = Earn.Rate(e, T0 + 3600)
    t.eq(span, 1800, "measured from the reset, not from the next coin")
    t.eq(perHour, 500, "and what came after the reset is counted from there")
end)

-- The totals come out of C_CurrencyInfo, which answers nil while the client is
-- still loading. A nil is not a total of zero, and reading it as one would
-- invent a thousand honor the moment the real figure arrived.
t.test("a total the game would not give is not a total of nothing", function()
    local e = Earn.New()
    Earn.Note(e, T0, nil, nil)
    Earn.Note(e, T0 + 600, 1000, 500)
    Earn.Note(e, T0 + 1200, 1100, 550)
    local honor, conquest = Earn.Rate(e, T0 + 1200)
    t.eq(honor, 600)
    t.eq(conquest, 300)
end)

t.test("the session total is there to be shown beside the rate", function()
    local e = tick(Earn.New(), 0, 1800, 300, 1000, 500, { 50, 20 })
    local got = Earn.Session(e)
    t.eq(got.honor, 300)
    t.eq(got.conquest, 120)
    t.eq(got.span, 1800)
end)

-- The bank is not readable until the player exists. C_CurrencyInfo answers a
-- quantity of 0 for both currencies before then, and a zero taken as the
-- baseline makes the whole bank arrive as a rise in the next sample: measured,
-- 76000 honor an hour on a character that earned nothing at all.
--
-- The only player for whom both really are zero has never earned either, and
-- the price they pay for this is the first sample of their first honor.
t.test("a bank of nothing at all is a client that is not ready yet", function()
    local e = Earn.New()
    Earn.Note(e, T0, 0, 0)
    Earn.Note(e, T0 + 60, 14000, 2200)
    for at = 120, 660, 60 do Earn.Note(e, T0 + at, 14000, 2200) end
    local honor, conquest, span = Earn.Rate(e, T0 + 660)
    t.eq(span, 600, "measured from the first reading worth believing")
    t.eq(honor, 0, "the bank is not an hour's earnings")
    t.eq(conquest, 0)
end)

-- Zero in one of them is an ordinary total: plenty of people hold no conquest
-- at the start of a week and are earning honor hand over fist.
t.test("one empty currency is still a reading", function()
    local e = Earn.New()
    Earn.Note(e, T0, 500, 0)
    Earn.Note(e, T0 + 600, 1100, 0)
    t.eq(Earn.Rate(e, T0 + 600), 3600)
end)
