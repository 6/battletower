JST['teambuilder'] = thermos.template (locals) ->
  @div '.builder_team', ->
    locals.pokemon.each (pokemon, i) =>
      klass = '.builder_pokemon'
      klass += '.selected'  if i == locals.selected
      @div klass, pokemon.name
    # @div '.builder_add_pokemon', '+'
  @div '.builder_detail', JST['teambuilder_detail']
