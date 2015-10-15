manual invocation:

    env TWITTER_CONSUMER_KEY=... TWITTER_CONSUMER_SECRET=... coffee twitter.coffee
    coffee web.coffee


some useful Redis commands:

    LLEN "twitter:countqueue"
    LRANGE "twitter:countqueue" 0 9

    LLEN "twitter:followersqueue"
    LRANGE "twitter:followersqueue" 0 9

    LLEN "twitter:friendsqueue"
    LRANGE "twitter:friendsqueue" 0 9

    SCARD "twitter:followers"
    SMEMBERS "twitter:followers"

    SCARD "twitter:friends"
    SMEMBERS "twitter:friends"

    ZCARD "twitter:influence"
    ZRANGE "twitter:influence" 0 9 WITHSCORES
    ZRANGEBYSCORE "twitter:influence" (20000 +inf

    KEYS twitter:*
    DEL twitter:countqueue
    DEL twitter:followersqueue
    DEL twitter:friendsqueue
    DEL twitter:followers
    DEL twitter:influence

    CONFIG SET stop-writes-on-bgsave-error no
