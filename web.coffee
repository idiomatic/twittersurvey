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
        <html>
          <head>
            <link rel="stylesheet" href="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/style.css" />
            <style>
              body {font-family: Sans-Serif;}
              th, td {text-align: right; padding: 0.5em;}
              th:first-child {text-align: left;}
              table {border-collapse: collapse;}
              table, td, th {border: 1px solid black;}
              .explain {font-size: x-small; color:#ccc;}
            </style>
          </head>
          <body>
            <h2>Statistics</h2>
            <table>
              <tr>
                <th></th>
                <th>unique discovered</th>
                <th>queue</th>
              </tr>
              <tr>
                <th>Influencers
                  <div class="explain">
                    Twitter users with 5000 followers or more
                  </div>
                </th>
                <td>
                  #{influence}<br/>
                  <a href="/influencers.csv?offset=0&count=5000">download</a>
                </td>
                <td>#{countqueue}</td>
              </tr>
              <tr>
                <th>Their Followers
                  <div class="explain">
                    Influencers with followers<br/>
                    Fetches the first 5000 followers (slow)<br/>
                    Users are eventually follower-count-discriminated
                  </div>
                </th>
                <td>#{followered}</td>
                <td>#{followersqueue}</td>
              </tr>
              <tr>
                <th>Their Friends
                  <div class="explain">
                    Users that follow others<br/>
                    Fetches the first 5000 users they follow (slow)<br/>
                    Occasionally purged without consequence
                  </div>
                </th>
                <td>&gt;&nbsp;#{friended}</td>
                <td>#{friendsqueue}</td>
              </tr>
            </table>
            <h2>Latest Influencer</h2>
            <script src="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/bundle.js"></script>
            <script>
              var lastInfluencer = #{JSON.stringify(JSON.parse(lastInfluencer))};
              var formatter = new JSONFormatter(lastInfluencer);
              document.body.appendChild(formatter.render())
            </script>
          </body>
        </html>
        """

    app.use route.get '/influencers.csv', (next) ->
        s = csv.createWriteStream()
        @body = s
        @type = 'text/csv'
        @attachment()
        {offset, count} = @query
        offset ?= 0
        count  ?= 5000
        influencers = yield redisClient.zrevrangebyscore('twitter:influence', '+inf', 5000, 'withscores', 'limit', offset, count)
        influencers = dictify(influencers)
        s.write(['screen_name', 'followers_count', 'name', 'description', 'location', 'url', 'email_address'])
        # HACK proceed in parallel to sending HTTP headers
        co ->
            # HACK x@y.z is valid, but x@gmail and "x at gmail dot com" are not
            email_re = /\S+@\S+\.\S+/
            for screen_name, followers_count of influencers
                influencer = yield redisClient.hget('twitter:influencers', screen_name)
                {name, description, location, url} = JSON.parse(influencer)
                email_address = email_re.exec(description)?[0]
                s.write([screen_name, followers_count, name, description, location, url, email_address])
            s.end()

    app.listen(port)


if require.main is module
    co(start)


module.exports = {start}
