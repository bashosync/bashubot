# Description:
#   Manage the on-call list and automate on-call schedule
#
# Dependencies:
#   cron
#   util
#   underscore
#   scoped-http-client
#
# Configuration:
#   ESCALATION_URL
#   ESCALATION_USER
#   ESCALATION_PASSWORD
#   ESCALATION_CRONSCHEDULE
#   ESCALATION_NOTIFICATIONROOM
#
# Commands:
#  hubot add <name>[ ,<name>...] to the on-call schedule for|from <mm/dd/yyyy>[ through|thru|to|until <mm/dd/yyyy>] - add people to a schedule
#  hubot set the on-call schedule for <mm/dd/yyyy> to <name>[,<name>...] - Create a schedule entry for date containing only the listed names
#  hubot unschedule <name>[, <name>...] from on-call for|from <mm/dd/yyyy>[ through|thru|to|until <mm/dd/yyyy>] - remove people from a schedule
#  hubot apply the on-call schedule - [re]update the current on-call list with the schedule for today
#  hubot clear the on-call schedule [for|from <mm/dd/yyyy>[ through|thru|to|until <mm/dd/yyyy>]] - remove the schedule entries for dates
#  hubot display|show|export the on-call schdeule [for|from <mm/dd/yyyy>[ through|thru|to|until <mm/dd/yyyy>]] - list the on-call schedule in a csv text blob
#  hubot display|show|export the current|next|today's|tomorrow's on-call schedule - list a single on-call schedule
#  hubot audit the on-call schedule [for|from <mm/dd/yyyy>[ through|thru|to|until <mm/dd/yyyy>]] - show audit entries for schedules in the date range
#  hubot load on-call schedule\n<CSV data> - bulk set schedules from CSV of the form <mm/dd/yyyy>,<name>[,<name>]\n - Note: does not remove any intermediate entries
#  hubot check|fix|repair the on-call schedule index
#  hubot who is on-call - list who is currently on-call
#  hubot show me on-call - list who is currently on-call
#  hubot put <name>[ ,<name>...] on-call - add people to the current on-call list
#  hubot remove <name>[ ,<name>...] from on-call - remove people from the current on-call list
#  hubot reset on-call - remove all names from the current on-call list, then apply the current schedule
#
# Author:
#   Those fine folks at Basho Technologies
#

util = require 'util'
cronJob = require('cron').CronJob
HttpClient = require 'scoped-http-client'
_ = require 'underscore'

onCall =
  testing: false
  url: process.env.ESCALATION_URL
  user: process.env.ESCALATION_USER
  password: process.env.ESCALATION_PASSWORD
  http: () ->
    HttpClient.create(@url, headers: { 'Authorization': 'Basic ' + new Buffer("#{@user}:#{@password}").toString('base64') }).path("/on-call")
  list: (msg) ->
    @http().get() (err, res, body) ->
      if err
        msg.reply "Sorry, I couldn't get the on-call list: #{util.inspect(err)}"
      else
        msg.reply ["Here's who's on-call:", body.trim().split("\n").join(", ")].join(" ")
  modify: (msg, people, op) ->
    http = @http()
    http.get() (err,res,body) =>
      if err
        msg.reply "Sorry, I couldn't get the on-call list: #{util.inspect(err)}"
      else
        newOnCall = op(body.trim().split("\n"), people)
        #don't actually set the on-call list while testing
        if @testing
          msg.reply "If I were allowed to set the on-call list, I would set it to: #{newOnCall.toString()}"
        else
          http.header('Content-Type', 'text/plain').put(newOnCall.join("\n")) (err, res, body) ->
            if err
              msg.reply "Sorry, I couldn't set the new on-call list to #{newOnCall.join(', ')}: #{util.inspect(err)}"
            else
              msg.reply "Ok, I updated the on-call list"
              http.get() (err,res,body) =>
                if not err
                  diffs = _.difference(newOnCall,body.trim().split("\n"))
                  if diffs.length > 0
                    msg.reply "Failed to add: #{diffs.toString()}"
                  diffs = _.difference(body.trim().split("\n"),newOnCall)
                  if diffs.length > 0
                    msg.reply "Failed to remove: #{diffs.toString()}"
                onCall.list(msg)
                 

