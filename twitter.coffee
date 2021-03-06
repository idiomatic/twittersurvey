#!/usr/bin/coffee
# copyright 2015, r. brian harrison.  all rights reserved.

assert  = require 'assert'
util    = require 'util'
co      = require 'co'
redis   = require 'redis'
coRedis = require 'co-redis'
limits  = require 'co-limits'
wait    = require 'co-wait'
Twit    = require 'twit'


influential = 4950


untilSignal = (signal='SIGTERM') ->
    forever = null
    process.on signal, ->
        clearTimeout(forever)
    yield (cb) ->
        forever = setTimeout(cb, 2147483647)


parseOptionalInt = (n) ->
    n = parseInt(n)
    n = undefined if isNaN(n)
    return n


createRedisClient = ->
    return coRedis(redis.createClient(process.env.REDIS_URL))


class Queue
    constructor: (@queueName, {@pushedCap, @queueCap}={}) ->
        @redis = createRedisClient()
        @blockingRedis = undefined

    push: (value) ->
        # encourage reactive shrinkage (remove more than adding)
        # encourage pushed-value freshness (preferring the new values)
        # discarded values may be serendipitiously repushed
        # for popped influencers, this will update their collected data
        if @pushedCap? and (@pushedCap < yield @redis.scard("#{@queueName}-pushed"))
            yield @redis.spop("#{@queueName}-pushed")
            yield @redis.spop("#{@queueName}-pushed")
            yield @redis.incrby("#{@queueName}-discarded", 2)

        # there's no room in the queue; do nothing further with value
        if @queueCap? and (@queueCap < yield @redis.llen("#{@queueName}-queue"))
            yield @redis.incr("#{@queueName}-discarded")
            return

        # do nothing further if this value is currently here
        return unless yield @redis.sadd("#{@queueName}-pushed", value)

        yield @redis.rpush("#{@queueName}-queue", value)


    pop: (timeout) ->
        # correct Redis sentinel value screwup:
        #     timeout=null -> blocking
        #     timeout=0 -> instant return
        if timeout == 0
            value = yield @redis.lpop("#{@queueName}-queue")
        else
            @blockingRedis ?= createRedisClient()
            [_, value] = yield @blockingRedis.blpop("#{@queueName}-queue", timeout ? 0)
        yield @redis.incr("#{@queueName}-popped")
        return value

    stats: ->
        # prefer frozen stats (where available)
        stats = yield @redis.hgetall("#{@queueName}-stats")
        stats or=
            pushed:    yield @redis.scard("#{@queueName}-pushed")
            popped:    yield @redis.get("#{@queueName}-popped")
            queue:     yield @redis.llen("#{@queueName}-queue")
            discarded: yield @redis.get("#{@queueName}-discarded")
        return stats


# function decorator to apply x-rate-limit headers
rateLimiter = (options) ->
    {disciplinaryNaptime=60000, voluntaryNaptime=0} = options or {}
    waitUntil = 0
    now = ->
        return new Date().getTime()
    f = (fn) ->
        delay = waitUntil - now()
        if delay > 0
            yield wait(delay)
        # HACK eat errors
        [data, response] = yield (cb) ->
            fn (err, args...) ->
                cb(null, args...)
        waitUntil = voluntaryNaptime + now()
        if response?.headers['x-rate-limit-remaining'] is '0'
            waitUntil = Math.max(waitUntil, 1000 * parseInt(response.headers['x-rate-limit-reset']))
        if response?.statusCode is 429
            waitUntil = Math.max(waitUntil, disciplinaryNaptime + now())
            # tail recurse
            yield f(fn)
        return [data, response]
    return f


