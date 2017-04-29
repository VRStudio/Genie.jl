module Migration

using Genie, Database, FileTemplates, Millboard, Configuration, Logger

type DatabaseMigration # todo: rename the "migration_" prefix for the fields
  migration_hash::String
  migration_file_name::String
  migration_module_name::String
end


"""
    new(cmd_args::Dict{String,Any}, config::Configuration.Settings) :: Void

Creates a new default migration file and persists it to disk in the configured Genie migrations folder.
"""
function new(cmd_args::Dict{String,Any}, config::Configuration.Settings) :: Void
  mfn = migration_file_name(cmd_args, config)

  if ispath(mfn)
    error("Migration file already exists")
  end

  f = open(mfn, "w")
  write(f, FileTemplates.new_database_migration(migration_module_name(cmd_args["migration:new"])))
  close(f)

  Logger.log("New migration created at $mfn")

  nothing
end


"""
    migration_hash() :: String

Computes a unique hash for a migration identifier.
"""
function migration_hash() :: String
  m = match(r"(\d*)-(\d*)-(\d*)T(\d*):(\d*):(\d*)\.(\d*)", "$(Dates.unix2datetime(time()))")

  join(m.captures)
end


"""
    migration_file_name(cmd_args::Dict{String,Any}, config::Configuration.Settings) :: String

Computes the name of a new migration file.
"""
function migration_file_name(cmd_args::Dict{String,Any}, config::Configuration.Settings) :: String
  joinpath(config.db_migrations_folder, migration_hash() * "_" * cmd_args["migration:new"] * ".jl")
end


"""
    migration_module_name(underscored_migration_name::String) :: String

Computes the name of the module of the migration based on the input from the user (migration name).
"""
function migration_module_name(underscored_migration_name::String) :: String
  mapreduce( x -> ucfirst(x), *, split(replace(underscored_migration_name, ".jl", ""), "_") )
end


"""
    last_up() :: Void

Migrates up the last migration.
"""
function last_up() :: Void
  run_migration(last_migration(), :up)
end


"""
    last_down() :: Void

Migrates down the last migration.
"""
function last_down() :: Void
  run_migration(last_migration(), :down)
end


"""
    up_by_module_name(migration_module_name::String; force::Bool = false) :: Void

Runs up the migration corresponding to `migration_module_name`.
"""
function up_by_module_name(migration_module_name::String; force::Bool = false) :: Void
  migration = migration_by_module_name(migration_module_name)
  if ! isnull(migration)
    run_migration(Base.get(migration), :up, force = force)
  else
    error("Migration $migration_module_name not found")
  end
end


"""
    down_by_module_name(migration_module_name::String; force::Bool = false) :: Void

Runs down the migration corresponding to `migration_module_name`.
"""
function down_by_module_name(migration_module_name::String; force::Bool = false) :: Void
  migration = migration_by_module_name(migration_module_name)
  if ! isnull(migration)
    run_migration(Base.get(migration), :down, force = force)
  else
    error("Migration $migration_module_name not found")
  end
end


"""
    migration_by_module_name(migration_module_name::String) :: Nullable{DatabaseMigration}

Computes the migration that corresponds to `migration_module_name`.
"""
function migration_by_module_name(migration_module_name::String) :: Nullable{DatabaseMigration}
  ids, migrations = all_migrations()
  for id in ids
    migration = migrations[id]
    if migration.migration_module_name == migration_module_name
      return Nullable(migration)
    end
  end

  Nullable()
end


"""
    all_migrations() :: Tuple{Vector{String},Dict{String,DatabaseMigration}}

Returns the list of all the migrations.
"""
function all_migrations() :: Tuple{Vector{String},Dict{String,DatabaseMigration}}
  migrations = String[]
  migrations_files = Dict{String,DatabaseMigration}()
  for f in readdir(Genie.config.db_migrations_folder)
    if ismatch(r"\d{16,17}_.*\.jl", f)
      parts = map(x -> String(x), split(f, "_", limit = 2))
      push!(migrations, parts[1])
      migrations_files[parts[1]] = DatabaseMigration(parts[1], f, migration_module_name(parts[2]))
    end
  end

  sort!(migrations), migrations_files
end