# structure of schedule data in robot.brain
# ocs-index : [onCasllScheduleIndexEntry]
# ocs-<epoch> : onCallScheduleEntry
# ocs-lastpurge : auditEntry
# onCallScheduleIndexEntry :  {date: epoch,
#                              deleted: boolean,
#                              lastupdated: epoch,
#                              audit: [auditEntry]}
# auditEntry: {date: epoch,
#              user: hipchetUser,
#              action: string}
# onCallScheduleEntry : {date: string(mm/dd/yyyy),
#                        people: [string]}
# hipchatUser : { id: string,
#                 name: string,
#                 room: string }

  schedule:

    cronschedule: process.env.ESCALATION_CRONSCHEDULE ? "0 0 9 * * *" # 9am daily
    #cronschedule: "0 */5 * * * *" #every 5 minute

    newAuditEntry: (msg, action) ->
      dNow = new Date
      usr =
        name: msg.message.user["name"] ? "<name missing>"
        id: msg.message.user["jid"] ? "<id missing>"
        room: msg.message["room"] ? "<room missing>"
      audit =
        action: action
        date: dNow.getTime()
        user: usr
      return audit


    newIndexEntry: (msg, dt, deleted, action) ->
      dNow = new Date
      idx =
        date: @makeDate(dt)
        deleted: deleted ? false
        lastupdated: dNow.getTime()
        audit: [
          @newAuditEntry(msg, if action then action else "create")
          ]

    newScheduleEntry: (date, people) ->
      sched =
        date: @epoch2Date(@makeDate(date))
        people: if people then people else []
      return sched

    getIndex: (msg,deletedok) ->
      i = msg.robot.brain.get 'ocs-index'
      if i instanceof Array
        if deletedok
            return i
        else
            return i.filter (entry) -> not entry["deleted"]
      else
        return []

    getIndexRange: (msg, fromDate, toDate, deletedok) ->
      idx = @getIndex(msg, deletedok)
      if (fromDate or toDate)
        start = @makeDate(fromDate)
        stop = @makeDate(toDate)
        start = stop if not start? or isNaN start
        stop = start if not stop? or isNaN stop
        idx = idx.filter (entry) -> (entry["date"] >= start) and (entry["date"] <= stop)
      if fromDate? and idx? and (idx.length > 0) and (idx[0]['date'] != @makeDate(fromDate))
        i = @getIndexEntry(msg, fromDate)
        if i and i['date']
          idx = idx.reverse()
          idx.push i
          idx.reverse()
      return idx

    saveIndex: (msg, index) ->
      if index instanceof Array
        msg.robot.brain.set 'ocs-index', index
      else 
        msg.robot.logger.info "Invalid index submitted: #{util.inspect index}"

    insertIndex: (msg,idx) ->
      oIndex = @getIndex(msg)
      if idx["date"]
        index = oIndex.filter (entry) -> entry['date'] != idx['date']
        index.push idx
        index.sort (a, b) ->
          return -1 if (a["date"] < b["date"])
          return 1 if (a["date"] > b["date"])
          return 0
        @saveIndex(msg,index)

    checkIndex: (msg) ->
      #fake message to identify the repair process as actor
      msg.robot.logger.info "Check/Repair index #{util.inspect msg.message.user}"
      fakemsg =
        robot: msg.robot
        message:
          user:
            name: "Auto Repair Process"
            id: "0"
            room: "backroom"
      ocsKeys = Object.keys(msg.robot.brain.data._private)
      index = @getIndex(msg, true)
      response = ["Checking index entries:"]
      for i in index
        if i
          if i['date']
            if not msg.robot.brain.get "ocs-#{i['date']}"
              i['deleted'] = true
              i['audit'].push @newAuditEntry(fakemsg, "delete")
              @insertIndex(msg, i)
              response.push "Index for #{@epoch2Date(i['date'])} points to non-existent schedule entry, deleteing"
          else
            i['deleted'] = true
            i['audit'].push @newAuditEntry(fakemsg, "delete")
            @insertIndex(msg,i)
            response.push "Index entry missing date, deleting:\n #{util.inspect i}"
        else
          response.push "Deleting invalid index entry #{util.inspect i}"
          @purgeIndex(msg, i)
      response.push "Checking schedule entries"
      #get a fresh index with the fixes so far applied
      index = @getIndex(msg, true)
      for k in ocsKeys
        m = /^ocs-([0-9]*)$/.exec k
        if m
          sched = msg.robot.brain.get k
          if sched and sched['date']
            sdt = @makeDate(sched['date'])
            kdt = @makeDate(m[1])
            if sdt != kdt
              response.push "Schedule entry date '#{sched['date']}' does not match key '#{k}', deleting"
              idx = @getIndexEntry(msg, m[1], true)
              if idx?
                @deleteEntryByIndex(msg, idx)
              else
                msg.robot.brain.remove k
            else
              idx = @getIndexEntry(msg, m[1], true)
              if idx and idx['date'] == @makeDate(m[1])
                if idx['deleted']
                    response.push "Index entry for schedule date '#{sched['date']}' marked deleted, undeleting"
                    idx['deleted'] = false
                    idx['audit'].push @newAuditEntry(fakemsg, 'undelete')
                    @insertIndex(msg,idx)
              else
                response.push "Index missing for schedule date '#{sched['date']}(#{@makeDate(sched['date'])}), creating"
                @insertIndex(msg, @newIndexEntry(fakemsg,sched['date']))
          else
            response.push "Deleting invalid schedule entry #{k}"
            msg.robot.brain.remove k
            idx = @getIndexEntry(msg, m[1])
            if idx
                idx['deleted'] = true
                idx['audit'].push @newAuditEntry(fakemsg, 'delete')
                @insertIndex(msg, idx)
      response.push "Check complete"
      msg.reply response.join("\n")

    purgeIndex: (msg, idx) ->
      index = @getIndex(msg,true)
      if idx and idx["date"]
        msg.robot.brain.remove "ocs-#{idx['date']}"
      @saveIndex  msg, _.difference(index,[idx])

    makeDate: (str) ->
      if not str instanceof String
        return str
      if /today/i.test str
        dt = (new Date).getTime()
      else
        if /tomorrow/i.test str
          dt = (new Date).getTime() + 86400000
        else
          dt = Date.parse(str)
      if isNaN dt
        dt = parseInt(str)
      return dt

    epoch2DateTime: (int) ->
      i = int
      if i instanceof String
        i = parseInt(int)
      d = new Date(i)
      return "#{d.getMonth() + 1}/#{d.getDate()}/#{d.getFullYear()} #{d.getHours()}:#{if d.getMinutes() < 10 then '0' else ''}#{d.getMinutes()}"

    epoch2Date: (int) ->
      i = int
      if i instanceof String
        i = parseInt(int)
      d = new Date(i)
      return "#{d.getMonth() + 1}/#{d.getDate()}/#{d.getFullYear()}"

    getIndexEntry: (msg, date, deletedok) ->
      index = @getIndex(msg)
      d = @makeDate(date)
      if deletedok
        aIndex = index.filter (entry) -> entry["date"] <= d
      else
        aIndex = index.filter (entry) -> (entry["date"] <= d and not entry["deleted"])
      if aIndex.length > 0
        return aIndex[aIndex.length-1]
      else
        return null

    getNextIndexEntry: (msg, date, deletedok) ->
      index = @getIndex(msg)
      d = @makeDate(date)
      if deletedok
        aIndex = index.filter (entry) -> entry["date"] > d
      else
        aIndex = index.filter (entry) -> (entry["date"] > d and not entry["deleted"])
      if aIndex.length > 0
        return aIndex[0]
      else
        return null

    getEntryByIndex: (msg, idx) ->
      if idx["date"]
        msg.robot.brain.get 'ocs-' + idx["date"]

    getEntry: (msg, date) ->
      idx = @getIndexEntry(msg,date)
      @getEntryByIndex(msg, idx)

    createEntry: (msg, date, ppl, overwrite) ->
      dt = @makeDate(date)
      current = @getIndexEntry(msg, dt, true)
      dNow = new Date
      epochnow = dNow.getTime()
      sched = @newScheduleEntry(dt, ppl)
      if not current or (current == []) or (current['date'] != dt)
       idx = @newIndexEntry(msg, dt, false, "create - #{ppl}")
       @saveEntry(msg, idx, sched)
      else
        if overwrite then @deleteEntryByIndex(msg, current)
        if current['deleted']
            current['deleted'] = false
            current['audit'].push @newAuditEntry(msg, "create - #{ppl}")
            current['lastupdated'] = epochnow
            @saveEntry(msg,current,sched)
        else
          msg.reply "Schedule entry already exists for #{date}"

    saveEntry: (msg, idx, entry) ->
      iDate = @epoch2Date(@makeDate(idx["date"]))
      eDate = @epoch2Date(@makeDate(entry["date"]))
      if iDate != eDate
        return {"error":"index and entry don't match\nIndex: #{util.inspect idx}\nEntry: #{util.inspect entry}"}
      current = @getIndexEntry(msg, idx["date"], true)
      if current and current['date'] and (current['date'] == idx['date'])
        idx["audit"] = _.union(current["audit"],idx["audit"])
      @insertIndex(msg,idx)
      msg.robot.brain.set "ocs-#{idx['date']}", entry
      return {"success":"Saved schedule entry for #{entry['date']}"}

    deleteEntryByIndex: (msg,idx) ->
      idx["deleted"] = true
      timenow = new Date
      idx["audit"].push @newAuditEntry(msg, "delete")
      idx["lastupdated"] = timenow.getTime()
      msg.robot.brain.remove "ocs-#{idx['date']}"
      @insertIndex(msg, idx)

    prettyEntry: (sched) ->
      if sched["date"]
        return "#{sched['date']},#{sched['people'].toString() if sched['people'] instanceof Array}"

    #import: (msg) ->

    fromCSV: (msg) ->
      msg.robot.logger.info "Upload from CSV"
      lines = "#{msg.message.text}".split("\n")
      response = []
      for line in lines[1..]
        fields = line.split(",")
        dt = @makeDate(fields[0])
        if not isNaN dt
          response.push line
          msg.robot.logger.info "Upload entry #{line}"
          response.push util.inspect @createEntry(msg, dt, fields[1..], true)
      msg.reply response.join("\n")

    # return the audit history entries for the requestd range
    audit: (msg, fromDate, toDate) ->
      idx = @getIndexRange(msg, fromDate, toDate, true)
      response = ["Audit entries:"]
      lastPurge = msg.robot.brain.get 'ocs-lastpurge'
      if lastPurge and lastPurge["date"]
        response.push "Schedule last purged #{@epoch2DateTime(lastPurge['date'])} by #{util.inspect lastPurge['user']}"
      for i in idx
        try
          if i["deleted"]
            item = ["Deleted Entry for #{@epoch2Date(i['date'])}"]
          else
            item = [@prettyEntry(@getEntryByIndex(msg,i))]
          for a in i["audit"]
            u = a['user']
            item.push "\t#{@epoch2DateTime(a['date'])}: #{a['action']} by #{if u['name'] then u['name'] else 'name missing'}(#{if u['id'] then u['id'] else '<id missing>'}) #{if u['room'] then 'in ' + u['room'] else ''}"
          response.push item.join("\n")
        catch error
          response.push "Error #{util.inspect error} with index #{util.inspect idx}"
      msg.reply response.join("\n")

    # return the requested block of entries in CSV format
    toCSV: (msg,fromDate,toDate) ->
      idx = @getIndexRange(msg,fromDate,toDate,false)
      response = ["Here is the on-call schedule"]
      if idx.length < 1
        i = @getIndexEntry(msg, fromDate)
        if i and i['date']
          response.push "#{@prettyEntry(@getEntryByIndex(msg,i))}"
        else
          response.push "Schedule empty!"
      for a in idx
        if a? and a['date'] 
          response.push @prettyEntry(@getEntryByIndex(msg,a)) 
      msg.reply response.join("\n")

    #failsafe to remove all traces of on-call schedule from robot.brain in the event of horrific failure
    purge: (msg) ->
      if @confirm(msg, "Please repeat command to confirm you want to purge everything",true)
        (@purgeIndex(msg,i) for i in @getIndex(msg,true))
        (msg.robot.brain.remove k for k in Object.keys(msg.robot.brain.data._private).filter (key) -> key.match(/^ocs-/))
        if @getIndex(msg,true).length == 0
          msg.reply "Purge successful"
        else
          msg.reply "Remaining index: #{util.inspect @getIndex(msg,true)}"
        dt = new Date
        purgeAudit =
          date: dt.getTime()
          user: msg.message.user
          action: "Purge"
        msg.robot.brain.set 'ocs-lastpurge', purgeAudit

    # delete schedule entries, but keep the audit history
    clear: (msg, fromDate, toDate) ->
      start = @makeDate(fromDate)
      end = @makeDate(toDate)
      if (not (start or end)) and (not @confirm(msg,"Please repeat command to confirm you want to delete the entire on-call schedule"))
          return
      idx = @getIndexRange(msg,fromDate,toDate,false)
      response = []
      if idx.length > 0
        response.push "Deleted the following schedule entries:"
        for a in idx
          response.push @prettyEntry(@getEntryByIndex(msg,a))
          @deleteEntryByIndex(msg,a)
        msg.reply response.join("\n")
      else
        msg.reply "I couldn't find any schedule entries between #{fromDate} and #{toDate}"

    cronApplySchedule: (msg) ->
      if @cronjob then return
      that = this
      msg.robot.logger.info "Create cronjob '#{@cronschedule} onCall.schedule.applySchedule(msg)'"
      @cronjob = new cronJob(@cronschedule, ->
        that.applySchedule(msg)
      )
      @cronjob.start()

    # locate the schedule entry for today and change who is on-call
    applySchedule: (msg) ->
      dt = new Date
      epoch = dt.getTime()
      oldppl = []
      idx = @getIndexEntry msg, epoch, false
      if (not idx) or (idx == [])
        msg.reply "Error: Cannot locate an on-call schedule entry that covers #{@epoch2Date(epoch)}!"
        return
      sched = @getEntryByIndex(msg, idx)
      msg.send "Updating to the on-call schedule for #{@epoch2Date(epoch)}"
      lastapply = msg.robot.brain.get 'ocs-lastapplied'
      if not lastapply? or lastapply < idx["date"]
        oldidx = @getIndexEntry msg, idx["date"] - 1000, false
        if oldidx
          osched = @getEntryByIndex(msg, oldidx)
          msg.send "Old schedule: #{@prettyEntry osched}"
          oldppl = _.difference(osched["people"],sched["people"])
      if lastapply? and lastapply == idx["date"]
        msg.send "Re-applying schedule #{sched['date']}"
      else
        msg.send "New schedule: #{@prettyEntry sched}"
      msg.robot.logger.info "Updating on-call Removing:[#{oldppl.toString()}] Adding:[#{sched['people'].toString()}]"
      if oldppl? and oldppl.length > 0
        msg.send "Removing #{oldppl.toString()}, Adding #{sched['people'].toString()}"
        onCall.modify(msg,oldppl, _.difference)
        delaymod = () ->
          onCall.modify(msg, sched["people"], _.union)
        setTimeout delaymod, 5000
      else
        msg.send "Adding #{sched['people'].toString()}"
        onCall.modify(msg, sched["people"], _.union)
      msg.robot.brain.set 'ocs-lastapplied', idx["date"]

    # modify a range of schedule entries
    # adds an entry at the beginning of the range if necessary
    modify: (msg, people, fromDate, toDate, op) ->
      dFrom = @makeDate(fromDate)
      dTo = @makeDate(toDate)
      if toDate
        if dFrom > dTo then return
      else
        dTo = dFrom
      dNow = new Date
      idx = @getIndexRange(msg, dFrom, dTo, false)
      response = []
      fromIdx = idx.filter (entry) -> entry['date'] == dFrom
      if fromIdx.length == 0
        # there's no entry for the first date in the range
        # figure out if this change is different than the previous entry
        prev = @getIndexEntry(msg, dFrom)
        prevppl = []
        if prev and prev['date']
            prevsched = @getEntryByIndex(msg, prev)
            if prevsched and prevsched['people'] then prevppl = prevsched['people']
        newppl = op(prevppl, people)
        newdiff = _.union(_.difference(newppl, prevppl), _.difference(prevppl, newppl))
        # only add a new entry if the list of names changes
        if newdiff.length != 0
          response.push @createEntry(msg, dFrom, newppl)
          response.push {"success":"Created new schedule entry for #{@epoch2Date(dFrom)}"}
      #update every pre-existing entry in the date range
      for i in idx
        sched = @getEntryByIndex(msg, i)
        newlist = op(sched["people"], people)
        i["audit"].push @newAuditEntry(msg, "modify - #{newlist.toString}")
        if sched
            sched["people"] = newlist
            response.push @saveEntry(msg, i, sched)
        else
            response.push {"error":"Could not find schedule entry corresponding to index #{util.inspect idx}"}
      errors = (s["error"] for s in response when s["error"])
      success = (s["success"] for s in response when s["success"])
      msg.reply "#{errors.join('\n')}\n#{success.join('\n')}"

    #startup initialization
    bootstrap: (robot) ->
      if not robot
        process.stdout.write "No robot, cannot initialize. Bad human! Bad!"
        return
      dt = new Date
      epoch = dt.getTime()
      fakemsg=
        robot: robot
        reply: (text) ->
          @robot.messageRoom process.env.ESCALATION_NOTIFICATIONROOM ? "Shell", text
        send: (text) ->
          @robot.messageRoom process.env.ESCALATION_NOTIFICATIONROOM ? "Shell", text
      # prune old entries, keeping only 30 expired schedules
      idx = @getIndexEntry(fakemsg,epoch)
      if idx and idx['date']
        cutoff = idx['date'] = 86400000 # cutoff 24 hours prior to the current schedule entry
        index = @getIndexRange(fakemsg,0,idx['date'] - 1000,true)
        while index.length > 30
          purgeIndex(index[0])
          index = index[1..]
      @cronApplySchedule(fakemsg)

    # confirmation - on the first pass, store an entry in the brain
    # ignore confirmation for 5 seconds to accomodate Hipchate duplicating messages
    # ignore confirmation entries older than 5 minutes
    confirm: (msg, note) ->
      userid = msg.message.user.jid
      room = msg.message.room
      cmd = msg.message.text
      confmsg = msg.robot.brain.get "ocs-confirm-#{userid}-#{room}"
      conftime = new Date
      conftime = conftime.getTime()
      haveMatch = (confmsg and (note == confmsg["msg"]) and (cmd == confmsg["cmd"]))
      # confirmation must match user id, room, message(user command), note(request confirmation), and be within 5-300 seconds of the initial command
      if haveMatch and (confmsg["time"] + 5000 <= conftime) and ((confmsg["time"] + 300000) >= conftime)
          msg.robot.brain.remove "ocs-confirm-#{userid}-#{room}"
          return true
      else
        msg.reply note
        if not haveMatch or (haveMatch and ((confmsg["time"] + 300000) < conftime))
            msg.robot.brain.set "ocs-confirm-#{userid}-#{room}", {"msg":note, "time": conftime, "cmd":cmd}
        return false

