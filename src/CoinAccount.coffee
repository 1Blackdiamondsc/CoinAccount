levelup = require "levelup"
levelplus = require "levelplus"
db = levelplus levelup "CoinAccountDB"
NodeCache = require "node-cache"
bitcoin = require "bitcoin"

cache = new NodeCache
  stdTTL: 600
  checkperiod: 120

clients = 
  FTC: new bitcoin.Client
    host: "localhost"
    port: 8332
    user: "Kevlar"
    pass: "zabbas"

clients.FTC.confirmations = 10


includeTransaction = (tx, amount, height)->
  (record)->
    if record[tx.id]?
      record[tx.id].amount += amount
    else
	  record[tx.id] =
        tx:tx
        amount:amount
        height:height
        date:new Date()
    record

removeTransaction = (tx)->
  (record)->
    if record[tx.id]?
      delete record[tx.id]
    record

checkTransactionForInterest = (tx, callback)->
  return false if not tx?
  for vout in tx.vout
    if vout.scriptPubKey?.addresses?
      do (vout)->
        for address in vout.scriptPubKey.addresses
          do (address)->
            db.get address, (err, user)->
              callback user, vout if not err?
                              
checkForPending = ()->
  for currency, client of clients
    do (currency, client)->
      db.get currency + "-lastPendingBlock", (err, lastBlock)->
        lastBlock = 1 if err?
        client.getBlockHash lastBlock, (error, hash) ->
          return console.log error if error?
          client.getBlock hash, (error, block)->
            return console.log error if error?
            db.put currency + "-lastPendingBlock", lastBlock+1
            return false if not block?.tx?
            for tx in block.tx
              do (tx)->
                client.getRawTransaction tx, (err, raw) ->
                  client.decodeRawTransaction raw, (error, tx)->
                    checkTransactionForInterest tx, (user, vout)->
                      getAccount user, (err, account)->
                        account.addPendingTransaction currency, tx, vout.value, lastBlock
            		  
            		  
checkForIncoming = ()->
  for currency, client of clients
    do (currency, client)->
      db.get currency + "-lastBlock", (err, lastBlock)->
        lastBlock = 1 if err?
        client.getBlockCount (err, blockCount)->
          return if blockCount - client.confirmations > lastBlock
          client.getBlockHash lastBlock, (error, hash) ->
            return console.log error if error?
            db.put currency + "-lastBlock", lastBlock+1
            client.getBlock hash, (error, block)->
              return console.log error if error?
              return false if not block?.tx?
              for tx in block.tx
                do (tx)->
                  checkTransactionForInterest tx, (user, vout)->
                    getAccount user, (err, account)->
                      account.removePendingTransaction currency, tx, vout.value
                      account.addConfirmedTransaction currency, tx, vout.value, lastBlock
                          
  
addToBalance = (amount, callback)->
  (oldBalance)->
    unless oldBalance?
      callback null, amount
      amount
    else
      callback null, amount + oldBalance
      amount + oldBalance
      
subtractFromBalance = (amount, callback)->
  (oldBalance)->
    throw "Error, invalid withdraw: " + amount if amount > oldBalance  
    callback?(null, amount - oldBalance)
    amount - oldBalance
      
getAccount = (user, callback)->
  cache.get user, (err, account)->
    if err? or not account?
      account = new CoinAccount user
    cache.set user, account
    callback null, account
    
getUserByAddress = (address, callback)->
  db.get address, (err, user)->
    callback? err if err?
    callback null, user
    		
class CoinAccount
  constructor(user)->
    @user = user
  getBalance: (currency, callback)->
    db.get @user + "|" + currency + "|Balance", (err, balance)->
      if err? then callback 0 else callback balance
  getAccountAddresses: (currency, callback)|>
    db.get @user + "|" + currency + "|AccountAddresses", (err, addresses)->
      if err? then callback [] else callback addresses
  addAccountAddress: (currency, address)->
    db.sadd @user + "|" + currency + "|AccountAddresses", address
    db.put address, @user
  addPendingTransaction: (currency, tx, amount, height)->
    db.update @user + "|" + currency + "|PendingTransactions", includeTransaction tx, amount, height
    @addPendingBalance currency, amount
  removePendingTransaction: (currency, tx, amount)->
    db.update @user + "|" + currency + "|PendingTransactions", removeTransaction tx
    @subtractPendingBalance currency, amount
  addPendingBalance: (currency, amount, callback)->
    db.update @user + "|" + currency + "|PendingBalance", addToBalance amount, (err, newPendingBal)->
      return callback? err if err?
      callback? null, newBal
  subtractPendingBalance: (currency, amount, callback)->
    db.update @user + "|" + currency + "|PendingBalance", subtractFromBalance amount, (err, newPendingBal)->
      return callback? err if err?
      callback? null, newBal
  addIncomingTransaction: (currency, tx, amount, height, callback)
    db.update @user + "|" + currency + "|IncomingTransactions", includeTransaction tx, amount, height
    @addBalance currency, amount, (err, newBal)->
      return callback? err if err?
      callback? null, newBal
  addOutgoingTransaction: (currency, tx, amount)->
    db.update @user + "|" + currency + "|OutgoingTransactions", includeTransaction tx, amount
  withdraw: (currency, amount, address, callback)->
    @getBalance currency, (balance)->
      return callback? "Cannot withdraw " + amount + ", balance is only " + balance if balance < amount
      clients[currency].sendToAddress address, amount, (err, txid)->
        return callback? err if err?
        @subtractBalance currency, amount, (err, newBal)->
          callback? null, newBal, txid
  addBalance: (currency, amount, callback)->
    db.update @user  + "|" + currency + "|Balance", addToBalance amount, (err, newBal)->
      return callback? err if err?
      callback? null, newBal
  subtractBalance: (currency, amount, callback)->
    db.update @user + "|" + currency + "|Balance", subtractFromBalance amount, (err, newBal)->
      return callback? err if err?
      callback? null, newBal
  give: (reciever, currency, amount, callback)->
    @getBalance currency, (balance)->
      if not balance >= amount then return callback? "Cannot give " + amount + ", insufficent balance."
      @subtractBalance currency, amount, (err, newBal)->
        return callback? err if err?
        reciever.addBalance currency, amount, (err, recieverBal)->
          return callback? err if err?
          callback?(null, newBal, recieverBal)

if exports? 
  exports.getAccount = getAccount