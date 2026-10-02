# Database Package — Explained for Beginners

This file explains **everything** about the `database` package: the concepts first, then the code, then how it connects to the rest of the backend.

> **Read order:** Concepts → `database.go` → `migrator.go` → "How it connects"

---

## Part 1 — The Big Idea (read this first)

### What is a "database layer" in a backend?

Almost every backend needs to **store and retrieve data**. That data lives in a **database** (here: PostgreSQL). But your code shouldn't talk to the database directly every time — that would be messy and unsafe. Instead, this package wraps the database connection into a clean, reusable object.

This package does **two jobs**:

1. **`database.go`** — creates a **connection pool** to PostgreSQL and hands it to the rest of the app. A pool is a set of ready-to-use connections that are shared, so you don't open a new connection for every single query (that would be slow).
2. **`migrator.go`** — runs **schema migrations**. Migrations are versioned SQL files that build/update your database tables. They let you change the schema safely, in order, without losing data.

### The mental model

```
config package (DatabaseConfig)
        │
        │  (host, port, user, password, pool settings)
        ▼
database.New()  ──►  *Database  (holds a pgxpool.Pool)
        │
        │  (handed to server, then to repositories)
        ▼
repositories / services / handlers   ← the rest of the app runs queries
```

And separately, at startup:

```
migrations/*.sql  (embedded into the binary)
        │
        ▼
database.Migrate()  ──►  applies pending migrations to PostgreSQL
```

### Why a pool? (the 3 reasons)

1. **Speed** — opening a TCP connection to a database is expensive. A pool keeps connections warm and reuses them.
2. **Safety** — a pool limits how many connections you use, so you don't exhaust the database server.
3. **Resilience** — if a connection dies, the pool can replace it.

### Why migrations?

- Your schema changes over time (add a column, add a table).
- Migrations are **versioned SQL files** — each one is a small, ordered step.
- They run **in order**, and the database remembers which version it's on (in a `schema_version` table), so they never run twice.

---

## Part 2 — Go Concepts You MUST Know First

These are the building blocks used everywhere in this file. If you understand these, the code becomes obvious.

### 1. Structs with embedded fields

```go
type Database struct {
	Pool *pgxpool.Pool
	log  *zerolog.Logger
}
```

`Database` is a struct that bundles the connection pool (`Pool`) and a logger (`log`). Note `log` is **lowercase** — that means it's **private** (only this package can see it). `Pool` is **uppercase** — it's **public** (other packages can use it, e.g. `db.Pool`).

### 2. Interfaces — "a promise to have these methods"

```go
type multiTracer struct {
	tracers []any
}
```

`any` means "any type". The `multiTracer` holds a list of tracers (things that watch queries). It then checks each one to see if it implements the pgx tracer interface. This is **duck typing** — "if it walks like a duck and quacks like a duck, it's a duck."

### 3. `//go:embed` — baking files into the binary

```go
//go:embed migrations/*.sql
var migrations embed.FS
```

This special comment tells Go: "take all `.sql` files in the `migrations/` folder and bundle them **inside the compiled binary**." That means the migrations travel with your app — you don't need to copy SQL files to the server separately.

### 4. Context — "a deadline + cancellation signal"

```go
ctx, cancel := context.WithTimeout(context.Background(), DatabasePingTimeout*time.Second)
defer cancel()
```

`context.Context` carries a **deadline** and a way to **cancel**. Here it says "ping the database, but give up after 10 seconds." `defer cancel()` makes sure the timer is cleaned up even if the function returns early.

### 5. `fmt.Errorf("...: %w", err)` — wrapping errors

```go
return nil, fmt.Errorf("failed to parse pgx pool config: %w", err)
```

`%w` **wraps** the original error inside a new one with more context. Later, `errors.Is()` / `errors.As()` can unwrap it to find the original cause. This is how Go preserves the "root cause" while adding context.

### 6. `net.JoinHostPort` and `url.QueryEscape`

```go
hostPort := net.JoinHostPort(cfg.Database.Host, strconv.Itoa(cfg.Database.Port))
encodedPassword := url.QueryEscape(cfg.Database.Password)
```

- `net.JoinHostPort` safely combines host + port into `host:port` (handles IPv6 correctly).
- `url.QueryEscape` **encodes** the password so special characters (like `@` or `#`) don't break the connection string.