module.exports = (robot) ->
  onCall.schedule.bootstrap(robot)

  # This is extremely dangerous, but very useful while debugging
  # It will permit anyone who can talk to the robot to execute
  # arbitrary javascript
  robot.respond /inspect (.*)/, (msg) ->
    eval "obj=#{msg.match[1]}"
    msg.reply "#{util.inspect obj}"

  robot.respond /purge \s*(?:the )?on[- ]call schedule$/, (msg) ->
    onCall.schedule.purge(msg)

  robot.respond /(check|repair|fix|unfuck) (?:the )?on[- ]call schedule index\s*/, (msg) ->
    onCall.schedule.checkIndex(msg)

  robot.respond /load \s*on[- ]call \s*schedule\s*\n?(.*)/, (msg) ->
    onCall.schedule.fromCSV(msg)

  robot.respond /apply \s*(?:the )?on[- ]call \s*schedule\s*/, (msg) ->
    onCall.schedule.applySchedule(msg)

  robot.respond /set (?:the )?\s*on[- ]call \s*schedule (?:for |on )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d) \s*to \s*(.*)/, (msg) ->
    people = msg.match[2].split(",")
    msg.robot.logger.info "Create schedule for #{msg.match[1]} - #{msg.match[2]}"
    msg.reply util.inspect onCall.schedule.createEntry(msg, msg.match[1], people, true)

  robot.respond /add \s*(.*) \s*to \s*(?:the )?\s*on[- ]call \s*schedule \s*(?:for |on |from )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)\s*(?:until |thru |through |to )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*/i, (msg) ->
    people = msg.match[1].split(",")
    msg.robot.logger.info "Put #{people.toString()} on-call for #{msg.match[2]} #{msg.match[3]}"
    onCall.schedule.modify(msg,people,msg.match[2],msg.match[3],_.union)

  robot.respond /unschedule \s*(.*) \s*from \s*on[- ]call \s*(?:for |on |from )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)\s*(?:until |thru |through |to )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*/i, (msg) ->
    people = msg.match[1].split(",")
    msg.robot.logger.info "Remove #{people.toString()} from on-call for #{msg.match[2]}"
    onCall.schedule.modify(msg,people,msg.match[2],msg.match[3],_.difference)

