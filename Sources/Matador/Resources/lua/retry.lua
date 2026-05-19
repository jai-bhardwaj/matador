-- Move a failed job back to the wait list atomically.
-- KEYS[1] = failed zset
-- KEYS[2] = wait list
-- KEYS[3] = job hash
-- ARGV[1] = job id
local removed = redis.call('ZREM', KEYS[1], ARGV[1])
if removed == 0 then return 0 end
redis.call('LPUSH', KEYS[2], ARGV[1])
redis.call('HDEL', KEYS[3], 'finishedOn', 'failedReason', 'stacktrace')
return 1
