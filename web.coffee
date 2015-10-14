#!/usr/bin/env coffee

util      = require 'util'
koa       = require 'koa'
#route     = require 'koa-route'
#koaStatic = require 'koa-static'
co        = require 'co'
redis     = require 'redis'
coRedis   = require 'co-redis'


port = process.env.PORT ? 3002


createRedisClient = ->
    return coRedis(redis.createClient(process.env.REDIS_URL))


start = ->
    redisClient = createRedisClient()

    app = koa()
    app.use (next) ->
        countqueue     = yield redisClient.llen('twitter:countqueue')
        followersqueue = yield redisClient.llen('twitter:followersqueue')
        friendsqueue   = yield redisClient.llen('twitter:friendsqueue')
        followers      = yield redisClient.scard('twitter:followers')
        friends        = yield redisClient.scard('twitter:friends')
        influencers    = yield redisClient.zcard('twitter:influence')
        lastInfluencer = yield redisClient.get('twitter:lastinfluencer')
        @body = """
        <!DOCTYPE html>
        <html><head>
            <link rel="stylesheet" href="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/style.css" />
        </head><body>
        <h2>progress</h2>
        followers #{followers}<br/>
        friends #{friends}<br/>
        influencers #{influencers}<br/>
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
    app.listen(port)


if require.main is module
    co(start)


module.exports = {start}
