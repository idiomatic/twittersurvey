#!/usr/bin/env coffee
# copyright 2015, r. brian harrison.  all rights reserved.

# TODO optimize CSV generation

util      = require 'util'
koa       = require 'koa'
route     = require 'koa-route'
#koaStatic = require 'koa-static'
co        = require 'co'
redis     = require 'redis'
coRedis   = require 'co-redis'
csv       = require 'fast-csv'


port = process.env.PORT ? 3002


createRedisClient = ->
    return coRedis(redis.createClient(process.env.REDIS_URL))


dictify = (a) ->
    # [k, v, k2, v2, ... ] -> {k: v, k2: v, ...}
    d = {}
    for v, i in a
        if i % 2 is 1
            d[a[i - 1]] = v
    return d


start = ->
    redisClient = createRedisClient()

    app = koa()
    app.use route.get '/', (next) ->
        countqueue     = yield redisClient.llen('twitter:countqueue')
        followersqueue = yield redisClient.llen('twitter:followersqueue')
        friendsqueue   = yield redisClient.llen('twitter:friendsqueue')
        followered     = yield redisClient.scard('twitter:followered')
        friended       = yield redisClient.scard('twitter:friended')
        counted        = yield redisClient.scard('twitter:counted')
        influence      = yield redisClient.zcard('twitter:influence')
        lastInfluencer = yield redisClient.get('twitter:lastinfluencer')
        @body = """
        <!DOCTYPE html>
        <html><head>
            <link rel="stylesheet" href="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/style.css" />
        </head><body>
        <h2>progress</h2>
        followers #{followered}<br/>
        friends #{friended}<br/>
        influencers #{influence} <a href="/influencers.csv?offset=0&count=5000">download</a><br/>
        <h2>queues</h2>
        count #{countqueue}<br/>
        followers #{followersqueue}<br/>
        friends #{friendsqueue}<br/>
        <h2>latest influencer<h2>
        <script src="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/bundle.js"></script>
        <script>
            var lastInfluencer = #{JSON.stringify(JSON.parse(lastInfluencer))};
            var formatter = new JSONFormatter(lastInfluencer);
            document.body.appendChild(formatter.render())
        </script>
        """

    app.use route.get '/influencers.csv', (next) ->
        s = csv.createWriteStream()
        @body = s
        @type = 'text/csv'
        @attachment()
        {offset, count} = @query
        offset ?= 0
        count ?= 5000
        influencers = yield redisClient.zrevrangebyscore('twitter:influence', '+inf', 5000, 'withscores', 'limit', offset, count)
        influencers = dictify(influencers)
        co ->
            s.write(['screen_name', 'followers_count', 'name', 'description', 'location', 'url'])
            for screen_name, followers_count of influencers
                influencer = yield redisClient.hget('twitter:influencers', screen_name)
                {name, description, location, url} = JSON.parse(influencer)
                s.write([screen_name, followers_count, name, description, location, url])
            s.end()

    app.listen(port)


if require.main is module
    co(start)


module.exports = {start}
