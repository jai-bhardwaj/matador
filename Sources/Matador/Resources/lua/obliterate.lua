-- Wipe an entire BullMQ queue: all state sets, all job hashes, all logs,
-- repeat scheduler keys, meta, id counter, events stream.
-- KEYS[1] = queue base, e.g. "bull:emails"
-- ARGV[1] = "1" to also delete active jobs (otherwise refuses if active > 0)
local base = KEYS[1]
local force = ARGV[1]
local activeKey = base .. ':active'
local activeLen = redis.call('LLEN', activeKey)
if force ~= "1" and activeLen > 0 then
    return -1
end

local states = {'wait', 'active', 'paused', 'prioritized'}
local zsets  = {'completed', 'failed', 'delayed', 'waiting-children'}

local function deleteJobs(ids)
    for i = 1, #ids do
        local id = ids[i]
        redis.call('DEL', base .. ':' .. id, base .. ':' .. id .. ':logs',
                          base .. ':' .. id .. ':dependencies',
                          base .. ':' .. id .. ':processed')
    end
end

for _, s in ipairs(states) do
    local k = base .. ':' .. s
    local ids = redis.call('LRANGE', k, 0, -1)
    deleteJobs(ids)
    redis.call('DEL', k)
end

for _, s in ipairs(zsets) do
    local k = base .. ':' .. s
    local ids = redis.call('ZRANGE', k, 0, -1)
    deleteJobs(ids)
    redis.call('DEL', k)
end

-- Repeat scheduler bookkeeping
local repeatIds = redis.call('ZRANGE', base .. ':repeat', 0, -1)
for i = 1, #repeatIds do
    redis.call('DEL', base .. ':repeat:' .. repeatIds[i])
end
redis.call('DEL', base .. ':repeat', base .. ':meta', base .. ':id',
                  base .. ':events', base .. ':stalled-check',
                  base .. ':delay', base .. ':limiter')
return 1
