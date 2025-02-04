# usage
```nix
{
  # Enable PostgreSQL and configure via the hectic.postgres namespace:
  hectic.postgres.enable = true;

  # Choose a package if you want a specific PostgreSQL version
  # (defaults to pkgs.postgresql_16):
  hectic.postgres.package = pkgs.postgresql_15;

  # Allow TCP connections (default true):
  hectic.postgres.enableTCPIP = true;

  # Set the PostgreSQL port (default 5432):
  hectic.postgres.port = 5433;

  hectic.postgres.environment = {
        VARIABLE_1 = "value_1";
        VARIABLE_2 = "value_2";
  };

  # Override or add any PostgreSQL settings (must be attrs):
  hectic.postgres.settings = {
    shared_buffers = "128MB";
  };

  # Define extensions you want to enable (bool per extension):
  hectic.postgres.extensions = {
    pg_cron  = true;
    pgjwt    = true;
    pg_net   = true;
    pg_http  = true;
    plrust   = true; # broken
  };

  # Provide an initial script if needed:
  hectic.postgres.initialScript = ./init.sql;

  # Map database names to migration directories. Each entry
  # spawns a systemd service that runs migrations after PostgreSQL starts:
  hectic.postgres.migrationFolders = {
    db1 = ./migrations/db1;
    db2 = ./migrations/db2;
  };
}
```
