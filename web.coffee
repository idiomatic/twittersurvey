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
survey    = require './twitter'


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
    surveyer = new survey.Surveyer()

    app = koa()
    app.use route.get '/', (next) ->
        stats = yield surveyer.stats()
        
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
                <th>processed</th>
                <th>
                  queue
                  <div class="explain">Backlog</div>
                </th>
              </tr>

              <tr>
                <th>Users
                  <div class="explain">
                    Twitter users
                  </div>
                </th>
                <td>#{stats.user.pushed}</td>
                <td>#{stats.user.popped}</td>
                <td>#{stats.user.queue}</td>
              </tr>

              <tr>
                <th>Influencers
                  <div class="explain">
                    Twitter users with 5000 followers or more
                  </div>
                  <div>
                    <a href="/influencers.csv">download all</a> or
                    <a href="/influencers.csv?offset=0&count=5000">first 5000</a>
                  </div>
                </th>
                <td>#{stats.influencers}</td>
                <td>#{stats.influencers}</td>
                <td>#{stats.user.queue}</td>
              </tr>

              <tr>
                <th>Influencer Followers
                  <div class="explain">
                    Influencers with followers<br/>
                    About to (slowly) fetch the first 5000 followers
                  </div>
                </th>
                <td>#{stats.followers.pushed}</td>
                <td>#{stats.followers.popped}</td>
                <td>#{stats.followers.queue}</td>
              </tr>

              <tr>
                <th>Influencer Follower Friends
                  <div class="explain">
                    Users that follow others<br/>
                    About to (slowly) fetch the first 5000 users they follow<br/>
                    Occasionally purged without consequence
                  </div>
                </th>
                <td>&gt;&nbsp;#{stats.friends.pushed}</td>
                <td>#{stats.friends.popped}</td>
                <td>&gt;&nbsp;#{stats.friends.queue}</td>
              </tr>
            </table>

            <h2>Latest Influencer</h2>
            <script src="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/bundle.js"></script>
            <script>
              var lastInfluencer = #{JSON.stringify(stats.lastInfluencer)};
              var formatter = new JSONFormatter(lastInfluencer);
              document.body.appendChild(formatter.render())
            </script>
          </body>
        </html>
        """

    app.use route.get '/influencers.csv', (next) ->
        redisClient = createRedisClient()
        s = csv.createWriteStream()
        @body = s
        @type = 'text/csv'
        @attachment()
        {offset, count} = @query
        offset ?= 0
        count  ?= -1
        # TODO redis via Surveyer
        influencers = yield redisClient.zrevrangebyscore('influence', '+inf', 5000, 'withscores', 'limit', offset, count)
        influencers = dictify(influencers)
        s.write(['screen_name', 'followers_count', 'name', 'description', 'location', 'url', 'email_address'])
        # HACK proceed in parallel to sending HTTP headers
        co ->
            # HACK x@y.z is valid, but x@gmail and "x at gmail dot com" are not
            email_re = /\S+@\S+\.\S+/
            for screen_name, followers_count of influencers
                influencer = yield redisClient.hget('influencers', screen_name)
                {name, description, location, url} = JSON.parse(influencer)
                description = description.replace(/\r/g, '\n')
                email_address = email_re.exec(description)?[0]
                s.write([screen_name, followers_count, name, description, location, url, email_address])
            s.end()
            redisClient.quit()

    app.listen(port)


if require.main is module
    co(start)


module.exports = {start}
