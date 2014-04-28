levelup = require "levelup"
levelplusplus = require "./levelplusplus"
db = levelplusplus levelup "CoinAccountDB"
NodeCache = require "node-cache"
bitcoin = require "bitcoin"
{EventEmitter} = require 'events'

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

addPendingTransaction = (currency, tx, amount, height)->
  (record)->
    if not record[currency]?
      record[currency] = {}
    if not record[currency].pendingTransactions?
      record[currency].pendingTransactions = {}
    if not record[currency].pendingTransactions[tx.id]?
      record[currency].pendingTransactions[tx.id] =
        tx:tx
        amount:amount
        height:height
        date:new Date()
    else
      record[currency].pendingTransactions[tx.id].amount += amount
    record

addConfirmedTransaction = (currency, tx, amount, height)->
  (record)->
    if not record[currency]?
      record[currency] = {}
    if not record[currency].confirmedTransactions?
      record[currency].confirmedTransactions = {}
    if not record[currency].confirmedTransactions[tx.id]?
      record[currency].confirmedTransactions[tx.id] =
        tx:tx
        amount:amount
        height:height
        date:new Date()
    else
      record[currency].confirmedTransactions[tx.id].amount += amount
    record
    
addOutgoingTransaction = (currency, tx, amount)->
  (record)->
    if not record[currency]?
      record[currency] = {}
    if not record[currency].outgoingTransactions?
      record[currency].outgoingTransactions = {}
    if not record[currency].outgoingTransactions[tx.id]?
      record[currency].outgoingTransactions[tx.id] =
        tx:tx
        amount:amount
        date:new Date()
    record
    
removePendingTransaction = (currency, tx)->
  (record)->
    if record?[currency]?.pendingTransactions?[tx.id]?
      delete record[currency].pendingTransactions[tx.id]
    record
 
removeConfirmedTransaction = (currency, tx)->
  (record)->
    if record?[currency]?.confirmedTransactions?[tx.id]?
      delete record[currency].confirmedTransactions[tx.id]
    record

addAddress = (currency, address)->
  (record)->
    if not record?[currency]?
      record[currency] = {}
    if record?[currency]?.addresses?
      record[currency].addresses.push address
    else
      record[currency].addresses = [address]
    
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
                          
  
addToBalance = (currency, amount, callback)->
  (record)->
    if not record[currency]
      record[currency] = {} 
    if not record[currency].balance
      record[currency].balance = amount
    else
      record[currency].balance += amount
    callback record[currency].balance if callback?
    record

addPendingBalance = (currency, amount, callback)->
  (record)->
    if not record[currency]
      record[currency] = {} 
    if not record[currency].pendingBalance
      record[currency].pendingBalance = amount
    else
      record[currency].pendingBalance += amount
    callback record[currency].pendingBalance if callback?
    record
    
subtractFromBalance = (currency, amount, callback)->
  (record)->
    if not record[currency]?
      callback? "Error, invalid withdraw of " + amount + " " + currency + ", balance is not available."  
      return record
    if record[currency].balance? and record[currency].balance < amount
      callback? "Error, invalid withdraw of " + amount + " " + currency + ", balance is only " + record[currency].balance + "."
      return record
    record[currency].balance -= amount
    callback?(null, record[currency].balance)
    record

subtractPendingBalance = (currency, amount, callback)->
  (record)->
    if not record[currency]?
      callback? "Error, invalid withdraw of " + amount + " " + currency + ", balance is not available."  
      return record
    if record[currency].balance? and record[currency].pendingBalance < amount
      callback? "Error, invalid withdraw of " + amount + " " + currency + ", balance is only " + record[currency].pendingBalance + "."
      return record
    record[currency].pendingBalance -= amount
    callback?(null, record[currency].pendingBalance)
    record
      
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
    		
class CoinAccount extends EventEmitter
  constructor:(user)->
    @user = user
    db.get user, (err, record)->
      if err? or not record?
        db.put user, {}
    events.EventEmitter.call @
  getBalance: (currency, callback)->
    db.get @user, (err, record)->
      if err? then return callback err, 0 
      if not record[currency]?
        record[currency]=
          balance:0
          pendingBalance:0
          addresses:[]
          confirmedTransactions:[]
          pendingTransactions:[]
        db.put @user, record
      callback null, record[currency].balance
  getPendingBalance: (currency, callback)->
    db.get @user, (err, record)->
      if err? then return callback err, 0 
      if not record[currency]?
        record[currency]=
          balance:0
          pendingBalance:0
          addresses:[]
          confirmedTransactions:[]
          pendingTransactions:[]
        db.put @user, record
      callback null, record[currency].pendingBalance
  getAccountAddresses: (currency, callback)->
    db.get @user, (err, record)->
      if err? then callback err, [] 
      if not record[currency]?
        record
      callback null, record[currency].addresses
  addAccountAddress: (currency, address)->
    db.update @user, addAddress currency, address
    db.put address, @user
  generateDepositAddress: (currency, callback)->
    clients[currency].getNewAddress (err, address)->
      return callback? err if err?
      @addAccountAddress currency, address
      callback? null, address
  addPendingTransaction: (currency, tx, amount, height)->
    db.update @user, addPendingTransaction currency, tx, amount, height
    @addPendingBalance currency, amount
    @emit "PendingTransaction", 
      currency:currency
      tx:tx
      amount:amount
  removePendingTransaction: (currency, tx, amount)->
    db.update @user, removePendingTransaction currency, tx
    @subtractPendingBalance currency, amount
  addPendingBalance: (currency, amount, callback)->
    db.update @user, addPendingBalance currency, amount, callback
  subtractPendingBalance: (currency, amount, callback)->
    db.update @user, subtractPendingBalance currency, amount, callback
  addIncomingTransaction: (currency, tx, amount, height, callback)
    db.update @user, addConfirmedTransaction currency, tx, amount, height
    @addBalance currency, amount, callback
    @emit "ConfirmedTransaction", 
      currency:currency
      tx:tx
      amount:amount
  addOutgoingTransaction: (currency, tx, amount)->
    db.update @user, includeOutgoingTransaction tx, amount
  withdraw: (currency, amount, address, callback)->
    self=@
    @getBalance currency, (balance)->
      return callback? "Cannot withdraw " + amount + ", balance is only " + balance if balance < amount
      clients[currency].sendToAddress address, amount, (err, txid)->
        return callback? err if err?
        self.subtractBalance currency, amount, (err, newBal)->
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
    self=@
    @getBalance currency, (balance)->
      if not balance >= amount then return callback? "Cannot give " + amount + ", insufficent balance."
      self.subtractBalance currency, amount, (err, newBal)->
        return callback? err if err?
        reciever.addBalance currency, amount, (err, recieverBal)->
          return callback? err if err?
          callback?(null, newBal, recieverBal)
          reciever.emit "IncomingTransfer", 
            currency:currency
            amount:amount

if exports? 
  exports.getAccount = getAccount