---

## Part 3 — The Libraries (what each one does)

| Library | Purpose |
|---|---|
| **pgx / pgxpool** | The PostgreSQL driver for Go. `pgxpool` is its connection-pool implementation. |
| **tern** | A migration tool for PostgreSQL. Reads SQL files and applies them in version order. |
| **pgx-zerolog** | Bridges pgx's internal logging to zerolog (so DB logs look like the rest of your logs). |
| **nrpgx5** | New Relic's PostgreSQL instrumentation — traces every query in New Relic. |
| **zerolog** | The structured logger used across the project. |
| **embed** | Standard library — bundles the migration SQL files into the binary. |

---

## Part 4 — `database.go` Explained Line by Line

### The `Database` struct

```go
type Database struct {
	Pool *pgxpool.Pool
	log  *zerolog.Logger
}
```

The public face of this package. `Pool` is what repositories use to run queries. `log` is private — used internally for logging.

### The `multiTracer` — chaining tracers

```go
type multiTracer struct {
	tracers []any
}

func (mt *multiTracer) TraceQueryStart(ctx context.Context, conn *pgx.Conn, data pgx.TraceQueryStartData) context.Context {
	for _, tracer := range mt.tracers {
		if t, ok := tracer.(interface {
			TraceQueryStart(context.Context, *pgx.Conn, pgx.TraceQueryStartData) context.Context
		}); ok {
			ctx = t.TraceQueryStart(ctx, conn, data)
		}
	}
	return ctx
}
```

pgx lets you attach **one** tracer per connection. But this project wants **two**: New Relic (for production monitoring) *and* a local SQL logger (for development). The `multiTracer` solves that by holding a list of tracers and calling each one in turn — like a chain.

- `TraceQueryStart` runs **before** a query (e.g. start a New Relic segment).
- `TraceQueryEnd` runs **after** a query (e.g. record the duration).

### `New()` — the main entry point

```go
func New(cfg *config.Config, logger *zerolog.Logger, loggerService *loggerConfig.LoggerService) (*Database, error) {
```

Called **once** at startup. It takes the full config, a logger, and the logger service (for New Relic). Returns a ready-to-use `*Database` or an error.

**Step 1 — build the connection string (DSN):**

```go
hostPort := net.JoinHostPort(cfg.Database.Host, strconv.Itoa(cfg.Database.Port))
encodedPassword := url.QueryEscape(cfg.Database.Password)
dsn := fmt.Sprintf("postgres://%s:%s@%s/%s?sslmode=%s",
	cfg.Database.User, encodedPassword, hostPort, cfg.Database.Name, cfg.Database.SSLMode)
```

Turns config values into a URL like:
```
postgres://user:pass@localhost:5432/boilerplate?sslmode=disable
```

**Step 2 — parse the pool config:**

```go
pgxPoolConfig, err := pgxpool.ParseConfig(dsn)
if err != nil {
	return nil, fmt.Errorf("failed to parse pgx pool config: %w", err)
}
```

Validates the DSN and creates a config object with sensible pool defaults.

**Step 3 — add New Relic instrumentation (production):**

```go
if loggerService != nil && loggerService.GetApplication() != nil {
	pgxPoolConfig.ConnConfig.Tracer = nrpgx5.NewTracer()
}
```

If New Relic is active (a license key was provided), every query gets traced. This only happens when `loggerService` actually has a New Relic app — in dev it's skipped.

**Step 4 — add local SQL logging (local env):**

```go
if cfg.Primary.Env == "local" {
	globalLevel := logger.GetLevel()
	pgxLogger := loggerConfig.NewPgxLogger(globalLevel)
	...
}
```

In the `local` environment, it also attaches a `tracelog.TraceLog` that prints every SQL query to the console (using the same log level as the app). If New Relic's tracer is already there, it wraps both in a `multiTracer` so **both** run.

**Step 5 — create the pool:**

```go
pool, err := pgxpool.NewWithConfig(context.Background(), pgxPoolConfig)
if err != nil {
	return nil, fmt.Errorf("failed to create pgx pool: %w", err)
}
```

Actually creates the pool. Note: this doesn't connect yet — connections are created lazily as needed.

**Step 6 — ping to verify:**

