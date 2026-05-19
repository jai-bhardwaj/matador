-- Move a delayed job to the wait list immediately.
-- KEYS[1] = delayed zset
-- KEYS[2] = wait list
-- KEYS[3] = job hash
-- ARGV[1] = job id
local removed = redis.call('ZREM', KEYS[1], ARGV[1])
if removed == 0 then return 0 end
redis.call('LPUSH', KEYS[2], ARGV[1])
redis.call('HDEL', KEYS[3], 'delay')
return 1
