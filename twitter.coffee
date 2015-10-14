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


untilSignal = (signal='SIGTERM') ->
    forever = null
    process.on signal, ->
        clearTimeout(forever)
    yield (cb) ->
        forever = setTimeout(cb, 2147483647)


createRedisClient = ->
    return coRedis(redis.createClient(process.env.REDIS_URL))


countQueue = (twitter) ->
    limit = limits(quarterly:180).co()
    redisClient = createRedisClient()

    loop
        # get up to 100 of the next uncounted users whom which we will discriminate

        # get the user first, blockingly
        [_, blockingUserId] = yield redisClient.blpop('twitter:countqueue', 0)
        if blockingUserId
            followedIds = [blockingUserId]

        # HACK since blpop(..., timeout) does not work
        yield (cb) -> setTimeout cb, 100

        # add up to 99 more
        for i in [1...100]
            #[_, anotherUserId] = yield redisClient.blpop('twitter:countqueue', '1')
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
        lastInfluencer = null
        for user in users or []
            {followers_count, screen_name, id} = user
            if followers_count >= influential
                #console.log "#{screen_name} (#{id}) has #{followers_count}"
                yield redisClient.zadd('twitter:influence', followers_count, screen_name)
                yield redisClient.hset('twitter:influencers', screen_name, JSON.stringify(user))
                # virally check out influcencers' followers
                if yield redisClient.sadd('twitter:followered', id)
                    yield redisClient.rpush('twitter:followersqueue', id)
                lastInfluencer = user

        if lastInfluencer
            yield redisClient.set('twitter:lastinfluencer', JSON.stringify(lastInfluencer))


followersQueue = (twitter) ->
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
            if yield redisClient.sadd('twitter:friended', follower)
                yield redisClient.rpush('twitter:friendsqueue', follower)
            if yield redisClient.sadd('twitter:counted', follower)
                yield redisClient.rpush('twitter:countqueue', follower)


friendsQueue = (twitter) ->
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
            if yield redisClient.sadd('twitter:counted', friend)
                # HACK: prioritize by pushing in front
                yield redisClient.lpush('twitter:countqueue', friend)


seed = ->
    redisClient = createRedisClient()

    user_id = 237845487
    if yield redisClient.sadd('twitter:counted', user_id)
        # TODO also skip if it's already queued?
        yield redisClient.rpush('twitter:countqueue', user_id)
        console.log "seeded #{user_id}"

    redisClient.quit()


authenticate = (consumer_key, consumer_secret) ->
    return new Twit {consumer_key, consumer_secret, app_only_auth: true}


start = ->
    credentials = {}
    {TWITTER_CONSUMER_KEY, TWITTER_CONSUMER_SECRET} = process.env
    if TWITTER_CONSUMER_KEY
        credentials[TWITTER_CONSUMER_KEY] = TWITTER_CONSUMER_SECRET]

    redisClient = createRedisClient()
    for credential in yield redisClient.lrange('twitter:credentials', 0, -1)
        [key, secret] = credential.split(':')
        continue if key is TWITTER_CONSUMER_KEY
        credentials[key] = secret
    redisClient.quit()

    # patient0
    yield seed

    credentialCount = 0
    for key, secret of credentials
        twitter = authenticate(key, secret)
        # parallel execution
        co -> yield countQueue(twitter)
        co -> yield followersQueue(twitter)
        co -> yield friendsQueue(twitter)
        ++credentialCount

    console.log "#{credentialCount} Twitter app credentials in use"

    # XXX
    #yield untilSignal()


if require.main is module
    co(start).catch (err) ->
        console.error err.stack


module.exports = {seed, authenticate, start, countQueue, followersQueue, friendsQueue}