```go
ctx, cancel := context.WithTimeout(context.Background(), DatabasePingTimeout*time.Second)
defer cancel()
if err = pool.Ping(ctx); err != nil {
	return nil, fmt.Errorf("failed to ping database: %w", err)
}
```

Forces a real connection to make sure the database is reachable. If it fails, the app **fails fast** at startup instead of crashing later on the first query. `DatabasePingTimeout = 10` seconds.

**Step 7 — return:**

```go
database := &Database{Pool: pool, log: logger}
logger.Info().Msg("connected to the database")
return database, nil
```

### `Close()` — graceful shutdown

```go
func (db *Database) Close() error {
	db.log.Info().Msg("closing database connection pool")
	db.Pool.Close()
	return nil
}
```

Closes all pooled connections. Called during server shutdown so the app exits cleanly.

---

## Part 5 — `migrator.go` Explained Line by Line

### Embedding the migrations

```go
//go:embed migrations/*.sql
var migrations embed.FS
```

Bundles all `migrations/*.sql` files into the compiled binary. The app can now run migrations even if the SQL files aren't present on disk.

### `Migrate()` — the entry point

```go
func Migrate(ctx context.Context, logger *zerolog.Logger, cfg *config.Config) error {
```

Runs all pending migrations. Called at startup, **before** the server starts serving traffic.

**Step 1 — build the DSN (same as `New()`):**

```go
hostPort := net.JoinHostPort(cfg.Database.Host, strconv.Itoa(cfg.Database.Port))
encodedPassword := url.QueryEscape(cfg.Database.Password)
dsn := fmt.Sprintf("postgres://%s:%s@%s/%s?sslmode=%s", ...)
```

**Step 2 — open a single connection:**

```go
conn, err := pgx.Connect(ctx, dsn)
if err != nil {
	return err
}
defer conn.Close(ctx)
```

Migrations use a **single** connection (not the pool) — migrations must run one at a time, in order.

**Step 3 — create the migrator:**

```go
m, err := tern.NewMigrator(ctx, conn, "schema_version")
```

`tern` creates a migrator that tracks applied versions in a table called `schema_version`.

**Step 4 — load the embedded SQL files:**

```go
subtree, err := fs.Sub(migrations, "migrations")
...
if err := m.LoadMigrations(subtree); err != nil { ... }
```

`fs.Sub` points into the embedded filesystem at the `migrations/` folder, then `LoadMigrations` reads all the `.sql` files and sorts them by version.

**Step 5 — check current version:**

```go
from, err := m.GetCurrentVersion(ctx)
```

Asks the database which migration version it's currently on.

**Step 6 — apply pending migrations:**

```go
if err := m.Migrate(ctx); err != nil {
	return err
}
```

Applies every migration newer than the current version, in order.

**Step 7 — log the result:**

```go
if from == int32(len(m.Migrations)) {
	logger.Info().Msgf("database schema up to date, version %d", len(m.Migrations))
} else {
	logger.Info().Msgf("migrated database schema, from %d to %d", from, len(m.Migrations))
}
```

If nothing changed, log "up to date". Otherwise, log the version jump.

---

## Part 6 — Architecture & Workflow

### Startup flow (how it all fits together)

```mermaid
flowchart TD
    A[main.go starts] --> B[config.LoadConfig]
    B --> C[logger.NewLoggerService]
    C --> D[database.Migrate]
    D --> E[database.New]
    E --> F[server.New]
    F --> G[HTTP server starts serving]
    D -.applies.-> M[(PostgreSQL)]
    E -.pool of connections.-> M
```

### How a query flows through the app

```mermaid
sequenceDiagram
    participant C as Client (browser/app)
    participant H as Handler
    participant R as Repository
    participant P as pgxpool.Pool
    participant DB as PostgreSQL

    C->>H: HTTP request
    H->>R: call repository method
    R->>P: db.Pool.Query(...)
    P->>DB: SQL query
    DB-->>P: rows
    P-->>R: result rows
    R-->>H: typed result
    H-->>C: JSON response
```

### Tracer chaining (local environment)

```mermaid
flowchart LR
    Q[SQL query] --> MT[multiTracer]
    MT --> NR[nrpgx5 tracer<br/>New Relic]
    MT --> TL[tracelog.TraceLog<br/>console SQL logging]
    NR --> DB[(PostgreSQL)]
    TL --> DB
```

