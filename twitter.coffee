#!/usr/bin/coffee
# copyright 2015, r. brian harrison.  all rights reserved.
#
# TODO save limits into redis

assert  = require 'assert'
util    = require 'util'
co      = require 'co'
redis   = require 'redis'
coRedis = require 'co-redis'
limits  = require 'co-limits'
Twit    = require 'twit'


influential = 4950

twitter = null


createRedisClient = ->
    return coRedis(redis.createClient(process.env.REDIS_URL))


countQueue = ->
    limit = limits(quarterly:180).co()
    redisClient = createRedisClient()

    loop
        # get up to 100 of the next uncounted users whom which we will discriminate

        # get the user first, blockingly
        [_, blockingUserId] = yield redisClient.blpop('twitter:countqueue', 0)
        if blockingUserId
            followedIds = [blockingUserId]

        # add up to 99 more
        for i in [1...100]
            anotherUserId = yield redisClient.lpop('twitter:countqueue')
            break unless anotherUserId
            followedIds.push(anotherUserId)

        # bulk lookup (up to 180/15min)
        # XXX make post due to HTTP url length limit?
        if followedIds.length > 0
            yield limit
            [users] = yield (cb) ->
                twitter.get('users/lookup', user_id:followedIds.join(','), cb)

        # discriminate
        influencerIds = []
        lastInfluencer = null
        for user in users or []
            {followers_count, screen_name, id} = user
            if followers_count >= influential
                console.log "#{screen_name} (#{id}) has #{followers_count}"
                influencerIds.push(id)
                yield redisClient.zadd('twitter:influence', followers_count, screen_name)
                yield redisClient.hset('twitter:influencers', screen_name, JSON.stringify(user))
                lastInfluencer = user

        if lastInfluencer
            yield redisClient.set('twitter:lastinfluencer', JSON.stringify(lastInfluencer))

        # virally check out influcencers' followers
        if influencerIds.length > 0
            yield redisClient.rpush('twitter:followersqueue', influencerIds...)


followersQueue = ->
    limit = limits(quarterly:15).co()
    redisClient = createRedisClient()

    loop
        # get some of a user's followers and queue new ones
        # TODO downstream queue pushback
        [_, user_id] = yield redisClient.blpop('twitter:followersqueue', 0)
        if user_id?
            yield limit
            [{ids}] = yield (cb) ->
                twitter.get('followers/ids', {user_id, count:5000}, cb)

        for follower in ids or []
            if yield redisClient.sadd('twitter:followers', follower)
                yield redisClient.rpush('twitter:friendsqueue', follower)


friendsQueue = ->
    limit = limits(quarterly:15).co()
    redisClient = createRedisClient()

    loop
        # get some of a user's friends and queue new ones
        # TODO pushback
        [_, user_id] = yield redisClient.blpop('twitter:friendsqueue', 0)
        if user_id?
            yield limit
            [{ids}] = yield (cb) ->
                twitter.get('friends/ids', {user_id, count:5000}, cb)

        for friend in ids or []
            if yield redisClient.sadd('twitter:friends', friend)
                yield redisClient.rpush('twitter:countqueue', friend)


seed = ->
    redisClient = createRedisClient()

    user_id = 237845487
    unless yield redisClient.zscore('twitter:influence', user_id)
        # TODO also skip if it's already queued?
        yield redisClient.rpush('twitter:countqueue', user_id)
        console.log "seeded #{user_id}"

authenticate = (consumer_key, consumer_secret) ->
    twitter = new Twit {consumer_key, consumer_secret, app_only_auth: true}
    

start = ->
    {TWITTER_CONSUMER_KEY, TWITTER_CONSUMER_SECRET} = process.env
    assert TWITTER_CONSUMER_KEY, "set TWITTER_CONSUMER_KEY"
    assert TWITTER_CONSUMER_SECRET, "set TWITTER_CONSUMER_SECRET"
    authenticate(TWITTER_CONSUMER_KEY, TWITTER_CONSUMER_SECRET)

    yield [seed, countQueue, followersQueue, friendsQueue]


if require.main is module
    co(start).catch (err) ->
        console.error err.stack


module.exports = {seed, authenticate, start, countQueue, followersQueue, friendsQueue}
