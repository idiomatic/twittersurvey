#!/usr/bin/env coffee
# copyright 2015, r. brian harrison.  all rights reserved.

# TODO optimize CSV generation

os        = require 'os'
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


commatize = (n) ->
    fractionIndex = (n or 0).toString().lastIndexOf('.')
    fraction = ''
    if fractionIndex > -1
        fraction = n.toString().substr(fractionIndex)
    if n >= 1000
        commatize(Math.floor(n / 1000)) + ',' + Math.floor(n).toString().substr(-3) + fraction
    else
        n


start = ->
    surveyer = new survey.Surveyer()

    app = koa()
    app.use route.get '/', (next) ->
        stats = yield surveyer.stats()

        @body = """
        <!DOCTYPE html>
        <html>
          <head>
            <title>Twitter Influencer Survey</title>
            <link rel="stylesheet" href="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/style.css" />
            <style>
              body {font-family: Sans-Serif;}
              #{if stats.stopped then "body {background-color:#fff9f9;}" else ""}
              th, td {text-align: right; padding: 0.5em;}
              th:first-child {text-align: left;}
              table {border-collapse: collapse;}
              table, td, th {border: 1px solid black;}
              th.trivia, td.trivia {border: 1px solid #eee; color:#eee;}
              th.trivia *, td.trivia * {color:#eee;}
              .explain {font-size: x-small; color:#ccc;}
              h1 {color:#f00;}
            </style>
          </head>
          <body>
            #{if stats.stopped then "<h1>stopped</h1>" else ""}
            <h2>Statistics</h2>

            <table>
              <tr>
                <th></th>
                <th>processed</th>
                <th>unique discovered</th>
                <th>
                  queue
                  <div class="explain">Backlog</div>
                </th>
                <th class="trivia">
                  discarded
                  <div class="explain">Memory pressure</div>
                </th>
              </tr>

              <tr>
                <th>Users
                  <div class="explain">
                    Twitter users
                  </div>
                </th>
                <td>#{commatize stats.user.popped or 0}</td>
                <td>#{if stats.user.discarded then "&ge;&nbsp;" else ""}#{commatize stats.user.pushed or 0}</td>
                <td rowspan=2>#{if stats.user.discarded then "&ge;&nbsp;" else ""}#{commatize stats.user.queue or 0}</td>
                <td class="trivia">#{commatize stats.user.discarded or 0}</td>
              </tr>

              <tr>
                <th>Influencers
                  <div class="explain">
                    Twitter users with 5,000 followers or more
                  </div>
                  <div>
                    <a href="/influencers.csv">download all</a> or
                    <a href="/influencers.csv?offset=0&count=5000">top #{commatize Math.min(5000, stats.influencers)}</a>
                    <a href="/influencers.csv?offset=0&count=5000&hasemail=1">with email</a>
                  </div>
                </th>
                <td colspan=2>#{commatize stats.influencers}</td>
                <td class="trivia">0</td>
              </tr>

              <tr>
                <th>Influencer Followers
                  <div class="explain">
                    Influencers with followers<br/>
                    About to (slowly) fetch the first 5,000 followers
                  </div>
                </th>
                <td>#{commatize stats.followers.popped or 0}</td>
                <td>#{if stats.followers.discarded then "&ge;&nbsp;" else ""}#{commatize stats.followers.pushed or 0}</td>
                <td>#{if stats.followers.discarded then "&ge;&nbsp;" else ""}#{commatize stats.followers.queue or 0}</td>
                <td class="trivia">#{commatize stats.followers.discarded or 0}</td>
              </tr>

              <tr>
                <th>Influencer Follower Friends
                  <div class="explain">
                    Users that follow others<br/>
                    About to (slowly) fetch the first 5,000 users they follow
                  </div>
                </th>
                <td>#{commatize stats.friends.popped or 0}</td>
                <td>#{if stats.friends.discarded then "&ge;&nbsp;" else ""}#{commatize stats.friends.pushed or 0}</td>
                <td>#{if stats.friends.discarded then "&ge;&nbsp;" else ""}#{commatize stats.friends.queue or 0}</td>
                <td class="trivia">#{commatize stats.friends.discarded or 0}</td>
              </tr>
            </table>

            <h2>Latest Influencer</h2>
            <p>
              <a href="https://twitter.com/#{stats.lastInfluencer.screen_name}">#{stats.lastInfluencer.name}</a>
            </p>
            <script src="https://cdn.rawgit.com/mohsen1/json-formatter-js/master/dist/bundle.js"></script>
            <script>
              var lastInfluencer = #{JSON.stringify(stats.lastInfluencer)};
              var formatter = new JSONFormatter(lastInfluencer);
              document.body.appendChild(formatter.render())
            </script>
          </body>
        </html>
        """

    app.use route.get '/stats', (next) ->
        @body = yield surveyer.stats()

    app.use route.get '/influencers.csv', (next) ->
        redisClient = createRedisClient()
        s = csv.createWriteStream()
        @body = s
        @type = 'text/csv'
        @attachment()
        s.write(['screen_name', 'followers_count', 'name', 'description', 'location', 'url', 'email_address'])
        {offset, count, hasemail} = @query
        influencers = null
        if offset? or count?
            # lazily avoid this ZSET if downloading all
            offset ?= 0
            count  ?= -1
            # TODO redis via Surveyer
            influencers = yield redisClient.zrevrangebyscore('influence', '+inf', 5000, 'withscores', 'limit', offset, count)
            influencers = dictify(influencers)
        # HACK proceed in parallel to sending HTTP headers
        co (cb) ->
            # HACK x@y.z is valid, but x@gmail and "x at gmail dot com" are not
            email_re = /\S+@\S+\.\S+/
            # HACK fetch everything and filter here
            cursor = '0'
            loop
                [cursor, influencersChunk] = yield redisClient.hscan('influencers', cursor, 'COUNT', 100)
                for screen_name, influencer of dictify(influencersChunk)
                    {name, followers_count, description, location, url} = JSON.parse(influencer)
                    continue if influencers? and not influencers[screen_name]
                    description = description.replace(/\r/g, '\n')
                    email_address = email_re.exec(description)?[0]
                    continue if hasemail? and not email_address
                    s.write([screen_name, followers_count, name, description, location, url, email_address])
                break if cursor is '0'
                
            s.end()
            redisClient.quit()
            cb?()
        .catch (err) ->
            # TODO propagate
            console.error err.stack

    app.use route.get '/memory', (next) ->
        @body = process.memoryUsage()
        yield return

    app.use route.get '/loadavg', (next) ->
        @body = os.loadavg()
        yield return

    app.listen(port)


if require.main is module
    co(start).catch (err) ->
        console.error err.stack


module.exports = {start}
