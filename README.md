## Manual Invocation

    env TWITTER_CONSUMER_KEY=... TWITTER_CONSUMER_SECRET=... coffee twitter.coffee
    coffee web.coffee


## Useful Redis Commands

    SCARD user-pushed
    SRANDMEMBER user-pushed

    LLEN user-queue
    LRANGE user-queue 0 9

    GET user-popped
    GET user-discarded

    ZCARD influence
    ZRANGE influence 0 9 WITHSCORES
    ZRANGEBYSCORE influence (20000 +inf

    HGETALL influencers

    LLEN follower-queue
    LRANGE follower-queue 0 9

    SCARD followers-pushed
    SMEMBERS followers-pushed

    GET follower-popped
    GET follower-discarded

    LLEN friend-queue
    LRANGE friend-queue 0 9

    SCARD friend-pushed
    SMEMBERS friend-pushed

    GET friend-popped
    GET friend-discarded

    KEYS *
    DEL user-queue user-pushed user-popped user-discarded
    DEL follower-queue follower-pushed follower-popped follower-discarded
    DEL friend-queue friend-pushed friend-popped friend-discarded
    DEL influence influencers lastinfluencer

    CONFIG SET stop-writes-on-bgsave-error no

    LPUSH credentials key:secret