"""
    last_migration() :: DatabaseMigration

Returns the last created migration.
"""
function last_migration() :: DatabaseMigration
  migrations, migrations_files = all_migrations()
  migrations_files[migrations[end]]
end


"""
    run_migration(migration::DatabaseMigration, direction::Symbol; force = false) :: Void

Runs `migration` in up or down, per `directon`. If `force` is true, the migration is run regardless of its current status (already `up` or `down`).
"""
function run_migration(migration::DatabaseMigration, direction::Symbol; force = false) :: Void
  if ! force
    if  ( direction == :up    && in(migration.migration_hash, upped_migrations()) ) ||
        ( direction == :down  && in(migration.migration_hash, downed_migrations()) )
      Logger.log("Skipping, migration is already $direction")
      return
    end
  end

  try
    m = include(abspath(joinpath(Genie.config.db_migrations_folder, migration.migration_file_name)))
    getfield(m, direction)()

    store_migration_status(migration, direction)

    ! Genie.config.suppress_output && Logger.log("Executed migration $(migration.migration_module_name) $(direction)")
  catch ex
    Logger.log(string(ex), :err)
  end

  nothing
end


"""
    store_migration_status(migration::DatabaseMigration, direction::Symbol) :: Void

Persists the `direction` of the `migration` into the database.
"""
function store_migration_status(migration::DatabaseMigration, direction::Symbol) :: Void
  if ( direction == :up )
    Database.query("INSERT INTO $(Genie.config.db_migrations_table_name) VALUES ('$(migration.migration_hash)')", system_query = true)
  else
    Database.query("DELETE FROM $(Genie.config.db_migrations_table_name) WHERE version = ('$(migration.migration_hash)')", system_query = true)
  end

  nothing
end


"""
    upped_migrations() :: Vector{String}

List of all migrations that are `up`.
"""
function upped_migrations() :: Vector{String}
  result = Database.query("SELECT * FROM $(Genie.config.db_migrations_table_name) ORDER BY version DESC", system_query = true)

  map(x -> x[1], result)
end


"""
    downed_migrations() :: Vector{String}

List of all migrations that are `down`.
"""
function downed_migrations() :: Vector{String}
  upped = upped_migrations()
  filter(m -> ! in(m, upped), all_migrations()[1])
end


"""
    status() :: Void

Prints a table that displays the `direction` of each migration.
"""
function status() :: Void
  migrations, migrations_files = all_migrations()
  up_migrations = upped_migrations()
  arr_output = []

  for m in migrations
    sts = ( findfirst(up_migrations, m) > 0 ) ? :up : :down
    push!(arr_output, [migrations_files[m].migration_module_name * ": " * uppercase(string(sts)); migrations_files[m].migration_file_name])
  end

  Millboard.table(arr_output, :colnames => ["Class name & status \nFile name "], :rownames => []) |> println

  nothing
end


"""
    all_with_status() :: Tuple{Vector{String},Dict{String,Dict{Symbol,Any}}}

Returns a list of all the migrations and their status.
"""
function all_with_status() :: Tuple{Vector{String},Dict{String,Dict{Symbol,Any}}}
  migrations, migrations_files = all_migrations()
  up_migrations = upped_migrations()
  indexes = String[]
  result = Dict{String,Dict{Symbol,Any}}()

  for m in migrations
    status = ( findfirst(up_migrations, m) > 0 ) ? :up : :down
    push!(indexes, migrations_files[m].migration_hash)
    result[migrations_files[m].migration_hash] = Dict(
      :migration => DatabaseMigration(migrations_files[m].migration_hash, migrations_files[m].migration_file_name, migrations_files[m].migration_module_name),
      :status => status
    )
  end

  indexes, result
end


"""
    all_down() :: Void

Runs all migrations `down`.
"""
function all_down() :: Void
  i, m = all_with_status()
  for v in values(m)
    if v[:status] == :up
      mm = v[:migration]
      down_by_module_name(mm.migration_module_name)
    end
  end

  nothing
end


"""
    all_up() :: Void

Runs all migrations `up`. 
"""
function all_up() :: Void
  i, m = all_with_status()
  for v_hash in i
    v = m[v_hash]
    if v[:status] == :down
      mm = v[:migration]
      up_by_module_name(mm.migration_module_name)
    end
  end

  nothing
end

end
