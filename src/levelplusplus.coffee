module.exports = (db) ->
  lock = (key) ->
    keyVal = JSON.stringify(key)
    ret = locks[keyVal]
    locks[keyVal] = true
    ret
  unlock = (key) ->
    delete locks[JSON.stringify(key)]
  locks = {}
  db.updateBatch = (batch) ->
    doUpdate = ->
      locked = []
      for u in batch
        if lock u.key
          for l in locked
            unlock l
          return setImmediate(doUpdate)
        locked.push JSON.stringify(u.key)
      for b in batch
        db.updateNoLock b.key, b.value, b.callback
  db.update = (key, fn, cb)->
    doUpdate = ->
      return setImmediate(doUpdate) if lock key
      db.updateNoLock key, fn, cb
    doUpdate()
  db.updateNoLock = (key, fn, cb) ->
    doUpdate = ->
      self.get key, (err, data) ->
        if err and err.name isnt "NotFoundError"
          unlock key
          return cb and cb(err)
        data = undefined
        try
          if typeof fn is "function"
            data = fn(data)
          else
            data = fn
        catch e
          unlock key
          return cb and cb(err)
        self.put key, data, (err) ->
          if err
            unlock key
            return cb and cb(err)
          unlock key
          cb and cb(null, data)


    self = this
    doUpdate()

  db.inc = (key, init, cb) ->
    inc = (data) ->
      data = init  if data is `undefined`
      ++data
    @update key, inc, cb

  db.push = (key, value, cb) ->
    push = (data) ->
      data = data or []
      data.push value
      data
    @update key, push, cb

  db.sadd = (key, value, cb) ->
    sadd = (data) ->
      data = data or []
      value = [value]  unless value instanceof Array
      value.forEach (item) ->
        data.push item  unless ~data.indexOf(item)

      data
    @update key, sadd, cb

  db