-- Minimal test registry. Specs get this as their second vararg.
local T = { cases = {}, failures = {}, passed = 0 }

function T.test(name, fn)
    T.cases[#T.cases + 1] = { name = name, fn = fn }
end

local function fail(msg)
    error({ __testfail = true, msg = msg }, 2)
end
T.fail = fail

function T.ok(v, msg)
    if not v then fail(msg or "expected truthy, got " .. tostring(v)) end
end

function T.notOk(v, msg)
    if v then fail(msg or "expected falsy, got " .. tostring(v)) end
end

function T.eq(a, b, msg)
    if a ~= b then
        fail((msg and msg .. ": " or "") .. "expected " .. tostring(b) .. ", got " .. tostring(a))
    end
end

function T.near(a, b, tol, msg)
    tol = tol or 1e-9
    if type(a) ~= "number" then fail((msg and msg .. ": " or "") .. "not a number: " .. tostring(a)) end
    local d = a - b
    if d < 0 then d = -d end
    if d > tol then
        fail(string.format("%sexpected %g +/- %g, got %g (off by %g)",
            msg and (msg .. ": ") or "", b, tol, a, d))
    end
end

function T.lt(a, b, msg)
    if not (a < b) then
        fail((msg and msg .. ": " or "") .. "expected " .. tostring(a) .. " < " .. tostring(b))
    end
end

-- Deterministic PRNG so a noisy-input test means the same thing on every run
-- and on every Lua version. math.randomseed is not portable across 5.1 / 5.4.
function T.rng(seed)
    local s = seed or 1
    return function()
        s = (1103515245 * s + 12345) % 2147483648
        return s / 2147483648
    end
end

-- Box-Muller on top of the above, for gaussian position noise.
function T.gauss(rand)
    return function(sd)
        local u1, u2 = rand(), rand()
        if u1 < 1e-12 then u1 = 1e-12 end
        return math.sqrt(-2 * math.log(u1)) * math.cos(6.283185307179586 * u2) * (sd or 1)
    end
end

function T.run()
    for _, c in ipairs(T.cases) do
        local ok, err = pcall(c.fn)
        if ok then
            T.passed = T.passed + 1
        else
            local msg = type(err) == "table" and err.msg or tostring(err)
            T.failures[#T.failures + 1] = { name = c.name, msg = msg }
        end
    end
    return T.passed, #T.failures
end

return T