#  robot.respond /import\s*on[- ]call\s*schedule\s*from\s*(.+)/i, (msg) ->
#    msg.robot.logger.info "Import schedule from " + msg.match[1]

  robot.respond /clear \s*(?:the )?\s*on[- ]call \s*schedule\s*(?:for |on |from )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*(?:until |to |through |thru )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*/i, (msg) ->
    msg.robot.logger.info "Clear the on-call schedule from #{msg.match[1]} to #{msg.match[2]}"
    onCall.schedule.clear(msg, msg.match[1], msg.match[2])

  robot.respond /(?:export|display|show) (?:the)?\s*(next|current|tomorrow[']?s?|today[']?s?) \s*on[- ]call \s*schedule\s*/i, (msg) ->
    today = new Date
    if /next|tomorrow/i.test msg.match[1]
      idx = onCall.schedule.getNextIndexEntry(msg, today.getTime(), false)
    else
      idx = onCall.schedule.getIndexEntry(msg, today.getTime(), false)
    if idx? and idx['date']
      onCall.schedule.toCSV(msg, idx['date'])
    else
      msg.reply "No more schedules found"

  robot.respond /(?:export|display|show) \s*(?:the )?\s*on[- ]call \s*schedule\s*(?:for |on |from )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*(?:until |to |through |thru )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*/i, (msg) ->
    onCall.schedule.toCSV(msg, msg.match[1], msg.match[2])

  robot.respond /audit \s*(?:the )?\s*on[- ]call \s*schedule\s*(?:for |on |from )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*(?:through |thru |to |until )?\s*(today|tomorrow|\d+\/\d+\/\d\d\d\d)?\s*/i, (msg) ->
    msg.robot.logger.info "Display audit records #{util.inspect msg.message.user}"
    onCall.schedule.audit(msg,msg.match[1],msg.match[2])

  robot.respond /(?:who is|show me) on[- ]call\??/i, (msg) ->
    msg.robot.logger.info "Checking on-call."
    onCall.list(msg)

  robot.respond /put (.*) on[- ]call\s*/i, (msg) ->
    people = msg.match[1].trim().split(/\s*,\s*/)
    msg.robot.logger.info "Adding #{util.inspect people} to on-call list"
    onCall.modify(msg, people, _.union)

  robot.respond  /remove (.*) from on[- ]call\s*/i, (msg) ->
    people = msg.match[1].trim().split(/\s*,\s*/)
    msg.robot.logger.info "Removing #{util.inspect people} from on-call list"
    onCall.modify(msg, people, _.difference)

  robot.respond  /reset on[- ]call\s*/i, (msg) ->
    msg.robot.logger.info "Resetting the on-call list"
    onCall.modify(msg, [""], _.intersection)
    onCall.schedule.applySchedule(msg)