class Surveyer
    constructor: (@twitter=null) ->
        # TODO make {options} not process.env
        # needs to be considerably bigger than 'ZCARD influence'
        pushedCap  = parseOptionalInt(process.env.USER_PUSHED_CAP)
        queueCap   = parseOptionalInt(process.env.USER_QUEUE_CAP)
        @userQueue = new Queue('user', {pushedCap, queueCap})

        pushedCap       = parseOptionalInt(process.env.FOLLOWERS_PUSHED_CAP)
        queueCap        = parseOptionalInt(process.env.FOLLOWERS_QUEUE_CAP)
        @followersQueue = new Queue('follower', {pushedCap, queueCap})

        pushedCap     = parseOptionalInt(process.env.FRIENDS_PUSHED_CAP)
        queueCap      = parseOptionalInt(process.env.FRIENDS_QUEUE_CAP)
        @friendsQueue = new Queue('friend', {pushedCap, queueCap})

        @usersLookupLimit  = rateLimiter() # 180/15min
        @followersIdsLimit = rateLimiter() # 15/15min
        @friendsIdsLimit   = rateLimiter() # 15/15min
        @redis             = createRedisClient()

    seed: =>
        yield @userQueue.push(237845487)

    stats: ->
        user:           yield @userQueue.stats()
        followers:      yield @followersQueue.stats()
        friends:        yield @friendsQueue.stats()
        influencers:    yield @redis.zcard('influence')
        lastInfluencer: yield =>
            influencer = yield @redis.get('lastinfluencer')
            return JSON.parse(influencer or 'null')
        paused:         yield @redis.get('paused')

    users: =>
        assert @twitter
        loop
            if yield @redis.get('paused')
                yield wait(5000)
                continue

            followedIds = [yield @userQueue.pop()]

            # HACK since blpop(..., timeout) does not work; 100ms queue top-off
            yield wait(100)

            # add up to 99 more possible influencers
            for i in [1...100]
                id = yield @userQueue.pop(0)
                break unless id
                followedIds.push(id)

            # bulk user retrieval
            [users] = yield @usersLookupLimit (cb) =>
                @twitter.get('users/lookup', user_id:followedIds.join(','), cb)

            # discriminate
            for user in users or []
                {followers_count, screen_name, id} = user
                if followers_count >= influential
                    yield @redis.zadd('influence', followers_count, screen_name)
                    userBrief =
                        name:            user.name
                        followers_count: user.followers_count
                        description:     user.description
                        location:        user.location
                        url:             user.url
                    yield @redis.hset('influencers', screen_name, JSON.stringify(userBrief))

                    # virally check out influcencers' followers
                    yield @followersQueue.push(id)
                    lastInfluencer = user

            # HACK
            if lastInfluencer
                yield @redis.set('lastinfluencer', JSON.stringify(lastInfluencer))

    followers: =>
        assert @twitter
        loop
            if yield @redis.get('paused')
                yield wait(5000)
                continue

            id = yield @followersQueue.pop()
            [{ids}] = yield @followersIdsLimit (cb) =>
                @twitter.get('followers/ids', {user_id:id, count:5000}, cb)

            for follower in ids or []
                yield @userQueue.push(follower)
                yield @friendsQueue.push(follower)

    friends: =>
        assert @twitter
        loop
            if yield @redis.get('paused')
                yield wait(5000)
                continue

            id = yield @friendsQueue.pop()
            [{ids}] = yield @friendsIdsLimit (cb) =>
                @twitter.get('friends/ids', {user_id:id, count:5000}, cb)

            for friend in ids or []
                yield @userQueue.push(friend)


authenticate = (consumer_key, consumer_secret) ->
    return new Twit {consumer_key, consumer_secret, app_only_auth: true}


start = ->
    credentials = {}
    {TWITTER_CONSUMER_KEY, TWITTER_CONSUMER_SECRET} = process.env
    if TWITTER_CONSUMER_KEY
        credentials[TWITTER_CONSUMER_KEY] = TWITTER_CONSUMER_SECRET

    redisClient = createRedisClient()
    for credential in yield redisClient.lrange('credentials', 0, -1)
        [key, secret] = credential.split(':')
        continue if key is TWITTER_CONSUMER_KEY
        credentials[key] = secret
    redisClient.quit()

    credentialCount = 0
    for key, secret of credentials
        twitter = authenticate(key, secret)
        surveyer = new Surveyer(twitter)
        yield surveyer.seed()

        # parallel execution
        # TODO error propagation
        chainError = (err) -> setImmediate -> throw err
        #chainError = (err) -> console.error err.stack
        co(surveyer.users).catch chainError
        co(surveyer.followers).catch chainError
        co(surveyer.friends).catch chainError
        ++credentialCount

    console.log "#{credentialCount} Twitter app credential(s) in use"

    # XXX
    #yield untilSignal()


if require.main is module
    co(start).catch (err) ->
        console.error err.stack


module.exports = {start, createRedisClient, Queue, Surveyer}
