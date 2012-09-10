{_} = require 'underscore'
{FakeRNG} = require './rng'
{Pokemon} = require './pokemon'
{Player} = require './player'
{Team} = require './team'

class @Battle
  # TODO: let Battle serialize these.
  {moves, MoveData, species, PokemonData} = require '../data/bw'

  constructor: (@id, attributes = {}) ->
    # Number of pokemon on each side of the field
    @numActive = 1

    # Stores the current turn of the battle
    @turn = 0

    # Stores the actions each player is about to make
    # Keyed by player.id
    @playerActions = {}

    # Stores the current requests for moves. Keyed by player.id
    @requests = {}

    # Stores queue of players that need to move.
    @requestQueue = []

    # Creates a RNG for this battle.
    @rng = new FakeRNG()

    # Maps clientId -> object
    @objectHash = {}

    # Current battle weather.
    @weather = "None"

    # Buffer of messages to send to each client.
    @buffer = []

    # Hash of players partaking in the battle.
    @players = {}

    for object in attributes.players
      {player, team} = object
      @players[player.id] = new Player(player, new Team(team, @numActive))

    # if replacing = true, continueTurn won't execute end of turn effects
    @replacing = false

    @startNewTurn()

  getPlayer: (id) =>
    @players[id]

  getTeam: (id) =>
    @getPlayer(id).team

  # Returns all opponents of a given player. In a 1v1 it returns
  # an array with only one opponent.
  getOpponents: (id) =>
    opponents = []
    for playerId, player of @players
      opponents.push(player)  if id != playerId
    opponents

  # Returns all opponent pokemon of a given player.
  #
  # id - The player who's opponent's pokemon we want to retrieve
  # max (optional) - The maximum amount of pokemon per opponent.
  #
  getOpponentPokemon: (id, max) =>
    opponents = @getOpponents(id)
    teams = (opponent.team.all()  for opponent in opponents)
    teams = (team.slice(0, max)   for team in teams)  if max?
    _.flatten(teams)

  # Returns all active pokemon on the field belonging to both players.
  # Active pokemon include fainted pokemon that have not been switched out.
  getActivePokemon: =>
    pokemon = []
    for id, player of @players
      pokemon.push(player.team.getActivePokemon()...)
    pokemon

  # Add `string` to a buffer that will be sent to each client.
  message: (string) =>
    @buffer.push(string)

  clearMessages: =>
    while @buffer.length > 0
      @buffer.pop()

  # Sends to each player the battle messages that have been queued up
  # TODO: It should be sent to spectators as well
  sendMessages: =>
    @message 'The turn continued.'
    for id, player of @players
      player.updateChat('SERVER', @buffer.join("<br>"))
    @clearMessages()

  hasWeather: (weatherName) =>
    weather = (if @hasWeatherCancelAbilityOnField() then "None" else @weather)
    weatherName == weather

  hasWeatherCancelAbilityOnField: =>
    _.any @getActivePokemon(), (pokemon) ->
      pokemon.hasAbility('Air Lock') || pokemon.hasAbility('Cloud Nine')

  startNewTurn: =>
    @turn++

    # Send appropriate requests to players
    for id, player of @players
      poke_moves = player.team.at(0).moves
      switches = player.team.getAlivePokemon().map((p) -> p.name)
      @requestAction(player, moves: poke_moves, switches: switches)

    @replacing = false

  # Tells the battle to continue the turn. This is called once all requests
  # have been submitted and the battle is ready to continue. Once
  # there are no more requests the next turn begins.
  continueTurn: =>
    skipIds = []
    for id in @orderIds()
      continue  if id in skipIds

      switch @getAction(id).type
        when 'switch' then @performSwitch(id)
        when 'move'   then @performMove(id)

      faintedIds = @requestFaintedReplacements()
      skipIds.push(faintedIds...)

      # Clean up playerActions hash.
      delete @playerActions[id]

    unless @replacing
      if @isOver()
        @sendMessages()
        @endBattle()
        return
      
      # TODO: Skip endTurn for pokemon that are fainted?
      pokemon.endTurn() for pokemon in @getActivePokemon()

      # A pokemon may have fainted during endTurn effects
      @requestFaintedReplacements()

      # TODO: Test if its over again

      if @requestQueue.length > 0
        {player, validActions} = @requestQueue.shift()
        @requestAction(player, validActions)
        
      @replacing = true

    # Send a message to each player.
    @sendMessages()

    # If no replacements are left, then continue the turn
    if @areAllRequestsCompleted() then @startNewTurn()

  endBattle: =>
    winner = @getWinner()
    for id, player of @players
      player.updateChat('SERVER', "#{winner.username} won!")
      player.updateChat('SERVER', "END BATTLE.")

  getWinner: =>
    winner = null
    length = 0
    for id, player of @players
      newLength = player.team.getAlivePokemon().length
      if newLength > length
        length = newLength
        winner = player
    player

  isOver: =>
    _.any(@players, (player) -> player.team.getAlivePokemon().length == 0)

  # Tells the player to execute a certain move by name. The move is added
  # to the list of player actions, which are executed once the turn continues.
  # TODO: Make this compatible with double battles by using the slot.
  #
  # player - the player object that will execute the move
  # moveName - the name of the move to execute
  #
  makeMove: (player, moveName) =>
    moveName = moveName.toLowerCase().replace(/\s+/g, '-')
    # TODO: Fail if move not in moves
    # TODO: Fail if move not in player pokemon's moves
    return  if moveName not of MoveData

    # Store the move name that this player wants to make.
    @playerActions[player.id] =
      type: 'move'
      name: moveName

    delete @requests[player.id]

    # Continue the turn if each player has moved.
    if @areAllRequestsCompleted() then @continueTurn()

  # Tells the player to switch with a certain pokemon specified by position.
  # The switch is added to the list of player actions, which are executed
  # once the turn continues.
  # TODO: Make this compatible with double battles by using the slot.
  #
  # player - the player object that will execute the move
  # toPosition - the index of the pokemon to switch to
  #
  makeSwitch: (player, toPosition) =>
    # TODO: Fail harder if pokemon not in team
    # TODO: Add more cases of invalid indices (such as fainted poke or activePokemon)
    pokemon = @getTeam(player.id).at(toPosition)
    unless pokemon
      console.log "#{player.username} made an invalid switch to position #{toPosition}."
      return

    # Record the switch
    @playerActions[player.id] =
      type: 'switch'
      to: toPosition

    delete @requests[player.id]

    # Continue the turn if each player has moved.
    if @areAllRequestsCompleted() then @continueTurn()

  # An alternate version of Battle.makeSwitch which takes the name of a pokemon
  # to switch to instead of the position. Useful for tests.
  # TODO: Test
  makeSwitchByName: (player, toPokemon) =>
    team = @getTeam(player.id)
    index = team.indexOf(toPokemon)

    @makeSwitch(player, index)

  getAction: (clientId) =>
    @playerActions[clientId]

  requestAction: (player, validActions) =>
    # TODO: Delegate this kind of logic to the Player class.
    @requests[player.id] = validActions
    player.requestAction(@id, validActions)

  # Returns true if all requests have been completed. False otherwise.
  areAllRequestsCompleted: =>
    requests = 0
    requests += 1  for id of @requests
    requests == 0

  # If a Pokemon faints, add the player to the action queue.
  requestFaintedReplacements: =>
    ids = []
    for id, player of @players
      team = player.team
      fainted = team.getActiveFaintedPokemon()
      if fainted.length > 0
        ids.push(id)
        for pokemon in fainted
          @message "#{player.username}'s #{pokemon.name} fainted!"
        validActions = {switches: team.getAliveBenchedPokemon()}
        @requestQueue.push({player, validActions})
    ids

  orderIds: =>
    ids = (id  for id of @playerActions)
    ordered = []
    for id in ids
      action = @getAction(id)
      priority = @actionPriority(action)
      pokemon = @getTeam(id).at(0)
      ordered.push({id, priority, pokemon})
    ordered.sort(@orderComparator)
    ordered.map((o) -> o.id)

  orderComparator: (a, b) =>
    diff = b.priority - a.priority
    if diff == 0
      diff = b.pokemon.stat('speed') - a.pokemon.stat('speed')
      if diff == 0
        diff = (if @rng.next() < .5 then -1 else 1)
    diff

  actionPriority: (action) =>
    switch action.type
      when 'switch' then 5
      # TODO: Apply priority callbacks
      when 'move'   then MoveData[action.name].priority

  # Executed by @continueTurn
  performSwitch: (id) =>
    player = @getPlayer(id)
    action = @getAction(id)
    team = @getTeam(id)
    
    team.at(0).switchOut()
    @message "#{player.username} withdrew #{team.at(0).name}!"
    team.switch(0, action.to)
    # TODO: Implement and call pokemon.activate() or pokemon.switchIn()
    @message "#{player.username} sent out #{team.at(0).name}!"
    
    # TODO: Hacky.
    player.emit? 'switch pokemon', 0, action.to

  # Executed by @continueTurn
  performMove: (id) =>
    player = @getPlayer(id)
    action = @getAction(id)
    pokemon = @getTeam(id).at(0)
    defenders = @getOpponentPokemon(id, @numActive)
    move = moves[action.name]

    @message "#{player.username}'s #{pokemon.name} used #{move.name}!"

    # TODO: Execute any before move events
    damage = move.execute(this, pokemon, defenders)
    # TODO: Execute any after move events
