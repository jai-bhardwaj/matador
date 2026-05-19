-- Bulk remove the oldest N ids from a state, plus their hashes + logs.
-- KEYS[1] = state key (list or zset)
-- KEYS[2] = queue base key, e.g. "bull:emails" — we append ":<id>" and ":<id>:logs"
-- ARGV[1] = "list" or "zset"
-- ARGV[2] = limit
-- Returns the count actually removed.
local kind = ARGV[1]
local limit = tonumber(ARGV[2])
local ids
if kind == "list" then
    ids = redis.call('LRANGE', KEYS[1], 0, limit - 1)
else
    ids = redis.call('ZRANGE', KEYS[1], 0, limit - 1)
end
if #ids == 0 then return 0 end

local base = KEYS[2]
for i = 1, #ids do
    local id = ids[i]
    if kind == "list" then
        redis.call('LREM', KEYS[1], 0, id)
    else
        redis.call('ZREM', KEYS[1], id)
    end
    redis.call('DEL', base .. ':' .. id, base .. ':' .. id .. ':logs')
end
return #ids
