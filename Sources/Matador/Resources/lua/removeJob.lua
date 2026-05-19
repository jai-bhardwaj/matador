-- Remove a job from any state set, plus its hash and logs.
-- Refuses to remove if the job is currently active and `force` is 0.
-- KEYS[1..N-2] = all candidate state keys (lists or zsets)
-- KEYS[N-1]   = job hash
-- KEYS[N]     = job logs list
-- ARGV[1]     = job id
-- ARGV[2]     = "1" if list, "0" if zset, alternating per KEY (string of length N-2)
-- ARGV[3]     = force flag ("1" to remove even from active)
-- ARGV[4]     = index (1-based) of the active key in KEYS, or "0" if none
local id = ARGV[1]
local kinds = ARGV[2]
local force = ARGV[3]
local activeIdx = tonumber(ARGV[4]) or 0
local n = #KEYS - 2

-- Safety: refuse to remove an active job unless forced.
if force ~= "1" and activeIdx > 0 then
    local present = redis.call('LPOS', KEYS[activeIdx], id)
    if present ~= false and present ~= nil then
        return -1
    end
end

for i = 1, n do
    local kind = string.sub(kinds, i, i)
    if kind == "1" then
        redis.call('LREM', KEYS[i], 0, id)
    else
        redis.call('ZREM', KEYS[i], id)
    end
end
redis.call('DEL', KEYS[#KEYS - 1], KEYS[#KEYS])
return 1