### Migration lifecycle

```mermaid
flowchart LR
    SQL[migrations/*.sql<br/>embedded in binary] --> LOAD[tern loads + sorts by version]
    LOAD --> CUR{current version<br/>vs latest?}
    CUR -->|behind| APPLY[apply pending migrations in order]
    CUR -->|up to date| DONE[log: schema up to date]
    APPLY --> TRACK[record version in schema_version table]
    TRACK --> DONE
```

---

## Part 7 — How This Connects to the Rest of the Backend

The database package is the **data foundation** — repositories depend on it.

```
server.New()
   │
   └── database.New(cfg, logger, loggerService)  ──►  *Database
                                                          │
                                                          ▼
                                              repositories (db.Pool)
                                                          │
                                                          ▼
                                              services → handlers → HTTP
```

| Package | Uses | For |
|---|---|---|
| `server` | `database.New(...)`, `db.Close()` | Initializing the DB at startup, closing it at shutdown |
| `repository` | `db.Pool` | Running queries (SELECT / INSERT / UPDATE / DELETE) |
| `config` | `cfg.Database.*` | Connection details + pool settings (host, port, max conns) |
| `logger` | `loggerService` | New Relic tracing + SQL logging in local env |
| `sqlerr` | (works alongside) | Converts database errors into friendly HTTP errors |

### The flow in `main.go` (what will happen)

```go
func main() {
	cfg, err := config.LoadConfig()          // 1. load config
	// ...
	loggerService := logger.NewLoggerService(cfg.Observability) // 2. New Relic
	// ...
	err = database.Migrate(ctx, logger, cfg) // 3. apply schema migrations
	// ...
	db, err := database.New(cfg, logger, loggerService) // 4. create pool
	// ...
	server := server.New(cfg, logger, loggerService)    // 5. build server (uses db)
	// ...
	server.Start()                           // 6. serve traffic
}
```

---

## Part 8 — Quick Reference Cheat Sheet

| Concept | Meaning |
|---|---|
| Connection pool | A shared set of reusable DB connections |
| DSN | The connection string (`postgres://user:pass@host:port/db`) |
| `pgxpool.Pool` | The pool object repositories use to run queries |
| Tracer | Code that observes queries (for logging / monitoring) |
| `multiTracer` | Chains multiple tracers together |
| `//go:embed` | Bundles files into the compiled binary |
| Migration | A versioned SQL file that changes the schema |
| `tern` | The migration runner (tracks version in `schema_version`) |
| `context.WithTimeout` | A deadline for an operation (e.g. ping = 10s) |
| `%w` | Wraps an error while keeping the original cause |
| Fail-fast | Crash at startup if the DB is unreachable |

---

## Part 9 — Try It Yourself

1. Make sure PostgreSQL is running locally, then create a database:
   ```bash
   createdb boilerplate
   ```

2. Add a migration file and see it get applied:
   ```bash
   mkdir -p internal/database/migrations
   cat > internal/database/migrations/0001_init.sql <<'EOF'
   CREATE TABLE users (
       id         BIGSERIAL PRIMARY KEY,
       email      TEXT NOT NULL UNIQUE,
       created_at TIMESTAMPTZ NOT NULL DEFAULT now()
   );
   EOF
   ```

3. In `main.go`, temporarily call `database.Migrate` and `database.New`:
   ```go
   package main

   import (
       "context"
       "fmt"
       "github.com/vinaykvv00/go-boilerplate/internal/config"
       "github.com/vinaykvv00/go-boilerplate/internal/database"
       "github.com/vinaykvv00/go-boilerplate/internal/logger"
   )

   func main() {
       cfg, err := config.LoadConfig()
       if err != nil {
           panic(err)
       }
       loggerService := logger.NewLoggerService(cfg.Observability)
       log := logger.NewLoggerWithService(cfg.Observability, loggerService)

       if err := database.Migrate(context.Background(), &log, cfg); err != nil {
           panic(err)
       }
       db, err := database.New(cfg, &log, loggerService)
       if err != nil {
           panic(err)
       }
       defer db.Close()

       fmt.Println("Database ready!")
   }
   ```

4. **Experiment:** run it twice. The first run applies `0001_init.sql`; the second run logs `database schema up to date`. That's migrations working.
