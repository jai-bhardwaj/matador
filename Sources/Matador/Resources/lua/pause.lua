-- Set/clear the BullMQ pause flag on a queue.
-- KEYS[1] = meta hash
-- ARGV[1] = "1" to pause, "0" to resume
if ARGV[1] == "1" then
    return redis.call('HSET', KEYS[1], 'paused', '1')
else
    return redis.call('HDEL', KEYS[1], 'paused')
end
